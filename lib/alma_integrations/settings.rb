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
      # Which Alma instance the API key points at. The hostname is the same for
      # both, so this cannot be detected: the key alone decides, and only the
      # person who pasted it in knows which one it is.
      #
      # It matters because sandbox is governed far more tightly than production.
      # A run tuned for production spends its sandbox calls on 429s, and a
      # rejected request is charged like any other, so a mistuned test run
      # quietly eats the allowance it was meant to be protecting.
      :environment                 => 'production',

      # Alma's governance threshold is per institution rather than per API key,
      # so it is shared with every other integration on campus. We stay well
      # under the production ceiling by default; sandbox runs are clamped to
      # SANDBOX_REQUESTS_PER_SECOND regardless of what is configured here.
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

      # The MARC record as it currently stands in Alma is always kept in the
      # report. It is the failsafe: if an update turns out to have been a
      # mistake, this is the copy of what Alma held beforehand.
      :store_alma_marc             => true,
      # The outgoing record can always be regenerated from ArchivesSpace, so it
      # is only stored on request.
      :store_outgoing_marc         => false,
      :include_unpublished         => false,

      # How long audit reports and their MARC snapshots are kept, in days.
      # nil (the default) keeps them indefinitely.
      :report_retention_days       => nil,

      # Copy each Alma MARC record into the plan file as well as the report, so
      # that a bulk update run from this audit can skip reading Alma a second
      # time and cost one API call per record instead of two.
      #
      # Off by default because it makes the plan file large -- the plan exists
      # precisely so the updater never has to hold a multi-megabyte document in
      # memory -- and because it is only any use to a run that opts in to
      # reusing it.
      :plan_includes_alma_marc     => false,

      # --- Update behaviour -------------------------------------------------
      # Refuse to overwrite an Alma record that changed after it was audited.
      :stale_version_check         => true,
      # Reuse the Alma MARC the audit already stored in the plan rather than
      # reading each record from Alma again, taking the update from two API
      # calls per record to one.
      #
      # Opt-in, because it trades a snapshot taken moments before the write for
      # one taken when the audit ran. What makes that trade survivable rather
      # than reckless is :stale_version_check: the outgoing record carries the
      # 005 from the audit-time snapshot, so if Alma's copy has moved at all
      # since, Alma rejects the write and the record is reported as skipped
      # rather than silently overwritten from a stale base.
      :reuse_audit_marc            => false,
      # Refuse to push a Resource that changed in ArchivesSpace after it was
      # audited, since the audit no longer describes what would be sent.
      :check_aspace_changes        => true,
      # Network Zone linked records are only partially replaced by a bib PUT, so
      # they are excluded from bulk updates unless explicitly opted in.
      :include_nz_linked           => false,

      # --- Arclight link (MARC 956) ----------------------------------------
      # Root URL of the Arclight instance, e.g.
      # 'https://arclight.example.edu'. Leaving it unset switches the 956 off
      # entirely: there is no sensible default for somebody else's hostname,
      # and a guessed one would push dead links into the catalogue.
      :arclight_base_url           => nil,

      # Which ArchivesSpace field the Arclight slug is built from. Arclight
      # derives its root ID from <eadid> as shipped, but an institution whose
      # EAD IDs are blank or unrelated to its call numbers indexes something
      # else. 'auto' prefers the EAD ID and falls back to the Resource
      # identifier; 'ead_id' and 'identifier' pin it.
      :arclight_id_source          => 'auto',

      # Default text for the link's $y. Overridable per run.
      :arclight_link_text          => 'Finding aid online',

      # Indicators for the 956. 956 is a locally defined field, so these are
      # institutional practice rather than MARC law; the default mirrors the
      # 4/2 ArchivesSpace itself uses for the finding aid 856.
      :arclight_indicators         => '42'
    }.freeze

    # Alma's sandbox is reported to allow roughly a tenth of production's
    # throughput. Running above it does not fail fast: requests come back 429,
    # get retried, and are charged on the way in and on the way out. Clamping
    # costs a sandbox run some wall-clock time and saves it real quota.
    SANDBOX_REQUESTS_PER_SECOND = 8

    SANDBOX_ENVIRONMENTS = %w[sandbox test].freeze

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
        :environment          => :alma_api_environment,
        :recommend_threshold  => :alma_audit_recommend_threshold,
        :include_unpublished  => :alma_include_unpublished,
        :store_alma_marc      => :alma_audit_store_alma_marc,
        :report_retention_days => :alma_audit_report_retention_days,
        :arclight_base_url    => :alma_arclight_base_url,
        :arclight_id_source   => :alma_arclight_id_source,
        :arclight_link_text   => :alma_arclight_link_text,
        :arclight_indicators  => :alma_arclight_indicators
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
      apply_environment_ceiling!
    end

    # True when this is pointed at a sandbox instance.
    def sandbox?
      SANDBOX_ENVIRONMENTS.include?(self[:environment].to_s.strip.downcase)
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
        'store_alma_marc'       => !!self[:store_alma_marc],
        'store_outgoing_marc'   => !!self[:store_outgoing_marc],
        'mms_field'             => self[:mms_field]
      }
    end

    private

    # Sandbox cannot be inferred from the API URL -- production and sandbox sit
    # behind the same gateway hostname and the key alone decides which instance
    # answers -- so this trusts the configured environment and clamps rather
    # than guesses. The clamp only ever lowers the rate, so an institution that
    # has deliberately configured something slower keeps it.
    def apply_environment_ceiling!
      return unless sandbox?

      configured = @values[:requests_per_second].to_f
      return if configured <= 0 || configured <= SANDBOX_REQUESTS_PER_SECOND

      @values = @values.merge(:requests_per_second => SANDBOX_REQUESTS_PER_SECOND)
    end

    def symbolize(hash)
      (hash || {}).each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
    end
  end
end
