require_relative '../lib/alma_job_support'

# Compares the MARC record Alma holds against the MARC record ArchivesSpace
# would send, for a list of records, and writes the result as JSON.
#
# The point is to answer one question before anybody presses the button: what
# would we lose if we let ArchivesSpace overwrite these catalogue records?
#
# Nothing here touches a model or JSONModel at load time. ArchivesSpace requires
# job runner files at the very top of backend boot, before the database is
# connected, so any model reference outside `run` would break the backend.
class AlmaAuditRunner < JobRunner
  include AlmaIntegrations::JobSupport

  register_for_job_type('alma_audit_job',
                        :create_permissions => :update_resource_record,
                        :cancel_permissions => :update_resource_record,
                        :run_concurrently => false)

  def run
    RequestContext.open(:repo_id => @job.repo_id) do
      begin
        audit
      rescue AlmaIntegrations::JobSupport::CanceledError
        # Returning normally is what tells ArchivesSpace this was a cancellation
        # rather than a failure; raising here would mark the job failed. The
        # work done so far is still written out, because discarding hours of
        # audit because someone pressed cancel would be its own kind of bug.
        log('')
        log('Cancelled. Saving the partial report.')
        finalise(:stopped_early => 'Cancelled by request')
      rescue AlmaIntegrations::DailyThresholdError, AlmaIntegrations::QuotaFloorError => e
        # Running out of Alma quota is an expected operational outcome, not a
        # bug. Everything audited so far is still written out so the run is not
        # wasted and can be resumed from where it stopped.
        log('')
        log("Stopped: #{e.message}")
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
    @writer.close if @writer
    @plan.close if @plan
    @alma_client.close if @alma_client
  rescue StandardError
    nil
  end

  def audit
    @started_at = Time.now
    @summary = AlmaIntegrations::ReportSummary.new(settings)

    log_heading('Alma audit')
    log("Repository: #{@job.repo_id}")
    log("Alma MMS ID is read from user_defined.#{settings[:mms_field]}")
    describe_rate_limiting
    sweep_expired_reports

    resolutions = resolve_input
    check_canceled!

    @writer = AlmaIntegrations::ReportWriter.new(report_parameters)
    @plan = AlmaIntegrations::JsonLinesWriter.new('alma-audit-plan')

    auditable = record_resolution_errors(resolutions)
    compare(auditable)

    finalise
    self.success!
  end

  # --- Input ---------------------------------------------------------------

  def resolve_input
    log_heading('Reading the list of records')

    list = collect_identifiers
    log("#{list.entries.length} identifier(s) to audit.")
    log("Skipped a header row: #{list.header.inspect}") if list.header
    log("Ignored #{list.duplicates.length} duplicate line(s).") unless list.duplicates.empty?

    list.problems.each do |problem|
      log("  ! line #{problem.line}: #{problem.reason} (#{problem.raw.inspect})")
    end

    raise AlmaIntegrations::Error, 'The list contained no usable identifiers.' if list.empty?

    @summary.record_submitted(list.entries.length)

    log_heading('Matching identifiers to ArchivesSpace resources')
    resolver = AlmaIntegrations::ResourceResolver.new(
      :repo_id => @job.repo_id,
      :settings => settings,
      :collection_id_field => job_param('collection_id_field').to_s
    )

    resolutions = resolver.resolve(list.entries).to_a
    matched = resolutions.count(&:ok?)
    log("Matched #{matched} of #{resolutions.length}.")

    flag_shared_mms_ids(resolutions)
    resolutions
  end

  # Two resources pointing at one bib means whichever is pushed last wins, and
  # the other's contribution disappears. Worth catching before anything is
  # pushed rather than explaining afterwards.
  def flag_shared_mms_ids(resolutions)
    by_mms = Hash.new { |hash, key| hash[key] = [] }

    resolutions.each do |resolution|
      next unless resolution.ok? && resolution.mms_id
      by_mms[resolution.mms_id] << resolution
    end

    by_mms.each do |mms_id, sharing|
      next if sharing.length < 2

      inputs = sharing.map(&:input).join(', ')
      message = "MMS ID #{mms_id} is claimed by #{sharing.length} resources (#{inputs}). " \
                'Updating them all would leave only the last one applied.'
      @summary.add_warning(message)
      log("  ! #{message}")

      sharing.each do |resolution|
        resolution.error = message
        resolution.error_kind = 'shared_mms_id'
      end
    end
  end

  def record_resolution_errors(resolutions)
    auditable = []

    resolutions.each do |resolution|
      if resolution.ok?
        auditable << resolution
        next
      end

      @summary.add_error(resolution.error_kind || 'unresolved')
      @writer.add_error(
        'input' => resolution.input,
        'kind' => resolution.kind,
        'error_kind' => resolution.error_kind,
        'error' => resolution.error,
        'resource_uri' => resolution.uri,
        'mms_id' => resolution.mms_id
      )
    end

    auditable
  end

  # --- Comparison ----------------------------------------------------------

  def compare(resolutions)
    return if resolutions.empty?

    log_heading('Comparing Alma records with ArchivesSpace')
    log("Fetching in batches of up to #{settings[:bulk_fetch_size]}; " \
        "#{fetch_estimate(resolutions.length)} Alma call(s) expected.")

    by_mms = {}
    resolutions.each { |resolution| by_mms[resolution.mms_id] = resolution }

    diff = AlmaIntegrations::MarcDiff.new(settings)
    generator = AlmaIntegrations::AspaceMarcGenerator.new(:settings => settings)
    done = 0
    total = resolutions.length

    alma_client.each_bib(by_mms.keys) do |mms_id, alma_record, error|
      check_canceled!
      resolution = by_mms[mms_id]
      done += 1

      begin
        if error
          record_error(resolution, 'alma_error', error.respond_to?(:message) ? error.message : error.to_s)
        elsif alma_record.nil?
          record_error(resolution, 'alma_not_found', "Alma has no bib for MMS ID #{mms_id}")
        else
          audit_record(resolution, alma_record, diff, generator)
        end
      rescue AlmaIntegrations::DailyThresholdError, AlmaIntegrations::QuotaFloorError
        raise
      rescue AlmaIntegrations::JobSupport::CanceledError
        raise
      rescue StandardError => e
        # One bad record must not take down a run of several thousand.
        record_error(resolution, 'comparison_failed', "#{e.class}: #{e.message}")
      end

      report_progress(done, total)
    end
  end

  def audit_record(resolution, alma_record, diff, generator)
    alma = AlmaIntegrations::MarcRecord.parse(alma_record)
    zone = AlmaIntegrations::NetworkZone.detect(alma)

    result = generator.outgoing(resolution.resource_id, alma_record,
                                :include_unpublished => settings[:include_unpublished])
    outgoing = AlmaIntegrations::MarcRecord.parse(result.record)

    comparison = diff.diff(alma, outgoing)
    @summary.add_record(comparison,
                        :network_zone_linked => zone.linked?,
                        :record => summary_identity(resolution))

    entry = build_record_entry(resolution, comparison, zone, result)
    entry['alma_marc'] = alma.to_xml if settings[:store_alma_marc]
    entry['outgoing_marc'] = result.to_xml if settings[:store_outgoing_marc]

    @writer.add_record(entry)
    @plan.add(build_plan_entry(resolution, comparison, zone, alma))
  end

  # The identity the summary carries so the report can link a field to the
  # records it affects. Deliberately small: the summary lives in the job blob
  # and is loaded whole every time the report is opened, and the full detail is
  # in the JSON report anyway.
  def summary_identity(resolution)
    label = resolution.ead_id || resolution.identifier || resolution.mms_id || resolution.input

    {
      'label' => label.to_s,
      'title' => resolution.title.to_s[0, 120],
      'uri' => resolution.uri,
      'mms_id' => resolution.mms_id
    }
  end

  def build_record_entry(resolution, comparison, zone, preserve_result)
    {
      'input' => resolution.input,
      'matched_by' => resolution.matched_by,
      'mms_id' => resolution.mms_id,
      'resource_uri' => resolution.uri,
      'resource_id' => resolution.resource_id,
      'title' => resolution.title,
      'ead_id' => resolution.ead_id,
      'identifier' => resolution.identifier,
      'network_zone' => zone.to_h,
      'has_loss' => comparison['has_loss'],
      'has_change' => comparison['has_change'],
      'has_addition' => comparison['has_addition'],
      'enrichment_fields_ignored' => comparison['enrichment_fields_ignored'],
      'preserved_fields' => preserve_result.preserved_counts,
      'warnings' => preserve_result.warnings,
      'fields' => comparison['fields']
    }
  end

  # The compact instruction set the bulk update job reads back, one JSON object
  # per line. Kept separate from the report so the updater never has to load a
  # multi-megabyte document into memory to find out what to do.
  def build_plan_entry(resolution, comparison, zone, alma)
    {
      'mms_id' => resolution.mms_id,
      'resource_id' => resolution.resource_id,
      'resource_uri' => resolution.uri,
      'title' => resolution.title,
      'input' => resolution.input,
      'nz_linked' => zone.linked?,
      'has_loss' => comparison['has_loss'],
      'has_change' => comparison['has_change'],
      'has_addition' => comparison['has_addition'],
      # Alma's own version stamp and ArchivesSpace's, so the update can tell
      # whether either side moved since the audit.
      'alma_005' => alma.controlfield_value('005'),
      'aspace_lock_version' => resolution.lock_version,
      'aspace_system_mtime' => resolution.system_mtime.respond_to?(:iso8601) ? resolution.system_mtime.iso8601 : resolution.system_mtime.to_s
    }
  end

  def record_error(resolution, kind, message)
    @summary.add_error(kind)
    @writer.add_error(
      'input' => resolution.input,
      'kind' => resolution.kind,
      'error_kind' => kind,
      'error' => message,
      'resource_uri' => resolution.uri,
      'mms_id' => resolution.mms_id
    )
    log("  ! #{resolution.input}: #{message}")
  end

  def fetch_estimate(count)
    size = settings[:bulk_fetch_size].to_i
    size = 100 if size <= 0
    (count.to_f / size).ceil
  end

  # --- Output --------------------------------------------------------------

  def report_parameters
    settings.diff_parameters.merge(
      'job_id' => @job.id,
      'repo_id' => @job.repo_id,
      'identifier_type' => job_param('identifier_type'),
      'collection_id_field' => job_param('collection_id_field'),
      'started_at' => @started_at.utc.iso8601
    )
  end

  def finalise(stopped_early: nil)
    # A cancellation during identifier resolution leaves nothing to write.
    if @writer.nil?
      log('No records were compared, so no report was produced.')
      return
    end

    log_heading('Writing the report')

    summary = @summary.to_h
    summary['stopped_early'] = stopped_early if stopped_early
    summary['alma_requests'] = (@alma_client ? alma_client.request_count : 0)
    summary['duration_seconds'] = (Time.now - @started_at).round(1)
    summary['job_id'] = @job.id

    files = []

    report = Tempfile.new(['alma-audit-report', '.json'])
    begin
      report.binmode
      @writer.write(report, summary)
      files << attach_file(report,
                           :label => 'report',
                           :filename => "alma_audit_report_#{@job.id}.json",
                           :description => 'Full audit report, including the Alma MARC snapshot')
    ensure
      report.close
    end

    files << attach_file(@plan.file,
                         :label => 'plan',
                         :filename => "alma_audit_plan_#{@job.id}.jsonl",
                         :description => 'Record list used by the bulk update job')

    summary['files'] = files
    store_summary(summary)

    log_summary(summary)
  end

  def log_summary(summary)
    records = summary['records'] || {}

    log('')
    log("Audited #{records['audited']} record(s) of #{records['total']} submitted.")
    log("  #{records['with_loss']} would lose data")
    log("  #{records['with_change']} would have changed data")
    log("  #{records['identical']} are already identical")
    log("  #{records['errored']} could not be audited") if records['errored'].to_i > 0

    if records['network_zone_linked'].to_i > 0
      log("  #{records['network_zone_linked']} are linked to the Network Zone and are held " \
          'back from bulk updates by default')
    end

    top = Array(summary['fields']).select { |field| field['records_with_loss'].to_i > 0 && !field['ignored'] }
    unless top.empty?
      log('')
      log('Fields that would lose data:')
      top.first(15).each do |field|
        log("  MARC #{field['tag']} #{field['label']}: " \
            "#{field['records_with_loss']}/#{field['records_in_alma']} record(s)")
      end
    end

    recommended = Array(summary['recommended_preserve_tags'])
    unless recommended.empty?
      log('')
      log('Consider adding these to AppConfig[:alma_marc_fields_to_preserve]:')
      recommended.each do |field|
        log("  #{field['tag']} (#{field['label']}) -- #{field['reason']}")
      end
    end

    excluded = Array(summary['excluded_from_summary']).map { |field| field['tag'] }
    unless excluded.empty?
      log('')
      log("Excluded from these counts: #{excluded.join(', ')}. They differ on essentially every " \
          'record for mechanical reasons. The per-record detail is still in the JSON report.')
    end

    log('')
    log("Alma API calls: #{summary['alma_requests']}. Duration: #{summary['duration_seconds']}s.")
  end
end
