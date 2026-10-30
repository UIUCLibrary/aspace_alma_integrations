require 'json'
require 'nokogiri'

module AlmaIntegrations
  # Base class for everything this plugin raises on its own behalf.
  class Error < StandardError; end

  # Raised when Alma reports that the institution's daily API allowance is gone.
  # Unlike the per-second threshold this cannot be waited out in any reasonable
  # amount of time, so jobs stop cleanly and record a resumable checkpoint.
  class DailyThresholdError < Error; end

  # Raised when the remaining daily allowance drops below the configured floor.
  # Stopping here leaves quota for the rest of the institution's integrations.
  class QuotaFloorError < Error; end

  # Raised when a request could not be completed after exhausting retries.
  class RequestFailedError < Error; end

  # A single error reported in an Alma response body.
  class AlmaError
    attr_reader :code, :message, :tracking_id

    def initialize(code, message, tracking_id = nil)
      @code = code
      @message = message
      @tracking_id = tracking_id
    end

    def to_s
      parts = []
      parts << "[#{code}]" unless code.nil? || code.empty?
      parts << message unless message.nil? || message.empty?
      parts << "(tracking id: #{tracking_id})" unless tracking_id.nil? || tracking_id.empty?
      parts.join(' ')
    end

    def to_h
      { 'code' => code, 'message' => message, 'tracking_id' => tracking_id }.reject { |_, v| v.nil? }
    end
  end

  # Alma error bodies arrive as XML (sometimes namespaced, sometimes not), as
  # JSON, and occasionally as an HTML error page from an intermediary. Over
  # thousands of requests all three will be seen, so parsing must never raise.
  module ErrorParser

    PER_SECOND_THRESHOLD = 'PER_SECOND_THRESHOLD'.freeze
    DAILY_THRESHOLD      = 'DAILY_THRESHOLD'.freeze

    module_function

    # Always returns an Array of AlmaError (possibly empty).
    def parse(body, content_type = nil)
      return [] if body.nil?

      body = body.to_s
      return [] if body.strip.empty?

      errors = if json_body?(body, content_type)
                 parse_json(body)
               else
                 parse_xml(body)
               end

      errors = [] if errors.nil?
      errors.empty? ? fallback(body) : errors
    rescue StandardError
      fallback(body)
    end

    def threshold_error?(errors, code)
      Array(errors).any? { |error| error.code.to_s.include?(code) }
    end

    # A single human-readable string for a response body, whatever shape it
    # arrived in. Falls back to the HTTP status so the caller always has
    # something to show rather than an empty message.
    def describe(body, status = nil)
      errors = parse(body)
      description = errors.map(&:to_s).reject { |text| text.strip.empty? }.join('; ')

      return description unless description.strip.empty?
      return "Alma returned HTTP #{status}" unless status.nil?

      'Alma returned an unreadable error'
    end

    def daily_threshold?(errors)
      threshold_error?(errors, DAILY_THRESHOLD)
    end

    def per_second_threshold?(errors)
      threshold_error?(errors, PER_SECOND_THRESHOLD)
    end

    def json_body?(body, content_type)
      return true if content_type.to_s.include?('json')

      body.lstrip.start_with?('{', '[')
    end

    def parse_json(body)
      parsed = JSON.parse(body)
      return [] unless parsed.is_a?(Hash)

      list = parsed['errorList'] || parsed['errorsList'] || {}
      entries = list.is_a?(Hash) ? list['error'] : list
      entries = [entries] if entries.is_a?(Hash)

      Array(entries).map do |entry|
        next unless entry.is_a?(Hash)

        AlmaError.new(entry['errorCode'], entry['errorMessage'], entry['trackingId'])
      end.compact
    rescue JSON::ParserError
      []
    end

    def parse_xml(body)
      doc = Nokogiri::XML(body)
      return [] if doc.nil? || doc.root.nil?

      # Alma is inconsistent about namespacing error documents, so drop them all
      # rather than guessing which one applies.
      doc.remove_namespaces!

      nodes = doc.xpath('//error')
      nodes = doc.xpath('//web_service_result') if nodes.empty?

      errors = nodes.map do |node|
        code = text_of(node, 'errorCode')
        message = text_of(node, 'errorMessage')
        tracking = text_of(node, 'trackingId')
        next if code.nil? && message.nil?

        AlmaError.new(code, message, tracking)
      end.compact

      return errors unless errors.empty?

      # Some responses put the code and message at the top level.
      code = text_of(doc, 'errorCode')
      message = text_of(doc, 'errorMessage')
      return [] if code.nil? && message.nil?

      [AlmaError.new(code, message, text_of(doc, 'trackingId'))]
    end

    def text_of(node, name)
      found = node.at_xpath(".//#{name}") || node.at_xpath("//#{name}")
      return nil if found.nil?

      value = found.text.to_s.strip
      value.empty? ? nil : value
    end

    # When nothing structured can be extracted, surface a truncated snippet of
    # the body so the job log still says something useful.
    def fallback(body)
      snippet = body.to_s.gsub(/\s+/, ' ').strip
      return [] if snippet.empty?

      snippet = "#{snippet[0, 500]}..." if snippet.length > 500
      [AlmaError.new(nil, snippet)]
    end
  end
end
