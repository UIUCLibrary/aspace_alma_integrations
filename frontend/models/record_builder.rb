require 'nokogiri'

class RecordBuilder

  def build_bib(record, mms)
    marc = Nokogiri::XML(record)

    # Nokogiri won't put 'standalone' in the header so you have to do it yourself
    header = Nokogiri::XML('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')

    doc = Nokogiri::XML::Builder.with(header){ |xml| xml.bib }.to_xml

    data = Nokogiri::XML(doc)
    if mms
    	mms_id = Nokogiri::XML::Node.new('mms_id', data)
    	mms_id.content = mms
    	data.root.add_child(mms_id)
    end
    data.root.add_child(marc.at_css('record'))

    data.to_xml
  end

  def build_item(holding_id, barcode, description, profile, policy = nil)
    doc = Nokogiri::XML('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')

    builder = Nokogiri::XML::Builder.with(doc) do |xml|
      xml.item {
        xml.holding_data {
          xml.holding_id holding_id
        }
        xml.item_data {
          xml.barcode barcode if barcode.present?
          xml.description description
          xml.internal_note_2 profile if profile.present?
          xml.policy policy if policy.present?
        }
      }
    end

    builder.to_xml
  end

  # Updates only the ASpace-managed fields (barcode, description, internal_note_2)
  # in the full Alma item XML, preserving all other Alma-managed fields intact.
  # This is required for PUT requests to the Alma Items API, which replace the
  # entire item record and therefore require the full item XML to be sent back.
  def merge_item(alma_item_xml, barcode, description, profile)
    doc = alma_item_xml.dup

    item_data = doc.at_css('item_data')
    return nil if item_data.nil?

    set_or_create(doc, item_data, 'barcode', barcode.present? ? barcode : '')
    set_or_create(doc, item_data, 'description', description)
    set_or_create(doc, item_data, 'internal_note_2', profile.present? ? profile : '')

    doc.to_xml
  end

  def build_holding(library, location, call_number)
    AlmaIntegrations::HoldingRecord.build(:library => library,
                                          :location => location,
                                          :call_number => call_number)
  end

  private

  def set_or_create(doc, parent, tag, value)
    node = parent.at_css(tag)
    if node
      node.content = value
    else
      new_node = Nokogiri::XML::Node.new(tag, doc)
      new_node.content = value
      parent.add_child(new_node)
    end
  end

end
