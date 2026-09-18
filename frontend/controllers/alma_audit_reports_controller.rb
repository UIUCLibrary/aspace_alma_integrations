require 'json'

# The Alma audit reports screen.
#
# Audits run as background jobs, so nobody has to sit and watch a page while
# thousands of records are compared. This controller is the place you come back
# to afterwards: a list of every audit that has been run, the summary for any
# one of them, the JSON download, and the button that turns a report into a
# bulk update.
class AlmaAuditReportsController < ApplicationController

  # ArchivesSpace's ApplicationController already enables this; stating it again
  # here is free and keeps the guarantee visible on a controller that hands out
  # report files and links to a job which rewrites catalogue records.
  protect_from_forgery :with => :exception

  set_access_control 'view_repository' => [:index, :show]

  AUDIT_JOB_TYPE = 'alma_audit_job'.freeze

  def index
    @search_data = Search.for_type(
      session[:repo_id],
      'job',
      params_for_backend_search.merge(
        'filter_term[]' => [{ 'job_type' => AUDIT_JOB_TYPE }.to_json],
        'sort' => 'create_time desc'
      )
    )
  rescue StandardError => e
    # The search index lagging behind is not a reason to show an error page.
    flash.now[:error] = I18n.t('alma_audit_reports.index_error', :message => e.message)
    @search_data = nil
  end

  def show
    @job = JSONModel(:job).find(params[:id])

    unless @job['job_type'] == AUDIT_JOB_TYPE
      flash[:error] = I18n.t('alma_audit_reports.not_an_audit')
      return redirect_to(:action => :index)
    end

    @summary = (@job.job['summary'] rescue nil) || {}
    @records = @summary['records'] || {}
    @fields = Array(@summary['fields'])

    # Control fields are excluded from the headline counts because they differ
    # on essentially every record for mechanical reasons. The page says so
    # rather than hiding it, and the detail is still in the JSON.
    @excluded = Array(@summary['excluded_from_summary'])
    @recommended = Array(@summary['recommended_preserve_tags'])
    @warnings = Array(@summary['warnings'])
    @files = Array(@summary['files'])

    # The records each field affects, so a count can be opened up into a list of
    # records to go and look at. Held once and referenced by index by the field
    # rows, and capped when the audit was large -- see ReportSummary.
    @sampled_records = Array(@summary['sampled_records'])
    @samples_truncated = @summary['samples_truncated'] ? true : false

    @loss_fields = @fields.select { |field| !field['ignored'] && field['records_with_loss'].to_i > 0 }
                          .sort_by { |field| -field['records_with_loss'].to_i }
    @change_fields = @fields.select { |field| !field['ignored'] && field['records_with_change'].to_i > 0 }
                            .sort_by { |field| -field['records_with_change'].to_i }
    @addition_fields = @fields.select { |field| !field['ignored'] && field['records_with_addition'].to_i > 0 }
                              .sort_by { |field| -field['records_with_addition'].to_i }

    @report_file = @files.find { |file| file['label'] == 'report' }
  end
end
