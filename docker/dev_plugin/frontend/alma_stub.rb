# Answer Alma API calls from files on disk, for local development only.
#
# There is no Alma sandbox wired into this stack, and the parts of the plugin
# that are hardest to get right -- the side-by-side comparison, the diff
# highlighting, the preserved fields -- only do anything when there is an Alma
# record to compare against. Without a stub those screens can only ever be seen
# in their "Alma did not answer" state, which is the one state that exercises
# none of the interesting code.
#
# The stub is installed at the HTTP boundary, replacing AlmaRequester#get
# rather than AlmaIntegrator#get_alma_bib. Everything above the socket -- the
# XML parsing, the error handling, the field preservation, the comparison -- is
# the real code, so what you see in the browser is what the plugin would do
# with the same bytes from Alma itself.
#
# Off unless ALMA_STUB_DIR names a directory. Set it in docker/.env:
#
#   ALMA_STUB_DIR=/archivesspace/plugins/alma_dev_errors/fixtures
#
# A fixture is a MARC <record> in a file named after the MMS ID, with a
# default.xml used for any ID that has no file of its own. Writes (PUT/POST)
# are left alone: they go to the real Alma, and with no API key configured they
# fail, which is the safe way round.
#
# Like the rest of this plugin, it is mounted only by the local docker-compose
# stack and must never reach a production ArchivesSpace.

require_relative '../alma_fixtures'

if AlmaFixtures.enabled?

  $stderr.puts("alma_dev_errors: Alma API responses are STUBBED from #{AlmaFixtures.dir}. " \
               'Local development only.')

  module AlmaStubResponses
    # is_a?(Net::HTTPSuccess) is what the plugin tests, so this has to be a real
    # response object rather than something that merely looks like one.
    def self.ok(body)
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response.add_field('Content-Type', 'application/xml;charset=UTF-8')
      response
    end
  end

  # AlmaRequester is autoloaded from the plugin's frontend/models, so it cannot
  # be referenced here: plugin_init.rb runs while the application is still being
  # defined. after_initialize runs once everything is in place.
  ActiveSupport.on_load(:after_initialize) do
    AlmaRequester.class_eval do
      alias_method :get_without_alma_stub, :get

      def get(uri, opts = {})
        base = AppConfig.has_key?(:alma_api_url) ? AppConfig[:alma_api_url].to_s : ''
        return get_without_alma_stub(uri, opts) if base.empty? || !uri.to_s.start_with?(base)

        rest = uri.to_s[base.length..-1].to_s.split('?').first.to_s.sub(%r{\A/}, '')
        return AlmaStubResponses.ok('<holdings total_record_count="0"/>') if rest.end_with?('holdings')

        query = URI.decode_www_form(uri.query.to_s).to_h
        ids = rest.empty? ? query['mms_id'].to_s.split(',') : [rest]

        xml, = AlmaFixtures.bibs_xml(ids)
        AlmaStubResponses.ok(xml)
      end
    end
  end

end
