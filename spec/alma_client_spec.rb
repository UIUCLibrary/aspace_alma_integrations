require 'spec_helper'

RSpec.describe AlmaIntegrations::AlmaClient do
  FakeRawResponse = Struct.new(:code, :body, :headers) do
    def initialize(code, body, headers = {})
      super(code.to_s, body, headers)
    end

    def each_header(&block)
      headers.each(&block)
    end
  end

  class FakeHTTP
    attr_reader :requests, :finish_count
    attr_accessor :open_timeout, :read_timeout, :keep_alive_timeout, :use_ssl

    def initialize(uri, responses, settings = nil)
      @uri = uri
      @responses = responses
      @requests = []
      @finish_count = 0
      @started = true

      return if settings.nil?

      @use_ssl = (uri.scheme == 'https')
      @open_timeout = settings[:open_timeout]
      @read_timeout = settings[:read_timeout]
      @keep_alive_timeout = 30
    end

    def address
      @uri.host
    end

    def port
      @uri.port
    end

    def started?
      @started
    end

    def finish
      @finish_count += 1
      @started = false
    end

    def request(request)
      @requests << request
      queued = @responses.shift
      raise 'No queued fake Alma response' if queued.nil?
      raise queued if queued.is_a?(Exception)

      queued
    end
  end

  class FakeHTTPFactory
    attr_reader :connections, :uris

    def initialize(responses, settings = nil)
      @responses = responses.dup
      @settings = settings
      @connections = []
      @uris = []
    end

    def call(uri)
      @uris << uri.dup
      connection = FakeHTTP.new(uri, @responses, @settings)
      @connections << connection
      connection
    end

    def requests
      @connections.flat_map(&:requests)
    end
  end

  class FakeLimiter
    attr_reader :acquire_count, :penalties

    def initialize(sleeper = nil)
      @sleeper = sleeper
      @acquire_count = 0
      @penalties = []
    end

    def acquire
      @acquire_count += 1
      0.0
    end

    def penalize(seconds)
      @penalties << seconds
      @sleeper.call(seconds) if @sleeper
    end
  end

  class FixedRng
    def initialize(values)
      @values = values.dup
    end

    def rand
      @values.empty? ? 0.0 : @values.shift
    end
  end

  def settings(overrides = {})
    AlmaIntegrations::Settings.new({
      :api_url => 'https://api.example.edu/almaws/v1/bibs',
      :api_key => 'secret-api-key',
      :daily_quota_floor => 0,
      :max_retries => 0,
      :open_timeout => 7,
      :read_timeout => 13,
      :retry_base_delay => 1.0,
      :retry_max_delay => 2.0
    }.merge(overrides))
  end

  def raw_response(code, body, headers = {})
    FakeRawResponse.new(code, body, headers)
  end

  def ok_bulk_response(mms_ids)
    raw_response(200, bulk_xml(Array(mms_ids).map { |id| bib_xml(id) }))
  end

  def bulk_xml(entries)
    "<bibs>\n#{entries.join("\n")}\n</bibs>"
  end

  def bib_xml(mms_id, record_id: mms_id)
    <<~XML
      <bib>
        <mms_id>#{mms_id}</mms_id>
        #{marc_xml(:controlfields => { '001' => record_id })}
      </bib>
    XML
  end

  def error_bib_xml(mms_id, code:, message:)
    <<~XML
      <bib>
        <mms_id>#{mms_id}</mms_id>
        <errorList>
          <error>
            <errorCode>#{code}</errorCode>
            <errorMessage>#{message}</errorMessage>
          </error>
        </errorList>
      </bib>
    XML
  end

  def error_xml(code, message)
    <<~XML
      <web_service_result>
        <errorList>
          <error>
            <errorCode>#{code}</errorCode>
            <errorMessage>#{message}</errorMessage>
          </error>
        </errorList>
      </web_service_result>
    XML
  end

  def build_client(responses, client_settings: settings, limiter: nil, sleeper: nil, rng: FixedRng.new([0.0]))
    sleeper ||= ->(_seconds) {}
    limiter ||= FakeLimiter.new(sleeper)
    factory = FakeHTTPFactory.new(responses, client_settings)
    client = described_class.new(:settings => client_settings,
                                 :limiter => limiter,
                                 :http_factory => factory,
                                 :sleeper => sleeper,
                                 :rng => rng)

    [client, factory, limiter]
  end

  def decoded_query(request)
    URI.decode_www_form(request.uri.query.to_s).to_h
  end

  def record_001(record)
    record.at_xpath('./controlfield[@tag="001"]').text
  end

  describe '#each_bib' do
    it 'fetches a short list in one multi-ID request and yields record nodes' do
      ids = %w[991000001 991000002]
      client, factory = build_client([ok_bulk_response(ids)])

      results = client.each_bib(ids).to_a

      expect(factory.requests.length).to eq(1)
      expect(decoded_query(factory.requests.first)).to eq('mms_id' => ids.join(','))
      expect(results.map(&:first)).to eq(ids)
      expect(results.map { |(_, record, error)| [record_001(record), error] }).to eq([
        ['991000001', nil],
        ['991000002', nil]
      ])
    end

    it 'uses the configured bulk_fetch_size when it is below the Alma maximum' do
      ids = %w[991000001 991000002 991000003]
      client_settings = settings(:bulk_fetch_size => 2)
      client, factory = build_client([
        ok_bulk_response(ids.first(2)),
        ok_bulk_response(ids.last(1))
      ], :client_settings => client_settings)

      results = client.each_bib(ids).to_a

      expect(results.map(&:first)).to eq(ids)
      expect(factory.requests.map { |request| decoded_query(request).fetch('mms_id') }).to eq([
        ids.first(2).join(','),
        ids.last(1).join(',')
      ])
    end

    it 'caps default-sized bulk requests at one hundred MMS IDs' do
      ids = (1..105).map { |number| "991#{number.to_s.rjust(6, '0')}" }
      client, factory = build_client([
        ok_bulk_response(ids.first(100)),
        ok_bulk_response(ids.last(5))
      ])

      results = client.each_bib(ids).to_a

      expect(results.map(&:first)).to eq(ids)
      expect(factory.requests.map { |request| decoded_query(request).fetch('mms_id') }).to eq([
        ids.first(100).join(','),
        ids.last(5).join(',')
      ])
      expect(client.request_count).to eq(2)
    end

    it 'yields a non-nil error when Alma omits a requested MMS ID' do
      ids = %w[991000001 991000002 991000003]
      client, = build_client([
        raw_response(200, bulk_xml([
          bib_xml('991000001'),
          bib_xml('991000003')
        ]))
      ])

      results = client.each_bib(ids).to_a

      expect(results.map(&:first)).to eq(ids)
      missing = results[1]
      expect(missing[0]).to eq('991000002')
      expect(missing[1]).to be_nil
      expect(missing[2]).to eq('Record not found in Alma')
    end

    it 'attributes per-record errors in a 200 bulk response to the affected MMS ID' do
      ids = %w[991000001 991000002 991000003]
      client, = build_client([
        raw_response(200, bulk_xml([
          bib_xml('991000001'),
          error_bib_xml('991000002',
                        :code => 'INVALID_MMS_ID',
                        :message => 'The requested bib does not exist'),
          bib_xml('991000003')
        ]))
      ])

      results = client.each_bib(ids).to_a
      errored = results[1]

      expect(results.map(&:first)).to eq(ids)
      expect(errored[1]).to be_nil
      expect(errored[2]).to include('INVALID_MMS_ID')
      expect(errored[2]).to include('The requested bib does not exist')
    end

    it 'does not make HTTP calls for empty input' do
      client, factory, limiter = build_client([])

      expect(client.each_bib([]).to_a).to eq([])
      expect(factory.connections).to be_empty
      expect(limiter.acquire_count).to eq(0)
      expect(client.request_count).to eq(0)
    end

    it 'yields once for each duplicate requested MMS ID' do
      ids = %w[991000001 991000001 991000002]
      client, factory = build_client([
        raw_response(200, bulk_xml([
          bib_xml('991000001'),
          bib_xml('991000002')
        ]))
      ])

      results = client.each_bib(ids).to_a

      expect(decoded_query(factory.requests.first)).to eq('mms_id' => ids.join(','))
      expect(results.map(&:first)).to eq(ids)
      expect(results.map { |(_, record, error)| [record_001(record), error] }).to eq([
        ['991000001', nil],
        ['991000001', nil],
        ['991000002', nil]
      ])
    end
  end

  describe 'auth and transport' do
    it 'sends the API key only in the Authorization header and reuses the connection' do
      client_settings = settings(:open_timeout => 4, :read_timeout => 8)
      client, factory, limiter = build_client([
        raw_response(200, '<ok/>'),
        raw_response(200, '<ok/>')
      ], :client_settings => client_settings)

      client.get('', :mms_id => '991000001')
      client.get('', :mms_id => '991000002')

      expect(factory.connections.length).to eq(1)
      expect(factory.uris.length).to eq(1)
      expect(limiter.acquire_count).to eq(2)
      expect(client.request_count).to eq(2)

      connection = factory.connections.first
      expect(connection.use_ssl).to be(true)
      expect(connection.open_timeout).to eq(4)
      expect(connection.read_timeout).to eq(8)
      expect(connection.keep_alive_timeout).to eq(30)

      factory.requests.each do |request|
        expect(request['Authorization']).to eq('apikey secret-api-key')
        expect(request.uri.query.to_s).not_to include('secret-api-key')
        expect(decoded_query(request)).not_to have_key('apikey')
      end
    end
  end

  describe 'throttling and retry behaviour' do
    it 'acquires the limiter before every HTTP attempt' do
      client, factory, limiter = build_client([
        raw_response(200, '<ok/>'),
        raw_response(200, '<ok/>')
      ])

      client.get('', :mms_id => '991000001')
      client.get('', :mms_id => '991000002')

      expect(limiter.acquire_count).to eq(2)
      expect(factory.requests.length).to eq(2)
    end

    it 'retries per-second threshold responses with growing capped jittered backoff before giving up' do
      sleeps = []
      sleeper = ->(seconds) { sleeps << seconds }
      limiter = FakeLimiter.new(sleeper)
      client_settings = settings(:max_retries => 3,
                                 :retry_base_delay => 1.0,
                                 :retry_max_delay => 2.0)
      threshold = raw_response(429,
                               error_xml('PER_SECOND_THRESHOLD', 'Too many requests'),
                               'Content-Type' => 'application/xml')
      client, factory = build_client([threshold, threshold, threshold, threshold],
                                     :client_settings => client_settings,
                                     :limiter => limiter,
                                     :sleeper => sleeper,
                                     :rng => FixedRng.new([0.5, 0.5, 0.5]))

      expect { client.get('', :mms_id => '991000001') }
        .to raise_error(AlmaIntegrations::RequestFailedError, /after 4 attempts/)

      expect(factory.requests.length).to eq(4)
      expect(limiter.acquire_count).to eq(4)
      expect(client.request_count).to eq(4)
      expect(sleeps.length).to eq(3)
      expect(sleeps[0]).to be_within(0.00001).of(0.75)
      expect(sleeps[1]).to be_within(0.00001).of(1.5)
      expect(sleeps[2]).to be_within(0.00001).of(1.5)
      expect(sleeps.each_cons(2).all? { |left, right| right >= left }).to be(true)
      expect(sleeps).to all(be <= client_settings[:retry_max_delay])
      expect(limiter.penalties).to eq(sleeps)
    end

    it 'raises DailyThresholdError without retrying the request' do
      sleeps = []
      sleeper = ->(seconds) { sleeps << seconds }
      limiter = FakeLimiter.new(sleeper)
      daily = raw_response(403,
                           error_xml('DAILY_THRESHOLD', 'Daily API threshold exceeded'),
                           'Content-Type' => 'application/xml')
      client, factory = build_client([daily],
                                     :client_settings => settings(:max_retries => 5),
                                     :limiter => limiter,
                                     :sleeper => sleeper)

      expect { client.get('', :mms_id => '991000001') }
        .to raise_error(AlmaIntegrations::DailyThresholdError, /daily API request threshold/)

      expect(factory.requests.length).to eq(1)
      expect(limiter.acquire_count).to eq(1)
      expect(limiter.penalties).to eq([])
      expect(sleeps).to eq([])
      expect(client.request_count).to eq(1)
    end

    it 'does not retry POST responses that are ordinary server errors' do
      client, factory, limiter = build_client([
        raw_response(500, '<html><body><h1>Gateway error</h1></body></html>',
                     'Content-Type' => 'text/html')
      ], :client_settings => settings(:max_retries => 5))

      response = client.post('', '<record/>')

      expect(response.code).to eq(500)
      expect(factory.requests.length).to eq(1)
      expect(limiter.acquire_count).to eq(1)
      expect(client.request_count).to eq(1)
    end

    it 'does not retry POST responses that hit the per-second threshold' do
      sleeps = []
      sleeper = ->(seconds) { sleeps << seconds }
      limiter = FakeLimiter.new(sleeper)
      client, factory = build_client([
        raw_response(429, error_xml('PER_SECOND_THRESHOLD', 'Too many requests')),
        raw_response(200, '<ok/>')
      ], :client_settings => settings(:max_retries => 1),
                                     :limiter => limiter,
                                     :sleeper => sleeper)

      response = client.post('', '<record/>')

      expect(response.code).to eq(429)
      expect(factory.requests.length).to eq(1)
      expect(limiter.acquire_count).to eq(1)
      expect(sleeps).to eq([])
    end
  end

  describe 'quota floor enforcement' do
    it 'allows responses just above and exactly at the remaining-call floor' do
      [11, 10].each do |remaining|
        client, = build_client([
          raw_response(200, '<ok/>', 'X-Exl-Api-Remaining' => remaining.to_s)
        ], :client_settings => settings(:daily_quota_floor => 10))

        response = client.get('', :mms_id => "9910000#{remaining}")

        expect(response.remaining).to eq(remaining)
        expect(client.last_remaining).to eq(remaining)
      end
    end

    it 'raises QuotaFloorError when the remaining-call count drops below the floor' do
      client, = build_client([
        raw_response(200, '<ok/>', 'X-Exl-Api-Remaining' => '9')
      ], :client_settings => settings(:daily_quota_floor => 10))

      expect { client.get('', :mms_id => '991000009') }
        .to raise_error(AlmaIntegrations::QuotaFloorError, /below the configured floor of 10/)
      expect(client.last_remaining).to eq(9)
      expect(client.request_count).to eq(1)
    end

    it 'ignores missing and non-numeric remaining-call headers' do
      [
        {},
        { 'X-Exl-Api-Remaining' => 'not-a-number' }
      ].each do |headers|
        client, = build_client([
          raw_response(200, '<ok/>', headers)
        ], :client_settings => settings(:daily_quota_floor => 10))

        expect { client.get('', :mms_id => '991000001') }.not_to raise_error
        expect(client.last_remaining).to be_nil
      end
    end
  end

  describe 'response resilience' do
    it 'turns malformed XML, HTML gateway pages, and empty bodies into per-record errors' do
      cases = {
        'malformed XML' => raw_response(200, '<not <xml'),
        'HTML gateway page' => raw_response(502,
                                            '<html><body><h1>Bad Gateway</h1></body></html>',
                                            'Content-Type' => 'text/html'),
        'empty body' => raw_response(200, '')
      }

      cases.each_value do |response|
        client, = build_client([response])
        result = nil

        expect { result = client.each_bib(['991000001']).to_a }.not_to raise_error
        expect(result.length).to eq(1)
        expect(result.first[0]).to eq('991000001')
        expect(result.first[1]).to be_nil
        expect(result.first[2]).to be_a(String)
        expect(result.first[2]).not_to be_empty
      end
    end
  end

  describe '#request_count' do
    it 'counts each completed HTTP response, including retried attempts' do
      sleeps = []
      sleeper = ->(seconds) { sleeps << seconds }
      limiter = FakeLimiter.new(sleeper)
      client, = build_client([
        raw_response(429, error_xml('PER_SECOND_THRESHOLD', 'Too many requests')),
        raw_response(200, '<ok/>')
      ], :client_settings => settings(:max_retries => 1),
                         :limiter => limiter,
                         :sleeper => sleeper)

      response = client.get('', :mms_id => '991000001')

      expect(response.code).to eq(200)
      expect(client.request_count).to eq(2)
      expect(limiter.acquire_count).to eq(2)
      expect(sleeps.length).to eq(1)
    end
  end
end
