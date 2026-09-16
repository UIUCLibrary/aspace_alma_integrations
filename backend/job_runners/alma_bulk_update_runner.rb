require_relative '../lib/alma_job_support'

# Pushes ArchivesSpace records to Alma in bulk.
#
# This is the destructive half of the feature, so its defaults are set to make
# damage difficult: it insists on a prior audit, it runs as a dry run unless
# told otherwise, it holds back Network Zone linked records, it refuses records
# that either system has changed since the audit, and it writes a snapshot of
# every Alma record immediately before overwriting it.
class AlmaBulkUpdateRunner < JobRunner
  include AlmaIntegrations::JobSupport

  register_for_job_type('alma_bulk_update_job',
                        :create_permissions => :update_alma_records,
                        :cancel_permissions => :update_alma_records,
                        :run_concurrently => false)

  def run
    RequestContext.open(:repo_id => @job.repo_id) do
      begin
        update
      rescue AlmaIntegrations::JobSupport::CanceledError
        log('')
        log('Cancelled. Records already sent to Alma have been applied; the rest were not attempted.')
        finalise(:stopped_early => 'Cancelled by request')
      rescue AlmaIntegrations::DailyThresholdError, AlmaIntegrations::QuotaFloorError => e
        log('')
        log("Stopped: #{e.message}")
        log('Re-running this job will skip the records that already succeeded.')
        finalise(:stopped_early => e.message)
        self.success!
      rescue StandardError => e
        log('')
        log("Failed: #{e.message}")
        e.backtrace.first(15).each { |line| log("    #{line}") }
        raise
      ensure
        close_resources
      end
    end
  end

  private

  def close_resources
    @results.close if @results
    @snapshots.close if @snapshots
    @alma_client.close if @alma_client
  rescue StandardError
    nil
  end

  def update
    @started_at = Time.now
    @counts = Hash.new(0)
    @updated_uris = []

    log_heading(dry_run? ? 'Alma bulk update (DRY RUN)' : 'Alma bulk update')
    log('No requests will be sent to Alma. This run reports what would happen.') if dry_run?
    describe_rate_limiting
    describe_safety_settings

    plan = load_plan
    check_canceled!

    @results = AlmaIntegrations::JsonLinesWriter.new('alma-update-results')
    @snapshots = AlmaIntegrations::JsonLinesWriter.new('alma-update-snapshot')

    apply(plan)

    finalise
    self.success!
  end

  def dry_run?
    truthy(job_param('dry_run'))
  end

  def describe_safety_settings
    log("Network Zone linked records: #{settings[:include_nz_linked] ? 'included' : 'held back'}")
    log("Alma version check: #{settings[:stale_version_check] ? 'on' : 'off'}")
    log("ArchivesSpace change check: #{settings[:check_aspace_changes] ? 'on' : 'off'}")
    log("Records already identical: #{skip_identical? ? 'skipped' : 'pushed anyway'}")
  end

  def skip_identical?
    job_param?('skip_identical') ? truthy(job_param('skip_identical')) : true
  end

  # --- Plan ----------------------------------------------------------------

  # The list of records to push, and what the audit knew about each of them.
  def load_plan
    audit_job_id = job_param('audit_job_id')

    if audit_job_id.nil? || audit_job_id.to_s.strip.empty?
      unless truthy(job_param('skip_audit'))
        raise AlmaIntegrations::Error,
              'No audit report was selected. Run an audit first, or tick "skip the audit" to ' \
              'push without one.'
      end

      return plan_from_identifiers
    end

    plan_from_audit(audit_job_id.to_i)
  end

  def plan_from_audit(audit_job_id)
    log_heading("Reading audit report from job #{audit_job_id}")

    audit_job = Job.any_repo[audit_job_id]
    raise AlmaIntegrations::Error, "Audit job #{audit_job_id} does not exist." if audit_job.nil?

    unless audit_job.repo_id == @job.repo_id
      raise AlmaIntegrations::Error, "Audit job #{audit_job_id} belongs to another repository."
    end

    unless audit_job.job_type == 'alma_audit_job'
      raise AlmaIntegrations::Error, "Job #{audit_job_id} is not an Alma audit."
    end

    unless audit_job.status == 'completed'
      raise AlmaIntegrations::Error,
            "Audit job #{audit_job_id} finished with status #{audit_job.status.inspect}; " \
            'only a completed audit can be applied.'
    end

    @audit_job_id = audit_job_id
    @audit_summary = (audit_job.job['summary'] rescue nil) || {}

    path = audit_plan_path(audit_job)
    entries = []
    AlmaIntegrations::JsonLinesWriter.each(path) do |entry, error|
      if error
        log("  ! Skipped an unreadable line in the audit plan: #{error}")
        next
      end

      entries << entry
    end

    log("#{entries.length} record(s) in the audit.")
    log("The audit ran #{time_since(audit_job.time_finished)} ago.") if audit_job.time_finished

    entries
  end

  # The audit records which of its output files is the plan, because the
  # output_files endpoint exposes ids with no names attached.
  def audit_plan_path(audit_job)
    descriptor = Array(@audit_summary['files']).find { |file| file['label'] == 'plan' }

    if descriptor && descriptor['id']
      job_file = JobFile[descriptor['id']]
      return job_file.full_file_path if job_file && File.file?(job_file.full_file_path)
    end

    # Fall back to the most recent .jsonl attached to that job.
    candidate = audit_job.job_files.map(&:full_file_path).select { |path| File.file?(path) }.last
    raise AlmaIntegrations::Error, "Audit job #{audit_job.id} has no readable plan file." if candidate.nil?

    candidate
  end

  # The unaudited path. Resolves identifiers but knows nothing about what the
  # push would destroy, which is why the form makes this deliberately awkward.
  def plan_from_identifiers
    log_heading('Reading the list of records (no audit)')
    log('! This run has no audit behind it. Nothing has checked what these updates would overwrite.')

    list = collect_identifiers
    resolver = AlmaIntegrations::ResourceResolver.new(
      :repo_id => @job.repo_id,
      :settings => settings,
      :collection_id_field => job_param('collection_id_field').to_s
    )

    entries = []
    resolver.resolve(list.entries) do |resolution|
      if resolution.ok?
        entries << {
          'mms_id' => resolution.mms_id,
          'resource_id' => resolution.resource_id,
          'resource_uri' => resolution.uri,
          'title' => resolution.title,
          'input' => resolution.input,
          'nz_linked' => nil,
          'has_loss' => nil,
          'has_change' => nil,
          'aspace_lock_version' => resolution.lock_version
        }
      else
        record_result(resolution.input, nil, 'skipped', resolution.error, :resource_uri => resolution.uri)
      end
    end

    log("#{entries.length} record(s) resolved.")
    entries
  end

  # --- Application ---------------------------------------------------------

  def apply(plan)
    return if plan.empty?

    log_heading(dry_run? ? 'Checking records' : 'Updating Alma')

    generator = AlmaIntegrations::AspaceMarcGenerator.new(:settings => settings)
    total = plan.length
    done = 0

    plan.each do |entry|
      check_canceled!
      done += 1

      begin
        process(entry, generator)
      rescue AlmaIntegrations::DailyThresholdError, AlmaIntegrations::QuotaFloorError
        raise
      rescue AlmaIntegrations::JobSupport::CanceledError
        raise
      rescue StandardError => e
        record_result(entry['input'], entry['mms_id'], 'failed', "#{e.class}: #{e.message}",
                      :resource_uri => entry['resource_uri'])
      end

      report_progress(done, total)
    end
  end

  def process(entry, generator)
    mms_id = entry['mms_id']
    reason = skip_reason(entry)

    if reason
      record_result(entry['input'], mms_id, 'skipped', reason, :resource_uri => entry['resource_uri'])
      return
    end

    # Fetch the record as it stands right now. This is both the failsafe
    # snapshot and the source of the fields we preserve.
    current = fetch_current(mms_id)
    return if current.nil?

    alma_record = AlmaIntegrations::MarcRecord.parse(current)

    if stale?(entry, alma_record)
      record_result(entry['input'], mms_id, 'skipped',
                    'Alma’s copy changed after the audit ran. Re-audit this record before pushing it.',
                    :resource_uri => entry['resource_uri'])
      return
    end

    if aspace_changed?(entry)
      record_result(entry['input'], mms_id, 'skipped',
                    'The ArchivesSpace resource changed after the audit ran. Re-audit before pushing.',
                    :resource_uri => entry['resource_uri'])
      return
    end

    zone = AlmaIntegrations::NetworkZone.detect(alma_record)
    if zone.linked? && !settings[:include_nz_linked]
      record_result(entry['input'], mms_id, 'skipped',
                    'Linked to the Network Zone; a bib update would only replace local fields.',
                    :resource_uri => entry['resource_uri'])
      return
    end

    # Snapshot before anything is sent, so there is always a copy of what Alma
    # held even if the push is wrong.
    @snapshots.add(
      'mms_id' => mms_id,
      'resource_uri' => entry['resource_uri'],
      'captured_at' => Time.now.utc.iso8601,
      'alma_marc' => alma_record.to_xml
    )

    result = generator.outgoing(entry['resource_id'], current,
                                :include_unpublished => settings[:include_unpublished])

    if dry_run?
      record_result(entry['input'], mms_id, 'would_update', nil,
                    :resource_uri => entry['resource_uri'],
                    :warnings => result.warnings)
      return
    end

    push(entry, mms_id, result)
  end

  def skip_reason(entry)
    return 'No MMS ID' if entry['mms_id'].to_s.strip.empty?
    return 'No ArchivesSpace resource' if entry['resource_id'].nil?

    if skip_identical? && entry['has_loss'] == false && entry['has_change'] == false &&
       entry['has_addition'] == false
      return 'Already identical to Alma'
    end

    nil
  end

  def fetch_current(mms_id)
    response = alma_client.get("/bibs/#{mms_id}")

    unless response.success?
      record_result(nil, mms_id, 'failed', "Could not read the record from Alma: #{response.error_message}")
      return nil
    end

    document = Nokogiri::XML(response.body)
    document.remove_namespaces! unless document.root.nil?
    record = document.at_xpath('//record')

    if record.nil?
      record_result(nil, mms_id, 'failed', 'Alma returned no MARC record')
      return nil
    end

    record
  end

  # Alma stamps every record with an 005 when it changes. Comparing it against
  # the value captured at audit time catches anyone who edited the record in
  # between -- including another ArchivesSpace job.
  def stale?(entry, alma_record)
    return false unless settings[:stale_version_check]

    audited = entry['alma_005']
    return false if audited.nil? || audited.to_s.empty?

    current = alma_record.controlfield_value('005')
    return false if current.nil? || current.to_s.empty?

    current.to_s.strip != audited.to_s.strip
  end

  def aspace_changed?(entry)
    return false unless settings[:check_aspace_changes]

    audited = entry['aspace_lock_version']
    return false if audited.nil?

    row = Resource.where(:id => entry['resource_id'], :repo_id => @job.repo_id)
                  .select(:lock_version).first
    return false if row.nil?

    row[:lock_version].to_i != audited.to_i
  end

  def push(entry, mms_id, preserve_result)
    query = {}
    # Letting Alma enforce the version check is better than doing it ourselves:
    # it closes the gap between our read and our write.
    query['stale_version_check'] = 'true' if settings[:stale_version_check]

    response = alma_client.put("/bibs/#{mms_id}", preserve_result.to_xml, query)

    if response.success?
      @updated_uris << entry['resource_uri'] if entry['resource_uri']
      record_result(entry['input'], mms_id, 'updated', nil,
                    :resource_uri => entry['resource_uri'],
                    :warnings => preserve_result.warnings)
    elsif version_conflict?(response)
      record_result(entry['input'], mms_id, 'skipped',
                    'Alma rejected the update: a newer version of the record exists. Re-audit and try again.',
                    :resource_uri => entry['resource_uri'])
    else
      record_result(entry['input'], mms_id, 'failed', response.error_message,
                    :resource_uri => entry['resource_uri'])
    end
  end

  # Alma reports a stale write as a 400 with error code 4022034.
  def version_conflict?(response)
    return true if response.errors.any? { |error| error.code.to_s == '4022034' }

    response.error_message.to_s.include?('newer version of this record')
  end

  def record_result(input, mms_id, status, message, resource_uri: nil, warnings: nil)
    @counts[status] += 1

    if @results
      @results.add(
        'input' => input,
        'mms_id' => mms_id,
        'resource_uri' => resource_uri,
        'status' => status,
        'message' => message,
        'warnings' => (warnings.nil? || warnings.empty? ? nil : warnings)
      )
    end

    log("  ! #{mms_id || input}: #{message}") if %w[failed skipped].include?(status) && message
  end

  def time_since(time)
    seconds = (Time.now - time).to_i
    return "#{seconds} second(s)" if seconds < 60
    return "#{seconds / 60} minute(s)" if seconds < 3600
    return "#{seconds / 3600} hour(s)" if seconds < 86_400

    "#{seconds / 86_400} day(s)"
  end

  # --- Output --------------------------------------------------------------

  def finalise(stopped_early: nil)
    return if @results.nil?

    log_heading('Writing the results')

    summary = {
      'dry_run' => dry_run?,
      'audit_job_id' => @audit_job_id,
      'counts' => @counts.dup,
      'records' => {
        'updated' => @counts['updated'],
        'would_update' => @counts['would_update'],
        'skipped' => @counts['skipped'],
        'failed' => @counts['failed']
      },
      'alma_requests' => (@alma_client ? alma_client.request_count : 0),
      'duration_seconds' => (Time.now - @started_at).round(1),
      'job_id' => @job.id
    }
    summary['stopped_early'] = stopped_early if stopped_early

    files = []
    files << attach_file(@results.file,
                         :label => 'results',
                         :filename => "alma_update_results_#{@job.id}.jsonl",
                         :description => 'Outcome for every record in the run')

    if @snapshots.count > 0
      files << attach_file(@snapshots.file,
                           :label => 'snapshot',
                           :filename => "alma_update_snapshot_#{@job.id}.jsonl",
                           :description => 'Alma MARC as it stood immediately before each update')
    end

    summary['files'] = files
    store_summary(summary)

    record_modified_resources

    log('')
    log("Updated:      #{@counts['updated']}")
    log("Would update: #{@counts['would_update']}") if dry_run?
    log("Skipped:      #{@counts['skipped']}")
    log("Failed:       #{@counts['failed']}")
    log('')
    log("Alma API calls: #{summary['alma_requests']}. Duration: #{summary['duration_seconds']}s.")

    if @snapshots.count > 0
      log("A snapshot of #{@snapshots.count} Alma record(s) as they stood before the update is " \
          'attached to this job.')
    end
  end

  # Links the affected resources to the job so they show up under its modified
  # records, giving a trail from a catalogue change back to the run that caused
  # it.
  def record_modified_resources
    return if @updated_uris.empty?

    @job.record_modified_uris(@updated_uris.uniq)
  rescue StandardError => e
    log("  ! Could not link the updated resources to this job: #{e.message}")
  end
end
