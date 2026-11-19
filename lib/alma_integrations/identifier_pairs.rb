require 'csv'

module AlmaIntegrations
  # Reads a spreadsheet that pairs an Alma MMS ID with the ArchivesSpace
  # collection it belongs to, so the MMS IDs can be written into the resources.
  #
  # This is the one-off inverse of everything else in the plugin: normally the
  # MMS ID is already on the resource and is used to find the Alma record. Here
  # the catalogue is the source, and ArchivesSpace is the thing being filled in.
  #
  # The columns are found by header name, because the export people actually
  # have to hand is a wide report from Alma where the two useful columns are
  # first and fifteenth. Falling back to column numbers only when the headers
  # cannot be recognised saves the operator from counting commas.
  #
  # Conflicts within the file are detected here rather than in the job runner:
  # they are a property of the list alone, need no database, and are the single
  # most dangerous thing a file like this can contain. An EAD ID appearing twice
  # with two different MMS IDs means one of the two rows is wrong, and there is
  # no safe way to guess which.
  class IdentifierPairs
    Row = Struct.new(:line, :mms_id, :collection_id, :raw) do
      def to_h
        { 'line' => line, 'mms_id' => mms_id, 'collection_id' => collection_id }
      end
    end

    Problem = Struct.new(:raw, :line, :reason) do
      def to_h
        { 'raw' => raw, 'line' => line, 'reason' => reason }
      end
    end

    # Same rule the rest of the plugin uses, so a value accepted here is one the
    # audit and update jobs will also accept.
    MMS_PATTERN = IdentifierList::MMS_PATTERN

    # Header names are compared after being reduced to lowercase words joined by
    # underscores, so "MMS Id", "mms-id" and "MMS_ID" all arrive here the same.
    MMS_HEADERS = %w[
      mms_id mms mmsid mms_number alma_mms_id alma_id bib_id bibid bib_mms_id
      lookup_mms_id
    ].freeze

    COLLECTION_HEADERS = %w[
      lookup_ead_id ead_id eadid ead ead_id_lookup aspace_ead_id
      collection_id collection identifier resource_identifier id_0
    ].freeze

    attr_reader :rows, :duplicates, :problems, :header,
                :mms_column, :collection_column, :matched_headers

    def self.parse(source, mms_column: nil, collection_column: nil)
      new(source, :mms_column => mms_column, :collection_column => collection_column)
    end

    def initialize(source, mms_column: nil, collection_column: nil)
      @requested_mms_column = normalise_column(mms_column)
      @requested_collection_column = normalise_column(collection_column)
      @rows = []
      @duplicates = []
      @problems = []
      @header = nil
      @matched_headers = false

      parse(source.to_s)
      flag_conflicts
    end

    def empty?
      rows.empty?
    end

    # Combines another parsed list into this one and re-checks for conflicts, so
    # a collection given one MMS ID in the pasted box and a different one in the
    # uploaded file is still caught. Each source is parsed separately first
    # because they may not have the same columns.
    def merge!(other)
      seen = rows.map { |row| [row.mms_id, row.collection_id] }

      other.rows.each do |row|
        key = [row.mms_id, row.collection_id]

        if seen.include?(key)
          @duplicates << row
        else
          @rows << row
          seen << key
        end
      end

      @duplicates.concat(other.duplicates)
      @problems.concat(other.problems)

      flag_conflicts
      self
    end

    def to_h
      {
        'total' => rows.length,
        'duplicates' => duplicates.length,
        'problems' => problems.length,
        'header_skipped' => header,
        'mms_column' => mms_column,
        'collection_column' => collection_column,
        'matched_by_header' => matched_headers
      }
    end

    private

    def normalise_column(value)
      return nil if value.nil? || value.to_s.strip.empty?

      [value.to_i, 0].max
    end

    def parse(text)
      text = clean(text)
      separator = detect_separator(text)

      # Without a separator there is only one column, and a pair needs two.
      if separator.nil?
        first = text.split(/\r\n|\r|\n/).find { |line| !line.strip.empty? }
        unless first.nil?
          @problems << Problem.new(first.strip, 1,
                                   'the file has only one column; a CSV or TSV with both an ' \
                                   'MMS ID and a collection identifier is required')
        end
        return
      end

      lines = text.split(/\r\n|\r|\n/)
      seen = {}
      header_checked = false

      lines.each_with_index do |line, index|
        line_number = index + 1

        next if line.strip.empty?
        next if line.strip.start_with?(IdentifierList::COMMENT_PREFIX)

        cells = split_row(line, separator)
        next if cells.nil?

        unless header_checked
          header_checked = true
          if assign_columns(cells)
            @header = line.strip
            next
          end
        end

        read_row(line, cells, line_number, seen)
      end
    end

    def clean(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding?
        text = text.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace, :replace => '')
      end

      text.sub(/\A\uFEFF/, '')
    end

    def detect_separator(text)
      sample = text.split(/\r\n|\r|\n/).reject { |line| line.strip.empty? }.first(20)
      return "\t" if sample.any? { |line| line.include?("\t") }
      return ',' if sample.any? { |line| line.include?(',') }

      nil
    end

    def split_row(line, separator)
      CSV.parse_line(line, :col_sep => separator)
    rescue CSV::MalformedCSVError, ArgumentError
      line.split(separator)
    end

    # Returns true when the row was consumed as a header. Explicit column
    # numbers win over the header names: an operator who has told us where to
    # look has usually done so because the guess was wrong.
    def assign_columns(cells)
      names = cells.map { |cell| normalise_header(cell) }
      by_name = {
        :mms => names.index { |name| MMS_HEADERS.include?(name) },
        :collection => names.index { |name| COLLECTION_HEADERS.include?(name) }
      }

      @mms_column = @requested_mms_column || by_name[:mms]
      @collection_column = @requested_collection_column || by_name[:collection]
      @matched_headers = !by_name[:mms].nil? && !by_name[:collection].nil?

      # No header row and no instruction: fall back to the first two columns,
      # which is the shape of a file somebody has trimmed down by hand.
      @mms_column ||= 0
      @collection_column ||= 1

      # Only swallow the row if it really was a header. A file whose columns
      # were given by number still starts with a header more often than not, so
      # a recognisable name in either position is enough to drop it.
      !by_name[:mms].nil? || !by_name[:collection].nil?
    end

    def normalise_header(value)
      value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
    end

    def read_row(line, cells, line_number, seen)
      raw = line.strip
      mms_id = cell(cells, @mms_column)
      collection_id = cell(cells, @collection_column)

      if mms_id.empty? && collection_id.empty?
        @problems << Problem.new(raw, line_number, 'no MMS ID and no collection identifier')
        return
      end

      if collection_id.empty?
        @problems << Problem.new(raw, line_number,
                                 "no collection identifier in column #{@collection_column}")
        return
      end

      if mms_id.empty?
        @problems << Problem.new(raw, line_number, "no MMS ID in column #{@mms_column}")
        return
      end

      mms_id = strip_prefix(mms_id)
      collection_id = strip_prefix(collection_id)

      unless MMS_PATTERN.match?(mms_id)
        @problems << Problem.new(raw, line_number,
                                 "#{mms_id.inspect} does not look like an Alma MMS ID")
        return
      end

      key = [mms_id, collection_id]
      if seen.key?(key)
        @duplicates << Row.new(line_number, mms_id, collection_id, raw)
        return
      end

      seen[key] = true
      @rows << Row.new(line_number, mms_id, collection_id, raw)
    end

    def cell(cells, index)
      return '' if index.nil?

      value = cells[index]
      value.nil? ? '' : value.to_s.strip
    end

    # Tolerates "mms:99..." or "ead:UA.1.2" in a spreadsheet cell, since the
    # other job forms invite that syntax and habits carry over.
    def strip_prefix(value)
      match = /\A([A-Za-z_]+)\s*:\s*(.*)\z/.match(value)
      return value if match.nil?
      return value unless IdentifierList::PREFIXES.key?(match[1].downcase)

      match[2].strip
    end

    # A row that disagrees with another row is dropped rather than applied. Both
    # sides are reported: the operator has to look at the spreadsheet to know
    # which is right, and naming only one of them would send them to the wrong
    # line.
    #
    # Rows are keyed by identity rather than line number, because after a merge
    # two sources each have a line 2.
    def flag_conflicts
      drop = {}

      group(:collection_id).each do |collection_id, group_rows|
        mms_ids = group_rows.map(&:mms_id).uniq
        next if mms_ids.length < 2

        lines = group_rows.map(&:line).join(', ')
        group_rows.each do |row|
          drop[row.object_id] = "#{collection_id} is given #{mms_ids.length} " \
                                "different MMS IDs (lines #{lines})"
        end
      end

      group(:mms_id).each do |mms_id, group_rows|
        collections = group_rows.map(&:collection_id).uniq
        next if collections.length < 2

        lines = group_rows.map(&:line).join(', ')
        group_rows.each do |row|
          drop[row.object_id] ||= "MMS ID #{mms_id} is given to #{collections.length} " \
                                  "different collections (lines #{lines})"
        end
      end

      return if drop.empty?

      kept, conflicted = @rows.partition { |row| !drop.key?(row.object_id) }
      @rows = kept
      conflicted.each do |row|
        @problems << Problem.new(row.raw, row.line, drop[row.object_id])
      end
    end

    def group(attribute)
      @rows.group_by { |row| row.public_send(attribute) }
    end
  end
end
