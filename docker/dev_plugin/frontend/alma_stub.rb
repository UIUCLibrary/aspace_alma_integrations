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

if !ENV['ALMA_STUB_DIR'].to_s.empty?

  STUB_DIR = ENV['ALMA_STUB_DIR'].to_s

  $stderr.puts("alma_dev_errors: Alma API responses are STUBBED from #{STUB_DIR}. " \
               'Local development only.')

  module AlmaStubResponses

    def self.record_for(mms_id)
      candidate = File.join(STUB_DIR, "#{mms_id}.xml")
      candidate = File.join(STUB_DIR, 'default.xml') unless File.file?(candidate)

      return nil unless File.file?(candidate)

      File.read(candidate, :encoding => 'UTF-8')
    end

    def self.ok(body)
      # is_a?(Net::HTTPSuccess) is what the plugin tests, so this has to be a
      # real response object rather than something that merely looks like one.
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response.add_field('Content-Type', 'application/xml;charset=UTF-8')
      response
    end

    def self.not_found(mms_id)
      ok(<<~XML)
        <bibs total_record_count="0">
          <errorsExist>true</errorsExist>
          <errorList>
            <error>
              <errorCode>402203</errorCode>
              <errorMessage>Input parameters mmsId #{mms_id} is not valid.</errorMessage>
            </error>
          </errorList>
        </bibs>
      XML
    end

    # Wraps one or more fixtures in the <bibs> envelope Alma returns. The
    # mms_id element matters: the multi-record fetch keys off it.
    def self.bibs(mms_ids)
      found = mms_ids.map { |mms_id| [mms_id, record_for(mms_id)] }.reject { |_, record| record.nil? }

      return not_found(mms_ids.join(',')) if found.empty?

      body = found.map do |mms_id, record|
        <<~XML
          <bib>
            <mms_id>#{mms_id}</mms_id>
            <record_format>marc21</record_format>
            #{record.sub(/\A<\?xml[^>]*\?>\s*/, '')}
          </bib>
        XML
      end

      ok(%(<bibs total_record_count="#{found.length}">\n#{body.join}\n</bibs>))
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
        query = Rack::Utils.parse_nested_query(uri.query.to_s)

        if rest.end_with?('holdings')
          return AlmaStubResponses.ok('<holdings total_record_count="0"/>')
        end

        ids = if rest.empty?
                query['mms_id'].to_s.split(',')
              else
                [rest]
              end

        return AlmaStubResponses.not_found('(none)') if ids.empty?

        AlmaStubResponses.bibs(ids)
      end
    end
  end

end
