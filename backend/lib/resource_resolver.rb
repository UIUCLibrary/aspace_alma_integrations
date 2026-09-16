require_relative '../../lib/alma_integrations'

module AlmaIntegrations
  # Turns a list of user-supplied identifiers into ArchivesSpace resources.
  #
  # Lookups are batched. A list of several thousand identifiers resolves in a
  # handful of queries rather than several thousand, which matters because this
  # runs inside a job thread that other jobs are queued behind.
  #
  # Anything that cannot be resolved -- unknown, ambiguous, or lacking an MMS ID
  # -- becomes an error row in the report rather than being quietly dropped. A
  # record silently missing from an audit is worse than no audit at all.
  class ResourceResolver
    # user_defined columns that can sensibly hold an MMS ID. Guarding the
    # configured value against this list keeps an AppConfig typo from reaching
    # the database as an identifier.
    VALID_MMS_FIELDS = (
      (1..4).map { |i| "string_#{i}" } +
      (1..5).map { |i| "text_#{i}" } +
      (1..3).map { |i| "integer_#{i}" }
    ).freeze

    Resolution = Struct.new(:input, :kind, :matched_by, :resource_id, :uri, :title,
                            :mms_id, :ead_id, :identifier, :lock_version,
                            :system_mtime, :error, :error_kind,
                            :keyword_init => true) do
      def ok?
        error.nil?
      end
    end

    attr_reader :mms_field, :collection_id_field

    def initialize(repo_id:, settings: nil, collection_id_field: 'auto')
      @repo_id = repo_id
      @settings = settings || Settings.new
      @mms_field = validate_mms_field(@settings[:mms_field])
      @collection_id_field = collection_id_field.to_s.empty? ? 'auto' : collection_id_field.to_s
      @resources = {}
      @mms_ids = {}
    end

    # Resolves every entry, yielding a Resolution in the caller's original order
    # so the report matches the list the user submitted.
    def resolve(entries)
      return enum_for(:resolve, entries) unless block_given?

      entries = Array(entries)
      mms_entries = entries.select(&:mms?)
      collection_entries = entries.reject(&:mms?)

      by_mms = lookup_by_mms(mms_entries.map(&:value).uniq)
      by_collection = lookup_by_collection(collection_entries.map(&:value).uniq)

      entries.each do |entry|
        yield(entry.mms? ? resolution_for_mms(entry, by_mms) : resolution_for_collection(entry, by_collection))
      end
    end

    private

    def validate_mms_field(field)
      field = field.to_s
      return field if VALID_MMS_FIELDS.include?(field)

      raise Error, "Configured Alma MMS ID field #{field.inspect} is not a user-defined field. " \
                   "Expected one of: #{VALID_MMS_FIELDS.join(', ')}"
    end

    # --- MMS ID --------------------------------------------------------------

    def lookup_by_mms(values)
      return {} if values.empty?

      column = @mms_field.to_sym
      index = Hash.new { |hash, key| hash[key] = [] }

      values.each_slice(500) do |slice|
        UserDefined
          .where(column => slice)
          .exclude(:resource_id => nil)
          .select(:resource_id, column)
          .each do |row|
            index[row[column].to_s] << row[:resource_id]
          end
      end

      hydrate(index)
    end

    def resolution_for_mms(entry, index)
      matches = index[entry.value]

      if matches.nil? || matches.empty?
        # An MMS ID with no ArchivesSpace resource behind it is still auditable:
        # we can fetch the Alma record, we just have nothing to compare it with.
        return Resolution.new(:input => entry.value, :kind => 'mms', :mms_id => entry.value,
                              :error => 'No ArchivesSpace resource has this MMS ID',
                              :error_kind => 'resource_not_found')
      end

      if matches.length > 1
        return ambiguous(entry, 'mms', matches)
      end

      build_resolution(entry, 'mms', @mms_field, matches.first)
    end

    # --- Collection identifier ----------------------------------------------

    def lookup_by_collection(values)
      return {} if values.empty?

      index = Hash.new { |hash, key| hash[key] = [] }
      matched_by = {}

      lookup_by_ead_id(values, index, matched_by) if use_ead_id?
      lookup_by_identifier(values, index, matched_by) if use_identifier?

      { :records => hydrate(index), :matched_by => matched_by }
    end

    def use_ead_id?
      %w[auto ead_id].include?(@collection_id_field)
    end

    def use_identifier?
      return true if %w[auto id_0 identifier].include?(@collection_id_field)

      false
    end

    def lookup_by_ead_id(values, index, matched_by)
      values.each_slice(500) do |slice|
        resource_dataset
          .where(:ead_id => slice)
          .select(:id, :ead_id)
          .each do |row|
            index[row[:ead_id].to_s] << row[:id]
            matched_by[row[:ead_id].to_s] ||= 'ead_id'
          end
      end
    end

    # `resource.identifier` is a JSON array of up to four parts, stored as a
    # string -- e.g. ["MS", "123", null, null]. Matching it means reproducing
    # the exact serialisation, so each user-supplied value is expanded into the
    # encodings it could plausibly have: the whole thing in the first part, and
    # the value split on the separators ArchivesSpace itself uses to display a
    # composite identifier.
    def lookup_by_identifier(values, index, matched_by)
      candidates = {}

      values.each do |value|
        next if index.key?(value) && !index[value].empty?

        identifier_encodings(value).each do |encoded|
          (candidates[encoded] ||= []) << value
        end
      end

      return if candidates.empty?

      candidates.keys.each_slice(500) do |slice|
        resource_dataset
          .where(:identifier => slice)
          .select(:id, :identifier)
          .each do |row|
            Array(candidates[row[:identifier].to_s]).each do |value|
              index[value] << row[:id]
              matched_by[value] ||= 'identifier'
            end
          end
      end
    end

    IDENTIFIER_SEPARATORS = ['--', '.', '/', ' '].freeze

    def identifier_encodings(value)
      value = value.to_s
      encodings = [encode_identifier([value])]

      IDENTIFIER_SEPARATORS.each do |separator|
        parts = value.split(separator)
        next if parts.length < 2 || parts.length > 4

        parts = parts.map(&:strip).reject(&:empty?)
        next if parts.length < 2

        encodings << encode_identifier(parts)
      end

      encodings.uniq
    end

    def encode_identifier(parts)
      padded = parts.dup
      padded << nil while padded.length < 4
      JSON(padded[0, 4])
    end

    def resolution_for_collection(entry, lookup)
      index = lookup.is_a?(Hash) ? (lookup[:records] || {}) : {}
      matched_by = lookup.is_a?(Hash) ? (lookup[:matched_by] || {}) : {}
      matches = index[entry.value]

      if matches.nil? || matches.empty?
        return Resolution.new(:input => entry.value, :kind => 'collection',
                              :error => "No resource found with #{searched_fields_description} #{entry.value.inspect}",
                              :error_kind => 'resource_not_found')
      end

      if matches.length > 1
        return ambiguous(entry, 'collection', matches)
      end

      build_resolution(entry, 'collection', matched_by[entry.value], matches.first)
    end

    def searched_fields_description
      case @collection_id_field
      when 'ead_id' then 'EAD ID'
      when 'id_0', 'identifier' then 'identifier'
      else 'EAD ID or identifier'
      end
    end

    # --- Shared --------------------------------------------------------------

    # Scoped explicitly rather than relying on the ambient RequestContext, so a
    # lookup can never reach into another repository even if the job's context
    # is wider than expected.
    def resource_dataset
      Resource.where(:repo_id => @repo_id)
    end

    # Loads the resource rows behind a set of matched ids, along with the MMS ID
    # from user_defined. Two queries regardless of how many ids there are.
    def hydrate(index)
      ids = index.values.flatten.uniq
      return index if ids.empty?

      missing = ids - @resources.keys

      unless missing.empty?
        missing.each_slice(500) do |slice|
          resource_dataset
            .where(:id => slice)
            .select(:id, :repo_id, :title, :identifier, :ead_id, :lock_version, :system_mtime)
            .each { |row| @resources[row[:id]] = row.to_hash }
        end

        column = @mms_field.to_sym
        missing.each_slice(500) do |slice|
          UserDefined
            .where(:resource_id => slice)
            .select(:resource_id, column)
            .each { |row| @mms_ids[row[:resource_id]] = row[column] }
        end
      end

      # Drop matches that live in another repository. Jobs are scoped to one
      # repository, and reaching across would silently audit records the user
      # may not be able to see.
      index.each_value { |matched| matched.select! { |id| @resources.key?(id) } }
      index
    end

    def build_resolution(entry, kind, matched_by, resource_id)
      row = @resources[resource_id]

      return Resolution.new(:input => entry.value, :kind => kind,
                            :error => 'Resource is not in this repository',
                            :error_kind => 'wrong_repository') if row.nil?

      mms_id = @mms_ids[resource_id]
      mms_id = nil if mms_id.to_s.strip.empty?

      Resolution.new(
        :input => entry.value,
        :kind => kind,
        :matched_by => matched_by,
        :resource_id => resource_id,
        :uri => JSONModel(:resource).uri_for(resource_id, :repo_id => @repo_id),
        :title => row[:title],
        :mms_id => mms_id,
        :ead_id => row[:ead_id],
        :identifier => format_identifier(row[:identifier]),
        :lock_version => row[:lock_version],
        :system_mtime => row[:system_mtime],
        :error => mms_id.nil? ? "Resource has no Alma MMS ID in user_defined.#{@mms_field}" : nil,
        :error_kind => mms_id.nil? ? 'no_mms_id' : nil
      )
    end

    def ambiguous(entry, kind, matches)
      uris = matches.map { |id| JSONModel(:resource).uri_for(id, :repo_id => @repo_id) }

      Resolution.new(
        :input => entry.value,
        :kind => kind,
        :error => "Matches #{matches.length} resources (#{uris.join(', ')}); identifier is not unique",
        :error_kind => 'ambiguous'
      )
    end

    def format_identifier(raw)
      parts = ASUtils.json_parse(raw || '[]')
      Array(parts).compact.join('--')
    rescue StandardError
      raw.to_s
    end
  end
end
