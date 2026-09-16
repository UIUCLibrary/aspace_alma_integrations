require_relative 'version'

module AlmaIntegrations
  # Central home for every tunable in the plugin, with defaults that are safe for
  # an institution that has not configured anything.
  #
  # Nothing in this file may reference AppConfig directly: the pure library has to
  # be loadable (and testable) outside of ArchivesSpace. Instead, ArchivesSpace
  # wiring calls Settings.from_app_config, which reads AppConfig defensively.
  class Settings

    DEFAULTS = {
      # --- Alma API access -------------------------------------------------
      :api_url                     => nil,
      :api_key                     => nil,

      # --- Rate limiting ---------------------------------------------------
      # Alma's documented governance threshold is 25 requests/second per
      # institution (not per API key), shared with every other integration on
      # campus. We stay well under it by default.
      :requests_per_second         => 19,
      :max_retries                 => 5,
      :retry_base_delay            => 1.0,
      :retry_max_delay             => 30.0,
      :open_timeout                => 15,
      :read_timeout                => 120,

      # Abort a long run rather than consume the last of the institution's daily
      # API allowance. Set to 0 to disable the check.
      :daily_quota_floor           => 1000,

      # --- Record identification -------------------------------------------
      # The Resource user_defined field that holds the Alma MMS ID.
      :mms_field                   => 'string_2',

      # --- MARC comparison --------------------------------------------------
      # Fields that differ mechanically on every single record and would other-
      # wise swamp the audit summary. They are still present in the per-record
      # detail of the report, just excluded from the headline counts.
      :ignored_tags                => %w[001 003 005].freeze,

      # Alma's multi-record GET enriches each returned record with extra 035
      # fields carrying the Network Zone and Community Zone identifiers. Those
      # are API artifacts rather than stored data, and comparing against them
      # would report a phantom 035 loss on every record.
      :ignore_value_patterns       => [/\A\(EXLNZ-/, /\A\(EXLCZ/].freeze,

      :normalize_whitespace        => true,
      :normalize_punctuation       => true,
      :normalize_case              => false,

      # Tags carried over from Alma into the outgoing record before pushing.
      :preserved_tags              => [].freeze,

      # --- Audit behaviour --------------------------------------------------
      :bulk_fetch_size             => 100,
      :recommend_threshold         => 0.25,
      :include_full_marc           => false,
      :include_unpublished         => false,

      # --- Update behaviour -------------------------------------------------
      # Refuse to overwrite an Alma record that changed after it was audited.
      :stale_version_check         => true,
      # Refuse to push a Resource that changed in ArchivesSpace after it was
      # audited, since the audit no longer describes what would be sent.
      :check_aspace_changes        => true,
      # Network Zone linked records are only partially replaced by a bib PUT, so
      # they are excluded from bulk updates unless explicitly opted in.
      :include_nz_linked           => false
    }.freeze

    def self.from_app_config(overrides = {})
      values = {}

      values[:api_url]  = app_config(:alma_api_url)
      values[:api_key]  = app_config(:alma_apikey)

      preserved = app_config(:alma_marc_fields_to_preserve)
      values[:preserved_tags] = Array(preserved).map(&:to_s) unless preserved.nil?

      mms_field = app_config(:alma_mms_id_field)
      values[:mms_field] = mms_field.to_s unless mms_field.nil?

      {
        :requests_per_second  => :alma_requests_per_second,
        :daily_quota_floor    => :alma_daily_quota_floor,
        :max_retries          => :alma_max_retries,
        :open_timeout         => :alma_open_timeout,
        :read_timeout         => :alma_read_timeout,
        :bulk_fetch_size      => :alma_bulk_fetch_size,
        :recommend_threshold  => :alma_audit_recommend_threshold,
        :include_unpublished  => :alma_include_unpublished
      }.each do |key, app_config_key|
        value = app_config(app_config_key)
        values[key] = value unless value.nil?
      end

      ignored = app_config(:alma_audit_ignored_tags)
      values[:ignored_tags] = Array(ignored).map(&:to_s) unless ignored.nil?

      new(values.merge(overrides))
    end

    def self.app_config(key)
      return nil unless defined?(AppConfig)
      return nil unless AppConfig.has_key?(key)

      AppConfig[key]
    rescue StandardError
      nil
    end

    def initialize(values = {})
      @values = DEFAULTS.merge(symbolize(values).reject { |_, v| v.nil? })
    end

    def [](key)
      @values[key.to_sym]
    end

    def fetch(key, default = nil)
      value = @values[key.to_sym]
      value.nil? ? default : value
    end

    def merge(other)
      self.class.new(@values.merge(symbolize(other)))
    end

    def to_h
      @values.dup
    end

    # The subset of settings that belong in the audit report so a reader can tell
    # how the numbers were produced. Deliberately excludes the API key.
    def diff_parameters
      {
        'ignored_tags'          => Array(self[:ignored_tags]),
        'preserved_tags'        => Array(self[:preserved_tags]),
        'normalize_whitespace'  => !!self[:normalize_whitespace],
        'normalize_punctuation' => !!self[:normalize_punctuation],
        'normalize_case'        => !!self[:normalize_case],
        'include_unpublished'   => !!self[:include_unpublished],
        'include_full_marc'     => !!self[:include_full_marc],
        'mms_field'             => self[:mms_field]
      }
    end

    private

    def symbolize(hash)
      (hash || {}).each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
    end
  end
end
