require 'spec_helper'

RSpec.describe AlmaIntegrations::MarcRecord do
  describe '.parse' do
    it 'parses leader, control fields, data fields, indicators, subfields, and positions from MARCXML' do
      record = described_class.parse(
        marc_xml(
          leader: '00000nam a2200000 i 4500',
          controlfields: {
            '001' => 'alma-001',
            '008' => '230101s1999    ilu                 eng  '
          },
          datafields: [
            ['245', '1', '0', [['a', 'Collection title'], ['b', 'subtitle']]],
            ['650', ' ', '7', [['a', 'Archives'], ['2', 'local']]]
          ]
        )
      )

      expect(record.leader).to eq('00000nam a2200000 i 4500')
      expect(record.fields.map(&:tag)).to eq(%w[001 008 245 650])
      expect(record.tags).to eq(%w[001 008 245 650])

      control = record.controlfield('001')
      expect(control).to be_control
      expect(control.value).to eq('alma-001')
      expect(control.position).to eq(0)
      expect(control.display).to eq('001  alma-001')
      expect(control.to_h).to eq(
        'tag' => '001',
        'value' => 'alma-001',
        'display' => '001  alma-001'
      )

      title = record.fields_for('245').first
      expect(title).not_to be_control
      expect(title.position).to eq(2)
      expect(title.indicators).to eq('10')
      expect(title.subfield_values('a')).to eq(['Collection title'])
      expect(title.subfield_values(:b)).to eq(['subtitle'])
      expect(title.display).to eq('245 10 $a Collection title $b subtitle')
      expect(title.to_h).to eq(
        'tag' => '245',
        'ind1' => '1',
        'ind2' => '0',
        'subfields' => [
          { 'code' => 'a', 'value' => 'Collection title' },
          { 'code' => 'b', 'value' => 'subtitle' }
        ],
        'display' => '245 10 $a Collection title $b subtitle'
      )
    end

    it 'normalizes blank and missing indicators for display and hashes' do
      record = marc_record(
        datafields: [
          ['590', nil, '', [['a', 'Local note']]]
        ]
      )

      field = record.fields_for('590').first
      expect(field.indicators).to eq('  ')
      expect(field.display).to eq('590    $a Local note')
      expect(field.to_h['ind1']).to eq(' ')
      expect(field.to_h['ind2']).to eq(' ')
    end

    it 'accepts wrapper documents and namespaces around the record' do
      xml = <<~XML
        <collection xmlns="http://www.loc.gov/MARC21/slim">
          #{marc_xml(controlfields: { '001' => 'wrapped-id' })}
        </collection>
      XML

      record = described_class.parse(xml)

      expect(record).not_to be_empty
      expect(record.controlfield_value('001')).to eq('wrapped-id')
    end

    it 'accepts a Nokogiri record node without requiring callers to serialize it first' do
      node = marc_node(
        controlfields: { '001' => 'node-id' },
        datafields: [
          ['100', '1', ' ', [['a', 'Creator, Example']]]
        ]
      )

      record = described_class.parse(node)

      expect(record.controlfield_value('001')).to eq('node-id')
      expect(record.fields_for(100).first.subfield_values('a')).to eq(['Creator, Example'])
    end

    it 'returns an existing MarcRecord instance unchanged' do
      record = marc_record(controlfields: { '001' => 'already-parsed' })

      expect(described_class.parse(record)).to be(record)
    end

    it 'returns an empty record for nil, blank XML, or XML with no record element' do
      [nil, '', '<not_a_record><controlfield tag="001">ignored</controlfield></not_a_record>'].each do |source|
        record = described_class.parse(source)

        expect(record).to be_empty
        expect(record.leader).to be_nil
        expect(record.fields).to eq([])
        expect(record.to_xml).to be_nil
      end
    end

    it 'retains the original record node serialization as a recovery copy' do
      xml = marc_xml(
        leader: '00000nam a2200000 i 4500',
        controlfields: { '001' => 'alma-001' }
      )

      record = described_class.parse(xml)

      expect(record.to_xml).to include('<leader>00000nam a2200000 i 4500</leader>')
      expect(record.to_xml).to include('<controlfield tag="001">alma-001</controlfield>')
    end
  end
end
