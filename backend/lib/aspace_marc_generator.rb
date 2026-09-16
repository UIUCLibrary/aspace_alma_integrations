require_relative '../../lib/alma_integrations'

module AlmaIntegrations
  # Produces the MARC record ArchivesSpace would send to Alma.
  #
  # The audit is only trustworthy if it diffs exactly what the update would
  # push, so both paths go through this one class. It calls the core export code
  # in process rather than going back out over HTTP to `marc21.xml`, which for a
  # few thousand records removes a few thousand round trips and the session
  # handling that goes with them.
  #
  # `generate_marc` is defined in ExportHelpers and calls `resolve_references`
  # unqualified, so URIResolver has to come along too. `Resource.to_jsonmodel`
  # is repository-scoped, so callers must already be inside
  # `RequestContext.open(:repo_id => ...)`.
  class AspaceMarcGenerator
    include ExportHelpers
    include URIResolver

    def initialize(settings: nil)
      @settings = settings || Settings.new
      @preserver = MarcPreserver.new(@settings)
    end

    # The record as ArchivesSpace would export it, before anything is preserved
    # from Alma.
    def generate(resource_id, include_unpublished: nil)
      include_unpublished = @settings[:include_unpublished] if include_unpublished.nil?

      generate_marc(resource_id, !!include_unpublished)
    end

    # The record as it would actually arrive in Alma: the ArchivesSpace export
    # with the configured Alma-only fields carried over from the existing bib.
    #
    # Returns a MarcPreserver::Result so callers can surface the warnings -- a
    # record missing an 008, for instance, is worth telling the user about
    # rather than silently working around.
    def outgoing(resource_id, alma_record, include_unpublished: nil)
      aspace_marc = generate(resource_id, :include_unpublished => include_unpublished)

      @preserver.apply(aspace_marc, alma_record)
    end
  end
end
