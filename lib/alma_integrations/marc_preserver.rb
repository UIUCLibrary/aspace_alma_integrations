require 'nokogiri'

require_relative 'settings'

module AlmaIntegrations
  # Prepares the ArchivesSpace-generated MARC record for overlay into Alma by
  # carrying across the fields that ArchivesSpace does not manage.
  #
  # This is the single implementation used by both the single-record "Push to
  # Alma" screen and the bulk audit, so the report can never describe a different
  # record than the one that would actually be sent.
  #
  # Two things are preserved:
  #
  #   * MARC 008/00-05, the "Date Entered on File". ArchivesSpace regenerates
  #     this every time it produces MARC output, so without intervention a push
  #     would silently replace Alma's original creation date with today's.
  #
  #   * Every tag listed in AppConfig[:alma_marc_fields_to_preserve]. All
  #     ArchivesSpace instances of the tag are removed and the Alma instances are
  #     put in their place, in correct MARC tag order.
  class MarcPreserver

    Result = Struct.new(:record, :warnings, :preserved_counts, :date_entered_preserved) do
      def to_xml(indent: 2)
        record.nil? ? nil : record.to_xml(:indent => indent)
      end
    end

    def initialize(settings = nil)
      @settings = settings.is_a?(Settings) ? settings : Settings.new(settings || {})
      @preserved_tags = Array(@settings[:preserved_tags]).map(&:to_s).uniq
    end

    # aspace_source and alma_source may each be a Nokogiri node or a MARCXML
    # string. The returned record is always a detached copy, so neither input is
    # modified.
    def apply(aspace_source, alma_source)
      aspace = record_node(aspace_source)
      return Result.new(nil, ['No ArchivesSpace MARC record to prepare.'], {}, false) if aspace.nil?

      aspace = aspace.dup
      alma = record_node(alma_source)

      warnings = []
      counts = {}

      if alma.nil?
        # Nothing to preserve from: this is a new record in Alma.
        return Result.new(aspace, warnings, counts, false)
      end

      date_preserved = preserve_date_entered(aspace, alma, warnings)

      @preserved_tags.each do |tag|
        counts[tag] = preserve_tag(aspace, alma, tag)
      end

      Result.new(aspace, warnings, counts, date_preserved)
    end

    private

    def record_node(source)
      return nil if source.nil?

      node = if source.is_a?(Nokogiri::XML::Node)
               source
             else
               doc = Nokogiri::XML(source.to_s, &:noblanks)
               return nil if doc.root.nil?

               doc.remove_namespaces!
               doc.root
             end

      node.name == 'record' ? node : node.at_xpath('.//record')
    end

    # Copy Alma's 008/00-05 into the outgoing record.
    #
    # The original implementation dereferenced both control fields without
    # checking for their presence, so a single record missing an 008 on either
    # side raised NoMethodError. In a bulk run that would abort the whole job.
    def preserve_date_entered(aspace, alma, warnings)
      aspace_008 = aspace.at_xpath('./controlfield[@tag="008"]')
      alma_008 = alma.at_xpath('./controlfield[@tag="008"]')

      if aspace_008.nil?
        warnings << 'The ArchivesSpace record has no 008 field, so the Alma "Date Entered on File" could not be preserved.'
        return false
      end

      if alma_008.nil?
        warnings << 'The Alma record has no 008 field, so there is no "Date Entered on File" to preserve.'
        return false
      end

      alma_value = alma_008.text.to_s
      aspace_value = aspace_008.text.to_s

      if alma_value.length < 6
        warnings << 'The Alma 008 field is too short to contain a "Date Entered on File".'
        return false
      end

      return true if aspace_value[0, 6] == alma_value[0, 6]

      remainder = aspace_value.length > 6 ? aspace_value[6..-1] : ''
      aspace_008.content = "#{alma_value[0, 6]}#{remainder}"

      true
    end

    def preserve_tag(aspace, alma, tag)
      xpath = field_xpath(tag)
      return 0 if xpath.nil?

      aspace.xpath(xpath).each(&:remove)

      alma_fields = alma.xpath(xpath)
      alma_fields.each do |field|
        insert_in_tag_order(aspace, field.dup, tag)
      end

      alma_fields.length
    end

    # Tags are restricted to the MARC character set before being interpolated
    # into an XPath expression, so a stray configuration value cannot alter the
    # meaning of the query.
    def field_xpath(tag)
      tag = tag.to_s
      return nil unless tag.match?(/\A[A-Za-z0-9]{1,3}\z/)

      "./controlfield[@tag='#{tag}'] | ./datafield[@tag='#{tag}']"
    end

    # Insert a field so that the record stays in MARC tag order.
    #
    # The original implementation looked for the first field with a numerically
    # greater tag, which misplaced the field whenever the record was not already
    # strictly sorted, and collapsed every alphabetic local tag to 0. Anchoring
    # on the *last* field that sorts at or before the new tag is correct for an
    # unsorted record and keeps repeated instances of the same tag together.
    def insert_in_tag_order(record, field, tag)
      existing = record.xpath('./controlfield | ./datafield')
      key = sort_key(tag)

      anchor = existing.select { |node| sort_key(node['tag']) <= key }.last

      if anchor
        anchor.add_next_sibling(field)
      elsif existing.first
        existing.first.add_previous_sibling(field)
      else
        record.add_child(field)
      end
    end

    # MARC tags are three characters and may be alphanumeric in local practice.
    # Plain string comparison on the zero-padded tag puts numeric tags in order
    # and sorts local alphabetic tags after them, which is the conventional
    # arrangement; comparing as integers does neither.
    def sort_key(tag)
      tag.to_s.rjust(3, '0')
    end
  end
end
