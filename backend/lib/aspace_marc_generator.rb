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
    # Built at load time so that two job threads reaching exporter_class at
    # once cannot each create a mutex and both proceed.
    EXPORTER_MUTEX = Mutex.new

    def initialize(settings: nil)
      @settings = settings || Settings.new
      @preserver = MarcPreserver.new(@settings)
    end

    # The record as ArchivesSpace would export it, before anything is preserved
    # from Alma.
    def generate(resource_id, include_unpublished: nil)
      include_unpublished = @settings[:include_unpublished] if include_unpublished.nil?

      exporter.generate_marc(resource_id, !!include_unpublished)
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

    private

    def exporter
      @exporter ||= self.class.exporter_class.new
    end

    class << self
      # ExportHelpers and URIResolver are defined by the backend's exporter
      # code, which is loaded well after this file is. ArchivesSpace requires
      # every plugin job runner from background_job_queue.rb near the top of
      # backend boot, so `include ExportHelpers` in the class body raises
      # NameError and takes the whole application down with it -- the backend
      # never finishes starting and the staff interface just reports a 500.
      #
      # Resolving the mixins on first use instead means the constants are only
      # looked up from inside a running job, by which point they exist.
      def exporter_class
        EXPORTER_MUTEX.synchronize do
          @exporter_class ||= Class.new do
            include ExportHelpers
            include URIResolver
          end
        end
      end
    end
  end
end
