# Parameters for the job that writes Alma MMS IDs into ArchivesSpace resources.
#
# As with the other jobs in this plugin, anything the show page needs to read
# has to be declared here: ArchivesSpace runs `job_blob` through
# `JSONSchemaUtils.drop_unknown_properties` before the frontend sees it, so an
# undeclared key is silently discarded.
{
  :schema => {
    '$schema' => 'http://json-schema.org/draft-03/schema#',
    'version' => 1,
    'type' => 'object',
    'properties' => {
      'format' => {
        'type' => 'string',
        'default' => 'json'
      },

      # Pasted rows, as an alternative to uploading the spreadsheet. Two
      # columns, same as the file.
      'pairs' => {
        'type' => 'string',
        'required' => false
      },

      # Which ArchivesSpace field the collection identifier is matched against.
      # Defaults to EAD ID only rather than 'auto', because the column in the
      # Alma export is explicitly an EAD ID and falling back to the resource
      # identifier would widen the match for no reason.
      'collection_id_field' => {
        'type' => 'string',
        'default' => 'ead_id',
        'enum' => %w[auto ead_id id_0 identifier]
      },

      # Left blank, the columns are found by header name. Filled in, they win:
      # an operator who counts columns has usually done so because the guess
      # was wrong.
      'mms_column' => {
        'type' => 'integer',
        'required' => false
      },

      'collection_column' => {
        'type' => 'integer',
        'required' => false
      },

      # On by default. Writing an MMS ID onto the wrong resource points a
      # future bulk update at the wrong catalogue record, so the first run
      # always reports and the operator has to come back and untick this.
      'dry_run' => {
        'type' => 'boolean',
        'default' => true
      },

      # A resource that already holds a different MMS ID is left alone unless
      # this is set. A value that is already there was put there by somebody,
      # and a spreadsheet is not automatically more right than they were.
      'overwrite' => {
        'type' => 'boolean',
        'default' => false
      },

      # Written by the job runner when the run finishes. Read by the show page.
      'summary' => {
        'type' => 'object',
        'required' => false
      }
    }
  }
}
