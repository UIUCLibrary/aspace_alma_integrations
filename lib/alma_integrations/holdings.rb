require 'erb'
require 'json'
require 'nokogiri'

module AlmaIntegrations
  # Builds the MARC holdings record the plugin posts to Alma for a collection.
  #
  # An archival collection is shelved as many containers under one call number,
  # so the holding is described as a multipart item holding (leader/06 'v') and
  # its 852 carries the EAD ID as a call number under "other scheme" (ind1 '8'),
  # since collection identifiers are neither LC nor Dewey.
  class HoldingRecord

    # Leader positions Alma does not recompute itself are spelt out here; the
    # '^' placeholders are how Alma's own holdings records represent blanks.
    #   05 n  new
    #   06 v  multipart item holdings
    #   17 1  holdings level 1
    #   18 n  no item information
    LEADER = '^^^^^nv^^a22^^^^^1n^4500'.freeze

    # 008/06-31 after the six-digit date entered on file:
    #   06 2 receipt status: received and complete
    #   07 u acquisition method unknown
    #   12 8 permanently retained
    #   16 4 completeness not applicable
    #   17-19 001 one copy
    FIXED_008 = '2u^^^^8^^^4001uueng0000000'.freeze

    CALL_NUMBER_SCHEME = '8'.freeze

    # The 852 $h for a collection: its EAD ID as written, dots and all. A
    # Resource with no EAD ID falls back to its four-part identifier joined by
    # dots, which is how ArchivesSpace's own exports render it.
    def self.call_number(ead_id: nil, identifier: nil)
      ead_id = ead_id.to_s.strip
      return ead_id unless ead_id.empty?

      parts = Array(identifier).map { |part| part.to_s.strip }.reject(&:empty?)
      parts.empty? ? nil : parts.join('.')
    end

    def self.build(library:, location:, call_number:, date: Time.now)
      doc = Nokogiri::XML('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')

      Nokogiri::XML::Builder.with(doc) do |xml|
        xml.holding {
          xml.record {
            xml.leader LEADER
            xml.controlfield(:tag => '008') { xml.text "#{date.strftime('%y%m%d')}#{FIXED_008}" }
            xml.datafield(:tag => '852', :ind1 => CALL_NUMBER_SCHEME, :ind2 => ' ') {
              xml.subfield(:code => 'b') { xml.text library.to_s }
              xml.subfield(:code => 'c') { xml.text location.to_s }
              xml.subfield(:code => 'h') { xml.text call_number.to_s } unless call_number.to_s.strip.empty?
            }
          }
        }
      end

      doc.to_xml
    end
  end

  # The locations a new holding can be placed in, offered in the Add Holdings
  # drop-down.
  #
  # The authoritative list lives in Alma, which knows every location in a library
  # and what it is called, so new shelving locations appear without anybody
  # editing config.rb. Reading it needs the Alma Configuration API, a separate
  # permission on the API key from the Bibs API the rest of the plugin uses, so
  # the static AppConfig[:alma_holdings] list remains as a fallback.
  class HoldingLocations

    Location = Struct.new(:library, :code, :name) do
      def label
        name.to_s.strip.empty? || name == code ? code : "#{name} (#{code})"
      end

      # The drop-down submits library and location together; a JSON pair avoids
      # inventing a delimiter that a location code might one day contain.
      def to_param
        [library, code].to_json
      end
    end

    # GET /almaws/v1/conf/libraries/{library}/locations, derived from the
    # configured bibs API URL, which ends in /bibs.
    def self.locations_url(api_url, library)
      base = api_url.to_s.strip.sub(%r{/+\z}, '')
      return nil if base.empty? || library.to_s.strip.empty?

      base = base.sub(%r{/bibs\z}, '')
      "#{base}/conf/libraries/#{ERB::Util.url_encode(library.to_s.strip)}/locations"
    end

    # Parses Alma's JSON location list for one library. Raises on a body that is
    # not the expected shape, so the caller can fall back rather than offer an
    # empty drop-down.
    def self.from_alma(library, body)
      obj = JSON.parse(body.to_s)
      raise ArgumentError, 'unexpected Alma location response' unless obj.is_a?(Hash)

      Array(obj['location']).filter_map do |entry|
        code = entry['code'].to_s.strip
        next if code.empty?

        Location.new(library.to_s, code, entry['name'].to_s.strip)
      end
    end

    # AppConfig[:alma_holdings]: [[library, location], ...], optionally with a
    # display name as a third element.
    def self.from_config(entries, translate: nil)
      Array(entries).filter_map do |entry|
        library, code, name = Array(entry).map { |value| value.to_s.strip }
        next if library.to_s.empty? || code.to_s.empty?

        name = translate.call(code) if name.to_s.empty? && translate
        Location.new(library, code, name.to_s.strip)
      end
    end

    # Drops locations the BIB already has a holding in, and duplicates.
    # `existing` holds [library, code] pairs; a nil library matches any.
    def self.available(locations, existing)
      existing = Array(existing)

      locations.uniq { |loc| [loc.library, loc.code] }.reject do |loc|
        existing.any? do |library, code|
          code == loc.code && (library.nil? || library == loc.library)
        end
      end
    end

    # Reads the library and location back out of a submitted drop-down value.
    def self.parse_param(value)
      pair = JSON.parse(value.to_s)
      return nil unless pair.is_a?(Array) && pair.length == 2

      library, code = pair.map { |part| part.to_s.strip }
      return nil if library.empty? || code.empty?

      [library, code]
    rescue JSON::ParserError
      nil
    end
  end
end
