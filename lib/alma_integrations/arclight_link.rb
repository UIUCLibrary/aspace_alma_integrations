require 'erb'
require 'json'
require 'nokogiri'
require 'uri'

require_relative 'settings'

module AlmaIntegrations
  # Adds a MARC 956 to the outgoing record pointing at the collection's page in
  # Arclight, the public discovery front end.
  #
  # Alma has no idea the finding aid exists unless the record says so, and
  # ArchivesSpace's own MARC export only emits an 856 when the Resource has an
  # EAD Location filled in by hand. This derives the link instead, from the same
  # identifier Arclight builds its own URLs from, so every pushed record carries
  # one without anybody maintaining a URL field.
  #
  # The URL pattern is Arclight's, not ours, and is reproduced here rather than
  # configured because it is structural:
  #
  #   collection  <base>/catalog/<slug>
  #   component   <base>/catalog/<slug>_<component id>
  #
  # where <slug> is Arclight's normalised ID. Arclight's own normaliser
  # (Arclight::NormalizedId) is exactly `id.strip.tr('.', '-')` -- dots become
  # dashes and nothing else is touched -- and its component IDs are the root
  # slug joined to the `id` attribute of the EAD <c> element, which
  # ArchivesSpace writes as `aspace_<ref_id>`.
  #
  # Only the base URL and the link text are configurable, because only those
  # vary between institutions.
  class ArclightLink

    TAG = '956'

    # Arclight's component IDs are the root slug and the EAD element ID joined
    # by an underscore, and ArchivesSpace prefixes its EAD element IDs with
    # this. A caller may pass either form of ref ID.
    ASPACE_REF_PREFIX = 'aspace_'.freeze

    # Only ever link over http(s). A base URL that is anything else -- a
    # javascript: or data: URI pasted into the config by accident or otherwise
    # -- would travel into Alma and from there into every catalogue interface
    # that renders the field.
    ALLOWED_SCHEMES = %w[http https].freeze

    def initialize(settings = nil)
      @settings = settings.is_a?(Settings) ? settings : Settings.new(settings || {})
      @base_url = normalize_base_url(@settings[:arclight_base_url])
      @id_source = @settings[:arclight_id_source].to_s.strip.downcase
      @id_source = 'auto' if @id_source.empty?
      @ind1, @ind2 = split_indicators(@settings[:arclight_indicators])
    end

    attr_reader :base_url

    # False when no Arclight base URL has been configured, in which case this
    # whole feature is inert and no record is touched.
    def configured?
      !@base_url.nil?
    end

    # The Arclight slug for a collection.
    #
    # ArchivesSpace keeps two things that could be the collection's public ID:
    # the EAD ID, and the four-part Resource identifier. Arclight derives its
    # root ID from <eadid> out of the box, but an institution whose EAD IDs are
    # blank or unrelated to its call numbers will be indexing something else, so
    # the source is selectable. `auto` prefers the EAD ID and falls back to the
    # identifier.
    #
    # The identifier may arrive as an array of parts, as the JSON array
    # ArchivesSpace stores in the database, or as a string. Parts are joined
    # with dots first, matching what the MARC and EAD exports do with them, and
    # the dots then become dashes like any other.
    def collection_slug(ead_id: nil, identifier: nil)
      candidates =
        case @id_source
        when 'ead_id'    then [ead_id]
        when 'identifier' then [identifier]
        else [ead_id, identifier]
        end

      candidates.each do |candidate|
        slug = normalize_id(candidate)
        return slug unless slug.nil?
      end

      nil
    end

    # The Arclight URL for a collection, or for one component within it when a
    # ref ID is given.
    def url(ead_id: nil, identifier: nil, ref_id: nil)
      return nil unless configured?

      slug = collection_slug(:ead_id => ead_id, :identifier => identifier)
      return nil if slug.nil?

      segment = slug
      component = component_id(ref_id)
      segment = "#{segment}_#{component}" unless component.nil?

      "#{@base_url}/catalog/#{escape(segment)}"
    end

    # Adds the 956 to a MARC record node, in place.
    #
    # Any 956 already pointing into the same Arclight instance is replaced, so
    # running this over a record that has been pushed before does not accumulate
    # duplicates and a changed base URL or link text takes effect. A 956 put
    # there for some other local purpose is left alone.
    #
    # Returns the URL that was written, or nil when nothing was written.
    def apply(record, ead_id: nil, identifier: nil, ref_id: nil, link_text: nil)
      return nil if record.nil?

      href = url(:ead_id => ead_id, :identifier => identifier, :ref_id => ref_id)
      return nil if href.nil?

      remove_existing(record)

      field = Nokogiri::XML::Node.new('datafield', record.document)
      field['tag'] = TAG
      field['ind1'] = @ind1
      field['ind2'] = @ind2
      field.add_child(subfield(record, 'u', href))

      text = link_text.to_s.strip
      text = @settings[:arclight_link_text].to_s.strip if text.empty?
      field.add_child(subfield(record, 'y', text)) unless text.empty?

      insert_in_tag_order(record, field)

      href
    end

    private

    def subfield(record, code, value)
      node = Nokogiri::XML::Node.new('subfield', record.document)
      node['code'] = code
      node.content = value
      node
    end

    # Matches on the base URL rather than on the tag alone: 956 is a local
    # field and another system may legitimately be using it on the same record.
    def remove_existing(record)
      record.xpath("./datafield[@tag='#{TAG}']").each do |field|
        urls = field.xpath("./subfield[@code='u']").map { |node| node.text.to_s.strip }
        next unless urls.any? { |value| value.start_with?("#{@base_url}/") || value == @base_url }

        field.remove
      end
    end

    # Keeps the record in MARC tag order. Mirrors MarcPreserver's insertion:
    # anchor on the last field that sorts at or before this one, which behaves
    # correctly even when the record it is handed is not strictly sorted.
    def insert_in_tag_order(record, field)
      existing = record.xpath('./controlfield | ./datafield')
      anchor = existing.select { |node| node['tag'].to_s.rjust(3, '0') <= TAG }.last

      if anchor
        anchor.add_next_sibling(field)
      elsif existing.first
        existing.first.add_previous_sibling(field)
      else
        record.add_child(field)
      end
    end

    def component_id(ref_id)
      ref_id = ref_id.to_s.strip
      return nil if ref_id.empty?

      ref_id.start_with?(ASPACE_REF_PREFIX) ? ref_id : "#{ASPACE_REF_PREFIX}#{ref_id}"
    end

    def normalize_id(value)
      parts = identifier_parts(value)
      return nil if parts.empty?

      slug = parts.join('.').strip.tr('.', '-')
      slug.empty? ? nil : slug
    end

    def identifier_parts(value)
      case value
      when nil then []
      when Array then value.map { |part| part.to_s.strip }.reject(&:empty?)
      else
        text = value.to_s.strip
        return [] if text.empty?

        # ArchivesSpace stores the Resource identifier as a JSON array of up to
        # four parts. Callers that read it straight out of the database hand it
        # over in that form.
        if text.start_with?('[')
          parsed = (JSON.parse(text) rescue nil)
          return identifier_parts(parsed) if parsed.is_a?(Array)
        end

        [text]
      end
    end

    # Escapes the slug as a single path segment. Identifiers are free text in
    # ArchivesSpace and one containing a space, a slash or a question mark would
    # otherwise produce a URL that points somewhere else entirely.
    def escape(segment)
      ERB::Util.url_encode(segment)
    end

    def normalize_base_url(value)
      value = value.to_s.strip
      return nil if value.empty?

      value = value.sub(%r{/+\z}, '')
      return nil if value.empty?

      uri = (URI.parse(value) rescue nil)
      return nil if uri.nil? || !ALLOWED_SCHEMES.include?(uri.scheme.to_s.downcase)
      return nil if uri.host.to_s.empty?

      value
    end

    # Indicators are configurable because 956 is locally defined and local Alma
    # normalisation rules may key on them. Anything that is not exactly two
    # characters falls back to the default rather than producing a malformed
    # field.
    def split_indicators(value)
      value = value.to_s
      return [value[0], value[1]] if value.length == 2

      default = Settings::DEFAULTS[:arclight_indicators].to_s
      [default[0], default[1]]
    end
  end
end
