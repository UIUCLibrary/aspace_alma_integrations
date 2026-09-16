require 'net/http'
require 'uri'
require 'nokogiri'

require_relative 'errors'
require_relative 'rate_limiter'

module AlmaIntegrations
  # A throttled, retrying, connection-reusing HTTP client for the Alma bibs API.
  #
  # Compared with the plugin's original AlmaRequester this class:
  #
  #   * sends the API key in an Authorization header instead of the query string,
  #     keeping it out of Alma's and any intermediary's access logs;
  #   * reuses a single keep-alive connection instead of opening one per call;
  #   * sets explicit open/read timeouts so a hung socket cannot stall a job that
  #     is working through thousands of records;
  #   * draws from a shared token bucket so the process as a whole stays under
  #     Alma's per-institution governance threshold;
  #   * retries 429 (PER_SECOND_THRESHOLD) responses with exponential backoff and
  #     jitter, and stops cleanly on DAILY_THRESHOLD;
  #   * watches the X-Exl-Api-Remaining header and refuses to spend the last of
  #     the institution's daily allowance.
  class AlmaClient

    REMAINING_HEADER = 'x-exl-api-remaining'.freeze

    # Alma accepts at most 100 comma-separated MMS IDs on the multi-record GET.
    MAX_BULK_FETCH = 100

    class Response
      attr_reader :code, :body, :headers

      def initialize(code, body, headers = {})
        @code = code.to_i
        @body = body
        @headers = headers || {}
      end

      def success?
        code >= 200 && code < 300
      end

      def content_type
        headers['content-type']
      end

      def errors
        @errors ||= success? ? [] : ErrorParser.parse(body, content_type)
      end

      def error_message
        return nil if errors.empty?

        errors.map(&:to_s).join('; ')
      end

      def remaining
        value = headers[REMAINING_HEADER]
        return nil if value.nil? || value.to_s.strip.empty?

        Integer(value.to_s.strip)
      rescue ArgumentError, TypeError
        nil
      end
    end

    attr_reader :settings, :limiter, :last_remaining

    def initialize(settings: nil, limiter: nil, logger: nil, http_factory: nil, sleeper: nil, rng: nil)
      @settings = settings || Settings.new
      @base_uri = URI(@settings[:api_url].to_s)
      @api_key = @settings[:api_key]
      @limiter = limiter || AlmaIntegrations.shared_rate_limiter(@settings[:requests_per_second])
      @logger = logger
      @http_factory = http_factory
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @rng = rng || Random.new
      @mutex = Mutex.new
      @http = nil
      @last_remaining = nil
      @request_count = 0
    end

    def request_count
      @request_count
    end

    def get(subpath = '', query = {})
      execute(:get, subpath, nil, query)
    end

    def put(subpath, body, query = {})
      execute(:put, subpath, body, query)
    end

    def post(subpath, body, query = {})
      execute(:post, subpath, body, query)
    end

    # Retrieve many bib records in a single call.
    #
    # Alma's multi-record GET returns the full MARC21 record for up to 100 MMS
    # IDs at a time, which turns a 1,200 record audit into ~12 API calls instead
    # of 1,200.
    #
    # Yields [mms_id, record_node_or_nil, error_message_or_nil] for every
    # requested id, in the order supplied, so that ids Alma did not return are
    # still accounted for.
    def each_bib(mms_ids)
      return enum_for(:each_bib, mms_ids) unless block_given?

      chunk_size = [[@settings[:bulk_fetch_size].to_i, 1].max, MAX_BULK_FETCH].min

      Array(mms_ids).each_slice(chunk_size) do |chunk|
        response = get('', :mms_id => chunk.join(','))

        unless response.success?
          message = response.error_message || "HTTP #{response.code}"
          chunk.each { |mms_id| yield(mms_id, nil, message) }
          next
        end

        records = index_bib_response(response.body)

        chunk.each do |mms_id|
          entry = records[mms_id.to_s]
          if entry.nil?
            yield(mms_id, nil, 'Record not found in Alma')
          else
            yield(mms_id, entry, nil)
          end
        end
      end
    end

    def close
      @mutex.synchronize { reset_connection }
    end

    private

    def index_bib_response(body)
      doc = Nokogiri::XML(body, &:noblanks)
      return {} if doc.nil? || doc.root.nil?

      doc.remove_namespaces!

      index = {}
      doc.xpath('//bib').each do |bib|
        mms_node = bib.at_xpath('./mms_id')
        record = bib.at_xpath('./record')
        next if record.nil?

        # Fall back to the 001 when the bib wrapper has no mms_id element.
        key = if mms_node
                mms_node.text.to_s.strip
              else
                bib.at_xpath('./record/controlfield[@tag="001"]')&.text.to_s.strip
              end
        next if key.empty?

        index[key] = record
      end

      index
    end

    def execute(method, subpath, body, query)
      uri = build_uri(subpath, query)
      attempt = 0

      loop do
        attempt += 1
        @limiter.acquire

        begin
          response = perform(method, uri, body)
        rescue *retryable_network_errors => e
          @mutex.synchronize { reset_connection }
          raise RequestFailedError, "#{method.to_s.upcase} #{redact(uri)} failed: #{e.class}: #{e.message}" unless retry_network?(method, attempt)

          log("Network error on #{method.to_s.upcase} #{redact(uri)} (#{e.class}); retrying (attempt #{attempt})")
          @sleeper.call(backoff_delay(attempt))
          next
        end

        @request_count += 1
        track_remaining(response)

        if throttled?(response)
          raise RequestFailedError, "Alma per-second threshold still exceeded after #{attempt} attempts" if attempt > max_retries

          delay = backoff_delay(attempt)
          log("Alma reported the per-second threshold; backing off for #{format('%.2f', delay)}s (attempt #{attempt})")
          @limiter.penalize(delay)
          next
        end

        raise DailyThresholdError, daily_threshold_message(response) if daily_threshold?(response)

        if server_error?(response) && retry_server_error?(method, attempt)
          delay = backoff_delay(attempt)
          log("Alma returned HTTP #{response.code}; retrying in #{format('%.2f', delay)}s (attempt #{attempt})")
          @sleeper.call(delay)
          next
        end

        enforce_quota_floor!

        return response
      end
    end

    def perform(method, uri, body)
      @mutex.synchronize do
        http = connection(uri)
        request = build_request(method, uri, body)
        raw = http.request(request)

        headers = {}
        raw.each_header { |name, value| headers[name.to_s.downcase] = value }

        Response.new(raw.code, raw.body, headers)
      end
    end

    def build_request(method, uri, body)
      request = case method
                when :get then Net::HTTP::Get.new(uri)
                when :put then Net::HTTP::Put.new(uri)
                when :post then Net::HTTP::Post.new(uri)
                else raise ArgumentError, "Unsupported method #{method}"
                end

      request['Authorization'] = "apikey #{@api_key}"
      request['Accept'] = 'application/xml'

      unless body.nil?
        request.body = body
        request.content_type = 'application/xml'
      end

      request
    end

    def connection(uri)
      if @http && (@http.address != uri.host || @http.port != uri.port || !@http.started?)
        reset_connection
      end

      return @http if @http

      @http = if @http_factory
                @http_factory.call(uri)
              else
                http = Net::HTTP.new(uri.host, uri.port)
                http.use_ssl = (uri.scheme == 'https')
                http.open_timeout = @settings[:open_timeout]
                http.read_timeout = @settings[:read_timeout]
                http.keep_alive_timeout = 30 if http.respond_to?(:keep_alive_timeout=)
                http.start
                http
              end

      @http
    end

    def reset_connection
      @http.finish if @http && @http.respond_to?(:started?) && @http.started?
    rescue StandardError
      nil
    ensure
      @http = nil
    end

    def build_uri(subpath, query)
      uri = @base_uri.dup
      subpath = subpath.to_s

      unless subpath.empty?
        subpath = "/#{subpath}" unless subpath.start_with?('/')
        uri.path = "#{uri.path}#{subpath}"
      end

      params = (query || {}).reject { |_, value| value.nil? }
      uri.query = params.empty? ? nil : URI.encode_www_form(params)
      uri
    end

    def track_remaining(response)
      remaining = response.remaining
      @last_remaining = remaining unless remaining.nil?
    end

    def enforce_quota_floor!
      floor = @settings[:daily_quota_floor].to_i
      return if floor <= 0
      return if @last_remaining.nil?
      return if @last_remaining >= floor

      raise QuotaFloorError,
            "Alma reports only #{@last_remaining} API calls remaining today, which is below the " \
            "configured floor of #{floor}. Stopping so the remaining allowance stays available " \
            'to the rest of the institution.'
    end

    def throttled?(response)
      return true if response.code == 429

      !response.success? && ErrorParser.per_second_threshold?(response.errors)
    end

    def daily_threshold?(response)
      !response.success? && ErrorParser.daily_threshold?(response.errors)
    end

    def daily_threshold_message(response)
      message = response.error_message
      base = "Alma reports that the institution's daily API request threshold has been reached."
      message.nil? ? base : "#{base} #{message}"
    end

    def server_error?(response)
      response.code >= 500
    end

    def max_retries
      @settings[:max_retries].to_i
    end

    # A bib PUT is a full replacement, so replaying it is safe. A POST creates a
    # new record and must never be replayed automatically.
    def idempotent?(method)
      method != :post
    end

    def retry_server_error?(method, attempt)
      idempotent?(method) && attempt <= max_retries
    end

    def retry_network?(method, attempt)
      idempotent?(method) && attempt <= max_retries
    end

    def retryable_network_errors
      [Timeout::Error, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
       Errno::ETIMEDOUT, Errno::EHOSTUNREACH, EOFError, IOError, SocketError,
       Net::HTTPBadResponse, Net::ReadTimeout, Net::OpenTimeout]
    end

    def backoff_delay(attempt)
      base = @settings[:retry_base_delay].to_f
      max = @settings[:retry_max_delay].to_f
      capped = [base * (2**([attempt, 10].min - 1)), max].min
      # Full jitter over the lower half of the window: enough randomness to break
      # up synchronised retries without ever waiting less than half the backoff.
      capped * (0.5 + (@rng.rand * 0.5))
    end

    def redact(uri)
      redacted = uri.dup
      redacted.query = nil
      redacted.to_s
    end

    def log(message)
      @logger.call(message) if @logger
    end
  end
end
