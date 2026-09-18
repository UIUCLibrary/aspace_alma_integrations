# The shared library is loaded here as well as in backend/plugin_init.rb so the
# single-record push screen and the bulk audit run the exact same comparison and
# field-preservation code. If they could drift, the audit would eventually start
# describing something the update does not do.
require_relative '../lib/alma_integrations'

ArchivesSpace::Application.extend_aspace_routes(File.join(File.dirname(__FILE__), "routes.rb"))
