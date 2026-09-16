require_relative '../../lib/alma_integrations'
require_relative 'resource_resolver'
require_relative 'aspace_marc_generator'
require_relative 'report_retention'

module AlmaIntegrations
  # Behaviour shared by the audit and bulk update job runners.
  #
  # Nothing here runs at load time. ArchivesSpace requires job runner files very
  # early in backend boot -- before the database is connected and before the
  # models are defined -- so everything that touches a model has to wait until
  # the job is actually running.
  module JobSupport
    # How often progress is written to the job log. Every record would make the
    # log unreadable and the file enormous on a run of several thousand.
    PROGRESS_INTERVAL = 25

    def settings
      @settings ||= begin
        base = Settings.from_app_config
        base.merge(settings_overrides)
      end
    end

    # Form values win over AppConfig, but only where the form actually offers a
    # choice. Everything else stays under the administrator's control.
    def settings_overrides
      overrides = {}

      overrides[:include_unpublished] = truthy(job_param('include_unpublished')) if job_param?('include_unpublished')
      overrides[:store_alma_marc] = truthy(job_param('store_alma_marc')) if job_param?('store_alma_marc')
      overrides[:store_outgoing_marc] = truthy(job_param('store_outgoing_marc')) if job_param?('store_outgoing_marc')
      overrides[:include_nz_linked] = truthy(job_param('include_nz_linked')) if job_param?('include_nz_linked')
      overrides[:stale_version_check] = truthy(job_param('stale_version_check')) if job_param?('stale_version_check')
      overrides[:check_aspace_changes] = truthy(job_param('check_aspace_changes')) if job_param?('check_aspace_changes')

      overrides
    end

    def job_payload
      @job_payload ||= (@json.job || {})
    end

    def job_param(key)
      job_payload[key.to_s]
    end

    def job_param?(key)
      !job_payload[key.to_s].nil?
    end

    def truthy(value)
      return false if value.nil?
      return value if value == true || value == false

      %w[true 1 yes on].include?(value.to_s.strip.downcase)
    end

    # --- Logging -------------------------------------------------------------

    def log(message)
      @job.write_output(message)
    end

    def log_heading(message)
      log('')
      log(message)
      log('-' * message.length)
    end

    def logger_proc
      @logger_proc ||= ->(message) { log(message) }
    end

    def report_progress(done, total, noun = 'records')
      return unless done == total || (done % PROGRESS_INTERVAL).zero?

      percent = total.to_i > 0 ? ((done.to_f / total) * 100).round : 0
      log("  #{done}/#{total} #{noun} (#{percent}%)")
    end

    # --- Cancellation --------------------------------------------------------

    def check_canceled!
      raise CanceledError if canceled?
    end

    class CanceledError < StandardError; end

    # --- Input ---------------------------------------------------------------

    # Combines the pasted list with any uploaded files. Both are accepted at
    # once so a user can add a couple of stragglers to a file without editing
    # the file.
    def collect_identifiers
      sources = []

      pasted = job_param('identifiers').to_s
      sources << pasted unless pasted.strip.empty?

      uploaded_files.each do |path|
        begin
          sources << File.read(path, :mode => 'rb')
        rescue StandardError => e
          log("  ! Could not read uploaded file: #{e.message}")
        end
      end

      raise Error, 'No identifiers were supplied. Paste a list or upload a file.' if sources.empty?

      column = job_param('csv_column').to_i
      skip_header = job_param?('skip_header') ? truthy(job_param('skip_header')) : nil

      combined = nil
      sources.each do |source|
        list = IdentifierList.parse(source, :column => column, :skip_header => skip_header)
        combined = combined.nil? ? list : merge_lists(combined, list)
      end

      apply_identifier_type(combined)
    end

    def merge_lists(first, second)
      seen = first.entries.map(&:value)

      second.entries.each do |entry|
        if seen.include?(entry.value)
          first.duplicates << entry.value
        else
          first.entries << entry
          seen << entry.value
        end
      end

      first.problems.concat(second.problems)
      first
    end

    # An explicit choice on the form overrides the per-line guess, except where
    # the user prefixed a line with `mms:` or `ead:`, which is as explicit as it
    # gets.
    def apply_identifier_type(list)
      type = job_param('identifier_type').to_s
      return list unless %w[mms collection].include?(type)

      list.entries.each do |entry|
        next if entry.explicit

        entry.kind = type.to_sym
      end

      list
    end

    def uploaded_files
      @job.job_files.map(&:full_file_path).select { |path| File.file?(path) }
    rescue StandardError
      []
    end

    # --- Output --------------------------------------------------------------

    # Attaches a file to the job and returns a descriptor the report page can
    # use. ArchivesSpace's output_files endpoint returns ids with no names or
    # types, so the job has to record which id is which itself.
    def attach_file(io, label:, filename:, description: nil)
      io.flush if io.respond_to?(:flush)
      io.rewind if io.respond_to?(:rewind)

      job_file = @job.add_file(io)

      {
        'id' => job_file.respond_to?(:id) ? job_file.id : nil,
        'label' => label,
        'filename' => filename,
        'description' => description,
        'bytes' => (File.size(io.path) rescue nil)
      }
    end

    # Merges results into the job blob so the report page can render without
    # parsing the report file. Merged rather than replaced: the blob is also the
    # record of what the user asked for, and overwriting it would lose that.
    def store_summary(summary)
      blob = job_payload.merge('summary' => summary)
      @job.job_blob = ASUtils.to_json(blob)
      @job.save
    rescue StandardError => e
      # A summary we cannot store is not worth failing a completed run over --
      # the report file on disk is the authoritative copy.
      log("  ! Could not store the summary on the job: #{e.message}")
    end

    def sweep_expired_reports
      retention = ReportRetention.new(:settings => settings, :logger => logger_proc)
      return unless retention.enabled?

      result = retention.sweep
      result.errors.each { |message| log("  ! #{message}") }
    rescue StandardError => e
      log("  ! Retention sweep failed: #{e.message}")
    end

    # --- Alma ----------------------------------------------------------------

    def alma_client
      @alma_client ||= begin
        if settings[:api_url].to_s.empty? || settings[:api_key].to_s.empty?
          raise Error, 'Alma is not configured. Set AppConfig[:alma_api_url] and AppConfig[:alma_apikey].'
        end

        AlmaClient.new(:settings => settings, :logger => logger_proc)
      end
    end

    def describe_rate_limiting
      log("Alma requests are capped at #{settings[:requests_per_second]}/second across this " \
          'ArchivesSpace instance.')
      floor = settings[:daily_quota_floor].to_i
      log("The job stops if Alma's remaining daily allowance falls below #{floor}.") if floor > 0
    end
  end
end
