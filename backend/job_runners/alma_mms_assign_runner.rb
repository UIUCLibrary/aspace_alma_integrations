require_relative '../lib/alma_job_support'

# Writes Alma MMS IDs into ArchivesSpace resources from a spreadsheet that pairs
# each MMS ID with the collection it belongs to.
#
# This is the bootstrap step for everything else in the plugin. The audit and
# bulk update jobs both start from the MMS ID held in user_defined, and until it
# is there they have nothing to work with. Cataloguers can type them in one at a
# time; several thousand is a different problem.
#
# It talks to ArchivesSpace only. No Alma request is made, so there is no rate
# limit to respect and nothing in the catalogue can be disturbed by a mistake
# here -- though a wrong MMS ID written now becomes a wrong catalogue record
# overwritten later, which is why the job reports before it writes.
#
# Nothing here touches a model at load time: ArchivesSpace requires job runner
# files before the database is connected.
class AlmaMmsAssignRunner < JobRunner
  include AlmaIntegrations::JobSupport

  register_for_job_type('alma_mms_assign_job',
                        :create_permissions => :update_resource_record,
                        :cancel_permissions => :update_resource_record,
                        :run_concurrently => false)

  def run
    # :current_username is what ArchivesSpace stamps on the record as
    # last_modified_by. Without it in the context the write is rejected, and
    # with the wrong one the collection's history would credit the change to
    # somebody who did not make it.
    RequestContext.open(:repo_id => @job.repo_id, :current_username => @job.owner.username) do
      begin
        assign
      rescue AlmaIntegrations::JobSupport::CanceledError
        # Returning normally marks the job cancelled rather than failed. The
        # rows already written stay written -- they are individually committed
        # and are not wrong, just incomplete -- and the report says where the
        # run stopped so it can be finished later.
        log('')
        log('Cancelled. Saving the partial report.')
        finalise(:stopped_early => 'Cancelled by request')
      rescue StandardError => e
        log('')
        log("Failed: #{e.message}")
        e.backtrace.first(15).each { |line| log("    #{line}") }
        raise
      ensure
        @writer.close if @writer
      end
    end
  end

  private

  def assign
    @started_at = Time.now
    @counts = Hash.new(0)
    @updated_uris = []

    log_heading(dry_run? ? 'Assign Alma MMS IDs (DRY RUN)' : 'Assign Alma MMS IDs')
    log('Nothing will be written. This run reports what would change.') if dry_run?
    log("Repository: #{@job.repo_id}")
    log("MMS IDs will be written to user_defined.#{mms_field}")
    log("Existing MMS IDs will be #{overwrite? ? 'REPLACED' : 'left alone'}.")

    list = read_pairs
    check_canceled!

    @writer = AlmaIntegrations::ReportWriter.new(report_parameters(list))

    resolutions = resolve(list)
    check_canceled!

    apply(list, resolutions)

    finalise
    self.success!
  end

  def dry_run?
    job_param?('dry_run') ? truthy(job_param('dry_run')) : true
  end

  def overwrite?
    truthy(job_param('overwrite'))
  end

  def mms_field
    @mms_field ||= settings[:mms_field]
  end

  # --- Input ---------------------------------------------------------------

  # The pasted box and the uploaded files are read together, so a few
  # stragglers can be added without editing the spreadsheet. Each source is
  # parsed on its own -- they may have different columns -- and the rows are
  # then merged so a conflict spanning two sources is still caught.
  def read_pairs
    log_heading('Reading the spreadsheet')

    sources = []

    pasted = job_param('pairs').to_s
    sources << pasted unless pasted.strip.empty?

    uploaded_files.each do |path|
      begin
        sources << File.read(path, :mode => 'rb')
      rescue StandardError => e
        log("  ! Could not read uploaded file: #{e.message}")
      end
    end

    if sources.empty?
      raise AlmaIntegrations::Error, 'No rows were supplied. Paste the two columns or upload the spreadsheet.'
    end

    list = parse_sources(sources)

    if list.matched_headers
      log("Found the MMS ID in column #{list.mms_column} and the collection identifier in " \
          "column #{list.collection_column}, by header name.")
    else
      log("Reading the MMS ID from column #{list.mms_column} and the collection identifier " \
          "from column #{list.collection_column}.")
    end

    log("Skipped a header row: #{list.header.inspect}") if list.header
    log("#{list.rows.length} pair(s) to apply.")
    log("Ignored #{list.duplicates.length} repeated row(s).") unless list.duplicates.empty?

    list.problems.each do |problem|
      log("  ! line #{problem.line}: #{problem.reason}")
      record_error(problem.raw, 'unusable_row', problem.reason, :line => problem.line)
    end

    raise AlmaIntegrations::Error, 'The spreadsheet contained no usable rows.' if list.empty?

    list
  end

  def parse_sources(sources)
    combined = nil

    sources.each do |source|
      list = AlmaIntegrations::IdentifierPairs.parse(
        source,
        :mms_column => job_param('mms_column'),
        :collection_column => job_param('collection_column')
      )

      combined = combined.nil? ? list : combined.merge!(list)
    end

    combined
  end

  # --- Matching ------------------------------------------------------------

  def resolve(list)
    log_heading('Matching collection identifiers to resources')

    resolver = AlmaIntegrations::ResourceResolver.new(
      :repo_id => @job.repo_id,
      :settings => settings,
      :collection_id_field => job_param('collection_id_field').to_s,
      # A resource with no MMS ID is exactly what this job is looking for.
      :require_mms_id => false
    )

    entries = list.rows.map do |row|
      AlmaIntegrations::IdentifierList::Entry.new(row.collection_id, row.collection_id,
                                                 :collection, row.line, true)
    end

    resolutions = resolver.resolve(entries).to_a
    log("Matched #{resolutions.count(&:ok?)} of #{resolutions.length}.")

    resolutions
  end

  # An MMS ID already sitting on some other resource in this repository means
  # two collections would point at one catalogue record, and a later bulk update
  # would have them overwrite each other. Cheaper to say so now than to explain
  # it afterwards. Scoped to this repository, like every other lookup the plugin
  # makes.
  def existing_holders(mms_ids)
    return {} if mms_ids.empty?

    column = mms_field.to_sym
    holders = Hash.new { |hash, key| hash[key] = [] }
    by_resource = {}

    mms_ids.each_slice(500) do |slice|
      UserDefined
        .where(column => slice)
        .exclude(:resource_id => nil)
        .select(:resource_id, column)
        .each { |row| by_resource[row[:resource_id]] = row[column].to_s }
    end

    return {} if by_resource.empty?

    in_repo = []
    by_resource.keys.each_slice(500) do |slice|
      Resource
        .where(:id => slice, :repo_id => @job.repo_id)
        .select(:id)
        .each { |row| in_repo << row[:id] }
    end

    in_repo.each { |resource_id| holders[by_resource[resource_id]] << resource_id }
    holders
  rescue StandardError => e
    log("  ! Could not check for MMS IDs already in use: #{e.message}")
    {}
  end

  # --- Applying ------------------------------------------------------------

  def apply(list, resolutions)
    log_heading(dry_run? ? 'Checking rows' : 'Writing MMS IDs')

    holders = existing_holders(list.rows.map(&:mms_id).uniq)
    total = list.rows.length
    done = 0

    list.rows.each_with_index do |row, index|
      check_canceled!

      apply_row(row, resolutions[index], holders)

      done += 1
      report_progress(done, total, 'rows')
    end
  end

  def apply_row(row, resolution, holders)
    if resolution.nil?
      record_error(row.collection_id, 'unresolved', 'No resolution for this row', :line => row.line)
      return
    end

    unless resolution.ok?
      log("  ! #{row.collection_id}: #{resolution.error}")
      record_error(row.collection_id, resolution.error_kind || 'resource_not_found',
                   resolution.error, :line => row.line, :mms_id => row.mms_id)
      return
    end

    current = resolution.mms_id.to_s
    warnings = holder_warnings(row, resolution, holders)

    if current == row.mms_id
      record_row(row, resolution, 'unchanged', 'The resource already has this MMS ID', warnings)
      return
    end

    if !current.empty? && !overwrite?
      message = "Already has MMS ID #{current}; left alone. Tick \"replace\" to change it."
      log("  ! #{row.collection_id}: #{message}")
      record_row(row, resolution, 'conflict', message, warnings)
      return
    end

    action = current.empty? ? 'assigned' : 'overwritten'

    if dry_run?
      record_row(row, resolution, "would_be_#{action}", nil, warnings)
      return
    end

    begin
      write_mms_id(resolution.resource_id, row.mms_id)
      @updated_uris << resolution.uri
      record_row(row, resolution, action, nil, warnings)
    rescue StandardError => e
      log("  ! #{row.collection_id}: could not be saved: #{e.message}")
      record_error(row.collection_id, 'save_failed', e.message,
                   :line => row.line, :mms_id => row.mms_id, :resource_uri => resolution.uri)
    end
  end

  def holder_warnings(row, resolution, holders)
    other = Array(holders[row.mms_id]).reject { |id| id == resolution.resource_id }
    return [] if other.empty?

    uris = other.map { |id| JSONModel(:resource).uri_for(id, :repo_id => @job.repo_id) }
    message = "MMS ID #{row.mms_id} is already on #{uris.join(', ')}. Two resources pointing at " \
              'one Alma record will overwrite each other on a bulk update.'
    log("  ! #{row.collection_id}: #{message}")

    [message]
  end

  # Written through the model rather than straight into the user_defined table,
  # so the change is reindexed, appears in the resource's history and is
  # attributed to whoever ran the job. A direct UPDATE would be faster and would
  # leave the record looking unchanged in every search result.
  #
  # Each row is its own transaction: one resource that refuses to save should
  # not roll back the thousands that already succeeded.
  def write_mms_id(resource_id, mms_id)
    DB.open(true) do
      obj = Resource.get_or_die(resource_id)
      json = Resource.to_jsonmodel(obj)

      user_defined = json.user_defined || {}
      user_defined = user_defined.to_hash if user_defined.respond_to?(:to_hash)
      user_defined = user_defined.dup
      user_defined['jsonmodel_type'] ||= 'user_defined'
      user_defined[mms_field] = mms_id

      json.user_defined = user_defined
      obj.update_from_json(json)
    end
  end

  # --- Output --------------------------------------------------------------

  def record_row(row, resolution, action, note, warnings)
    @counts[action] += 1

    @writer.add_record(
      'line' => row.line,
      'mms_id' => row.mms_id,
      'collection_id' => row.collection_id,
      'action' => action,
      'note' => note,
      'warnings' => warnings,
      'resource_uri' => resolution.uri,
      'resource_title' => resolution.title,
      'ead_id' => resolution.ead_id,
      'identifier' => resolution.identifier,
      'matched_by' => resolution.matched_by,
      'previous_mms_id' => resolution.mms_id
    )
  end

  def record_error(input, kind, message, line: nil, mms_id: nil, resource_uri: nil)
    @counts['errored'] += 1

    return if @writer.nil?

    @writer.add_error(
      'line' => line,
      'input' => input,
      'mms_id' => mms_id,
      'error_kind' => kind,
      'error' => message,
      'resource_uri' => resource_uri
    )
  end

  def report_parameters(list)
    {
      'repo_id' => @job.repo_id,
      'dry_run' => dry_run?,
      'overwrite' => overwrite?,
      'mms_field' => mms_field,
      'collection_id_field' => job_param('collection_id_field').to_s,
      'input' => list.to_h
    }
  end

  def finalise(stopped_early: nil)
    return if @writer.nil?

    log_heading('Writing the report')

    summary = {
      'dry_run' => dry_run?,
      'overwrite' => overwrite?,
      'mms_field' => mms_field,
      'rows' => {
        'total' => @writer.record_count + @counts['errored'],
        'assigned' => @counts['assigned'],
        'overwritten' => @counts['overwritten'],
        'would_be_assigned' => @counts['would_be_assigned'],
        'would_be_overwritten' => @counts['would_be_overwritten'],
        'unchanged' => @counts['unchanged'],
        'conflict' => @counts['conflict'],
        'errored' => @counts['errored']
      },
      'stopped_early' => stopped_early,
      'duration_seconds' => (Time.now - @started_at).round(1),
      'job_id' => @job.id
    }

    files = []
    Tempfile.open(['alma-mms-assign', '.json']) do |io|
      @writer.write(io, summary)
      files << attach_file(io,
                           :label => 'report',
                           :filename => "alma_mms_assign_#{@job.id}.json",
                           :description => 'Outcome for every row in the spreadsheet')
    end

    summary['files'] = files
    store_summary(summary)

    record_modified_resources

    log('')
    if dry_run?
      log("Would assign:  #{@counts['would_be_assigned']}")
      log("Would replace: #{@counts['would_be_overwritten']}")
    else
      log("Assigned:      #{@counts['assigned']}")
      log("Replaced:      #{@counts['overwritten']}")
    end
    log("Already set:   #{@counts['unchanged']}")
    log("Left alone:    #{@counts['conflict']}")
    log("Errors:        #{@counts['errored']}")

    if dry_run?
      log('')
      log('This was a dry run. Nothing was written. Run the job again with the dry run ' \
          'box unticked to apply it.')
    end
  end

  # Links the changed resources to the job, so there is a trail from a
  # collection back to the run that set its MMS ID.
  def record_modified_resources
    return if @updated_uris.empty?

    @job.record_modified_uris(@updated_uris.uniq)
  rescue StandardError => e
    log("  ! Could not link the updated resources to this job: #{e.message}")
  end
end
