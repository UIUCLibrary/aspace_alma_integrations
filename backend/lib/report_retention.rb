require 'fileutils'

require_relative '../../lib/alma_integrations'

module AlmaIntegrations
  # Deletes the artefacts of old audit and update runs.
  #
  # This exists because ArchivesSpace does not clean up after itself: deleting a
  # job cascades away its `job_input_file` rows but leaves the files on disk
  # forever. An audit that stores Alma MARC snapshots for thousands of records
  # is not small, so without something like this the job file directory grows
  # without bound.
  #
  # Deliberately conservative:
  #
  #   * It does nothing at all unless AppConfig[:alma_audit_report_retention_days]
  #     is set. The default is to keep everything.
  #   * It only ever considers this plugin's own job types, and only jobs that
  #     have finished.
  #   * It removes stored files and the rows that point at them. It does not
  #     delete the `job` row, so the record that an audit was run, by whom, and
  #     when, survives the expiry of its data.
  class ReportRetention
    JOB_TYPES = %w[alma_audit_job alma_bulk_update_job].freeze
    TERMINAL_STATUSES = %w[completed failed canceled].freeze

    Result = Struct.new(:jobs, :files, :bytes, :errors, :keyword_init => true)

    def initialize(settings: nil, logger: nil)
      @settings = settings || Settings.new
      @logger = logger
    end

    def retention_days
      days = @settings[:report_retention_days]
      return nil if days.nil?

      days = days.to_i
      days > 0 ? days : nil
    end

    def enabled?
      !retention_days.nil?
    end

    def sweep
      result = Result.new(:jobs => 0, :files => 0, :bytes => 0, :errors => [])
      return result unless enabled?

      cutoff = Time.now - (retention_days * 24 * 60 * 60)

      expired_jobs(cutoff).each do |job_row|
        purge_job(job_row, result)
      end

      log("Retention: removed #{result.files} file(s) from #{result.jobs} expired run(s), " \
          "freeing #{result.bytes} bytes") if result.jobs > 0

      result
    end

    private

    def expired_jobs(cutoff)
      Job
        .any_repo
        .where(:job_type => JOB_TYPES)
        .where(:status => TERMINAL_STATUSES)
        .where { time_submitted < cutoff }
        .select(:id, :job_type, :time_submitted)
        .all
    end

    def purge_job(job_row, result)
      files = JobFile.where(:job_id => job_row[:id]).all
      return if files.empty? && !job_directory_exists?(job_row)

      files.each do |file|
        begin
          path = file.full_file_path
          if File.file?(path)
            result.bytes += File.size(path)
            File.unlink(path)
            result.files += 1
          end
        rescue StandardError => e
          result.errors << "Could not remove file for job #{job_row[:id]}: #{e.message}"
        end
      end

      JobFile.where(:job_id => job_row[:id]).delete

      remove_job_directory(job_row, result)
      result.jobs += 1
    end

    # The job's own directory also holds output.log, which the file rows do not
    # reference. Removing the directory is what actually reclaims the space.
    def job_directory(job_row)
      base = AppConfig[:job_file_path]
      return nil if base.nil?

      File.join(base, "#{job_row[:job_type]}_#{job_row[:id]}")
    end

    def job_directory_exists?(job_row)
      path = job_directory(job_row)
      !path.nil? && File.directory?(path)
    end

    def remove_job_directory(job_row, result)
      path = job_directory(job_row)
      return if path.nil? || !File.directory?(path)

      # Guard against a misconfigured job_file_path turning this into something
      # far more destructive than a cleanup.
      base = File.absolute_path(AppConfig[:job_file_path])
      target = File.absolute_path(path)
      unless target.start_with?(base + File::SEPARATOR) && target != base
        result.errors << "Refusing to remove #{target}: outside the job file path"
        return
      end

      FileUtils.remove_entry_secure(target)
    rescue StandardError => e
      result.errors << "Could not remove directory for job #{job_row[:id]}: #{e.message}"
    end

    def log(message)
      @logger.call(message) if @logger.respond_to?(:call)
    end
  end
end
