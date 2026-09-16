# Parameters for the Alma audit job.
#
# Every property the report page needs to read has to be declared here.
# ArchivesSpace runs the contents of `job_blob` through
# `JSONSchemaUtils.drop_unknown_properties` before handing it to the frontend,
# so an undeclared key is silently discarded -- which is why the finished
# summary is written back into a declared `summary` property rather than being
# stashed on the side.
{
  :schema => {
    '$schema' => 'http://json-schema.org/draft-03/schema#',
    'version' => 1,
    'type' => 'object',
    'properties' => {
      # Drives the extension ArchivesSpace gives downloaded output files.
      'format' => {
        'type' => 'string',
        'default' => 'json'
      },

      # Identifiers pasted into the form. A file upload may be supplied instead
      # of, or in addition to, this.
      'identifiers' => {
        'type' => 'string',
        'required' => false
      },

      # How to interpret each identifier. 'auto' classifies per line: anything
      # that looks like an MMS ID (a long run of digits) is treated as one, and
      # anything else is looked up as a collection identifier. An explicit
      # `mms:` or `ead:` prefix on a line always wins.
      'identifier_type' => {
        'type' => 'string',
        'default' => 'auto',
        'enum' => %w[auto mms collection]
      },

      # Which ArchivesSpace field a collection identifier is matched against.
      # 'auto' tries EAD ID first and falls back to the resource identifier.
      'collection_id_field' => {
        'type' => 'string',
        'default' => 'auto',
        'enum' => %w[auto ead_id id_0 identifier]
      },

      # Which column to read when the uploaded file is a CSV or TSV.
      'csv_column' => {
        'type' => 'integer',
        'required' => false,
        'default' => 0
      },

      'skip_header' => {
        'type' => 'boolean',
        'required' => false
      },

      # Keeping Alma's MARC as it stood at audit time is the failsafe: if an
      # update later turns out to have been a mistake, this is the only record
      # of what Alma held beforehand.
      'store_alma_marc' => {
        'type' => 'boolean',
        'default' => true
      },

      # The outgoing record can be regenerated from ArchivesSpace at any time,
      # so it is only stored on request.
      'store_outgoing_marc' => {
        'type' => 'boolean',
        'default' => false
      },

      'include_unpublished' => {
        'type' => 'boolean',
        'default' => false
      },

      # Written by the job runner when the audit finishes. Read by the report
      # page so it can render without parsing the full JSON document.
      'summary' => {
        'type' => 'object',
        'required' => false
      }
    }
  }
}
