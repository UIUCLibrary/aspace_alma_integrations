# Parameters for the Alma bulk update job.
#
# As with the audit job, anything the frontend needs to read back has to be a
# declared property here or ArchivesSpace will drop it from `job_blob`.
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

      # The audit whose report this update is applying. Required unless
      # `skip_audit` is explicitly set, because updating the catalogue without
      # first seeing what it would destroy is the thing this feature exists to
      # prevent.
      'audit_job_id' => {
        'type' => 'integer',
        'required' => false
      },

      'skip_audit' => {
        'type' => 'boolean',
        'default' => false
      },

      # Runs the entire job -- resolution, MARC generation, preserve-field
      # merging, staleness checks -- and sends no PUTs.
      'dry_run' => {
        'type' => 'boolean',
        'default' => true
      },

      # A bib PUT only replaces local fields on a Network Zone linked record, so
      # the audit's picture of the change is incomplete for those records. They
      # are held back unless this is deliberately turned on.
      'include_nz_linked' => {
        'type' => 'boolean',
        'default' => false
      },

      # Carries Alma's 005 from the audit snapshot on the outgoing record so
      # Alma itself rejects anything that changed in between.
      'stale_version_check' => {
        'type' => 'boolean',
        'default' => true
      },

      # Refuses records whose ArchivesSpace resource was modified after the
      # audit ran, since the audit no longer describes what would be sent.
      'check_aspace_changes' => {
        'type' => 'boolean',
        'default' => true
      },

      # Only push records the audit found would lose or change something.
      # Pushing a record that is already identical spends quota for nothing.
      'skip_identical' => {
        'type' => 'boolean',
        'default' => true
      },

      # Used only when `skip_audit` is set.
      'identifiers' => {
        'type' => 'string',
        'required' => false
      },

      'identifier_type' => {
        'type' => 'string',
        'default' => 'auto',
        'enum' => %w[auto mms collection]
      },

      'collection_id_field' => {
        'type' => 'string',
        'default' => 'auto',
        'enum' => %w[auto ead_id id_0 identifier]
      },

      'csv_column' => {
        'type' => 'integer',
        'required' => false,
        'default' => 0
      },

      'skip_header' => {
        'type' => 'boolean',
        'required' => false
      },

      'include_unpublished' => {
        'type' => 'boolean',
        'default' => false
      },

      'summary' => {
        'type' => 'object',
        'required' => false
      }
    }
  }
}
