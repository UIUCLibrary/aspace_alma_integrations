# Answer the audit and bulk update jobs' Alma calls from fixture files.
#
# The frontend half of this stub (dev_plugin/frontend/alma_stub.rb) covers the
# single-record push screen, which goes through AlmaRequester. The background
# jobs use AlmaIntegrations::AlmaClient instead -- a different client, with its
# own throttling, retries and response object -- so it needs its own stub if an
# audit is to be run without an Alma sandbox.
#
# The patch is applied at AlmaClient#perform, the one method that actually
# touches the socket. Everything above it -- the rate limiter, the retry and
# backoff logic, the daily-quota guard, the <bibs> parsing, the comparison, the
# report writer -- is the real code, so an audit run against this stub exercises
# the whole job apart from the network itself.
#
# Off unless ALMA_STUB_DIR names a directory. Local development only.

require_relative '../alma_fixtures'

if AlmaFixtures.enabled?

  $stderr.puts("alma_dev_errors: backend Alma API responses are STUBBED from #{AlmaFixtures.dir}. " \
               'Local development only.')

  module AlmaClientStub
    def perform(method, uri, body)
      # Writes are left to the real client. With no API key configured they
      # fail, which is the safe way round: a stubbed PUT would make a bulk
      # update look as though it had succeeded when nothing had been written.
      return super unless method == :get

      path = uri.path.to_s
      query = URI.decode_www_form(uri.query.to_s).to_h

      return stub_response('<holdings total_record_count="0"/>') if path.end_with?('holdings')

      ids = query['mms_id'].to_s.split(',')
      ids = [path.split('/').last.to_s] if ids.empty?

      xml, = AlmaFixtures.bibs_xml(ids)
      stub_response(xml)
    end

    private

    def stub_response(body)
      AlmaIntegrations::AlmaClient::Response.new(
        200, body,
        'content-type' => 'application/xml;charset=UTF-8',
        # A generous remaining-quota header, so the daily-quota guard does not
        # stop a development run.
        AlmaIntegrations::AlmaClient::REMAINING_HEADER => '100000'
      )
    end
  end

  AlmaIntegrations::AlmaClient.prepend(AlmaClientStub)
end
