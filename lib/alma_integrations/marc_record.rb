require 'nokogiri'

module AlmaIntegrations
  # A plain-Ruby view of a MARCXML record.
  #
  # Parsing once into simple structures keeps the diff engine free of Nokogiri
  # node identity concerns and makes it straightforward to test with literal
  # data.
  class MarcField

    attr_reader :tag, :ind1, :ind2, :value, :subfields, :position

    def initialize(tag:, ind1: nil, ind2: nil, value: nil, subfields: nil, position: nil)
      @tag = tag.to_s
      @ind1 = ind1
      @ind2 = ind2
      @value = value
      @subfields = subfields
      @position = position
    end

    def control?
      @subfields.nil?
    end

    def indicators
      control? ? nil : "#{blank_indicator(ind1)}#{blank_indicator(ind2)}"
    end

    def subfield_values(code)
      return [] if control?

      subfields.select { |c, _| c == code.to_s }.map { |_, v| v }
    end

    # A human readable single-line rendering, used in the report so a cataloguer
    # can see what would be lost without reading XML.
    def display
      return "#{tag}  #{value}" if control?

      rendered = subfields.map { |code, val| "$#{code} #{val}" }.join(' ')
      "#{tag} #{indicators} #{rendered}".rstrip
    end

    def to_h
      if control?
        { 'tag' => tag, 'value' => value, 'display' => display }
      else
        {
          'tag' => tag,
          'ind1' => blank_indicator(ind1),
          'ind2' => blank_indicator(ind2),
          'subfields' => subfields.map { |code, val| { 'code' => code, 'value' => val } },
          'display' => display
        }
      end
    end

    private

    def blank_indicator(indicator)
      value = indicator.to_s
      value.empty? ? ' ' : value
    end
  end

  class MarcRecord

    attr_reader :leader, :fields

    def self.parse(source)
      return source if source.is_a?(MarcRecord)
      return new(nil, []) if source.nil?

      node = if source.is_a?(Nokogiri::XML::Node)
               source
             else
               doc = Nokogiri::XML(source.to_s)
               doc.remove_namespaces! unless doc.root.nil?
               doc.root
             end

      return new(nil, []) if node.nil?

      # Accept either a <record> node or a wrapper that contains one.
      record = node.name == 'record' ? node : node.at_xpath('.//record')
      return new(nil, []) if record.nil?

      leader = record.at_xpath('./leader')&.text

      fields = []
      record.xpath('./controlfield | ./datafield').each_with_index do |field, index|
        if field.name == 'controlfield'
          fields << MarcField.new(:tag => field['tag'], :value => field.text, :position => index)
        else
          subfields = field.xpath('./subfield').map { |sub| [sub['code'].to_s, sub.text.to_s] }
          fields << MarcField.new(:tag => field['tag'],
                                  :ind1 => field['ind1'],
                                  :ind2 => field['ind2'],
                                  :subfields => subfields,
                                  :position => index)
        end
      end

      new(leader, fields, record)
    end

    def initialize(leader, fields, source_node = nil)
      @leader = leader
      @fields = fields || []
      @source_node = source_node
    end

    # The record exactly as it arrived. The audit stores Alma's MARC verbatim as
    # a failsafe, so this deliberately returns the original serialisation rather
    # than a round trip through the parsed model -- a round trip could quietly
    # normalise away the very thing someone is trying to recover.
    def to_xml
      return nil if @source_node.nil?

      @source_node.to_xml
    end

    def empty?
      leader.nil? && fields.empty?
    end

    def tags
      fields.map(&:tag).uniq
    end

    def fields_for(tag)
      tag = tag.to_s
      fields.select { |field| field.tag == tag }
    end

    def controlfield(tag)
      fields_for(tag).find(&:control?)
    end

    def controlfield_value(tag)
      controlfield(tag)&.value
    end
  end
end
