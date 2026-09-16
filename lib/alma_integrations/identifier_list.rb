require 'csv'

module AlmaIntegrations
  # Turns the operator's list of records into a normalised, de-duplicated set of
  # identifiers.
  #
  # Accepts a pasted list or an uploaded file, one identifier per line or a
  # column of a CSV/TSV. Each identifier is classified as an Alma MMS ID or an
  # ArchivesSpace collection identifier (EAD ID or resource identifier), and an
  # explicit prefix always wins over the heuristic.
  class IdentifierList

    Entry = Struct.new(:raw, :value, :kind, :line) do
      def mms?
        kind == :mms
      end

      def collection?
        kind == :collection
      end

      def to_h
        { 'raw' => raw, 'value' => value, 'kind' => kind.to_s, 'line' => line }
      end
    end

    Problem = Struct.new(:raw, :line, :reason) do
      def to_h
        { 'raw' => raw, 'line' => line, 'reason' => reason }
      end
    end

    # Alma MMS IDs are long integers (typically 16-19 digits). Requiring at least
    # nine digits keeps short numeric local collection identifiers from being
    # mistaken for them.
    MMS_PATTERN = /\A\d{9,}\z/.freeze

    PREFIXES = {
      'mms' => :mms,
      'mmsid' => :mms,
      'mms_id' => :mms,
      'bib' => :mms,
      'ead' => :collection,
      'ead_id' => :collection,
      'id' => :collection,
      'collection' => :collection,
      'resource' => :collection
    }.freeze

    HEADER_VALUES = %w[
      mms mmsid mms_id bib bibid bib_id
      id identifier ead ead_id eadid
      collection collection_id resource resource_id record record_id
    ].freeze

    COMMENT_PREFIX = '#'.freeze

    attr_reader :entries, :duplicates, :problems, :header, :column, :total_lines

    def self.parse(source, column: 0, skip_header: nil)
      new(source, :column => column, :skip_header => skip_header)
    end

    def initialize(source, column: 0, skip_header: nil)
      @column = [column.to_i, 0].max
      @skip_header = skip_header
      @entries = []
      @duplicates = []
      @problems = []
      @header = nil
      @total_lines = 0

      parse(source.to_s)
    end

    def empty?
      entries.empty?
    end

    def mms_ids
      entries.select(&:mms?).map(&:value)
    end

    def collection_ids
      entries.select(&:collection?).map(&:value)
    end

    def to_h
      {
        'total' => entries.length,
        'mms_ids' => entries.count(&:mms?),
        'collection_ids' => entries.count(&:collection?),
        'duplicates' => duplicates.length,
        'problems' => problems.length,
        'header_skipped' => header
      }
    end

    private

    def parse(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      text = text.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace, :replace => '') unless text.valid_encoding?
      text = text.sub(/\A\xEF\xBB\xBF/n, '')
      text = text.sub(/\A\uFEFF/, '')

      separator = detect_separator(text)
      seen = {}
      first_value_seen = false

      text.split(/\r\n|\r|\n/).each_with_index do |line, index|
        line_number = index + 1
        @total_lines = line_number

        stripped = line.strip
        next if stripped.empty?
        next if stripped.start_with?(COMMENT_PREFIX)

        cell = extract_cell(line, separator, line_number)
        next if cell.nil?

        cell = cell.strip
        if cell.empty?
          @problems << Problem.new(line.strip, line_number, 'no value in the selected column')
          next
        end

        unless first_value_seen
          first_value_seen = true
          if header?(cell)
            @header = cell
            next
          end
        end

        kind, value = classify(cell)

        if value.empty?
          @problems << Problem.new(line.strip, line_number, 'no value after the identifier prefix')
          next
        end

        key = [kind, value]
        if seen.key?(key)
          @duplicates << Entry.new(cell, value, kind, line_number)
          next
        end

        seen[key] = true
        @entries << Entry.new(cell, value, kind, line_number)
      end
    end

    def detect_separator(text)
      sample = text.split(/\r\n|\r|\n/).reject { |line| line.strip.empty? }.first(20)
      return "\t" if sample.any? { |line| line.include?("\t") }
      return ',' if sample.any? { |line| line.include?(',') }

      nil
    end

    def extract_cell(line, separator, line_number)
      return line if separator.nil?

      cells = begin
        CSV.parse_line(line, :col_sep => separator)
      rescue CSV::MalformedCSVError, ArgumentError
        line.split(separator)
      end

      cells ||= []

      if cells.length <= @column
        @problems << Problem.new(line.strip, line_number, "line has fewer than #{@column + 1} columns")
        return nil
      end

      cells[@column]
    end

    def header?(value)
      return @skip_header if [true, false].include?(@skip_header)

      HEADER_VALUES.include?(value.downcase.gsub(/[\s-]+/, '_'))
    end

    def classify(value)
      if (match = /\A([A-Za-z_]+)\s*:\s*(.*)\z/.match(value))
        kind = PREFIXES[match[1].downcase]
        return [kind, match[2].strip] unless kind.nil?
      end

      MMS_PATTERN.match?(value) ? [:mms, value] : [:collection, value]
    end
  end
end
