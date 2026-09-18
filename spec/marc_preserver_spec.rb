require 'spec_helper'

RSpec.describe AlmaIntegrations::MarcPreserver do
  def apply(aspace_source, alma_source, settings = nil)
    described_class.new(settings).apply(aspace_source, alma_source)
  end

  def fixed_008(date_entered: '240101', date1: '1999', date2: '    ', place: 'ilu', material: '                 ', language: 'eng', modified: ' ', source: ' ')
    "#{date_entered}s#{date1}#{date2}#{place}#{material}#{language}#{modified}#{source}"
  end

  def control_value(result, tag)
    result.record.at_xpath("./controlfield[@tag='#{tag}']").text
  end

  def datafield_values(result, tag, code)
    result.record.xpath("./datafield[@tag='#{tag}']/subfield[@code='#{code}']").map(&:text)
  end

  def field_tags(result)
    result.record.xpath('./controlfield | ./datafield').map { |node| node['tag'] }
  end

  describe '#apply' do
    it 'preserves Alma 008 positions 00-05 so Date Entered on File is not silently overwritten' do
      aspace_008 = fixed_008(date_entered: '260916', date1: '2001', place: 'ilu', language: 'eng')
      alma_008 = fixed_008(date_entered: '990101', date1: '1980', place: 'nyu', language: 'fre')
      aspace = marc_node(
        controlfields: { '008' => aspace_008 },
        datafields: [['245', '1', '0', [['a', 'ArchivesSpace title']]]]
      )
      alma = marc_node(controlfields: { '008' => alma_008 })

      result = apply(aspace, alma)

      expect(result.date_entered_preserved).to be(true)
      expect(control_value(result, '008')).to eq("990101#{aspace_008[6..-1]}")
      expect(aspace.at_xpath('./controlfield[@tag="008"]').text).to eq(aspace_008)
      expect(result.warnings).to eq([])
      expect(result.preserved_counts).to eq({})
      expect(result.to_xml).to include('<controlfield tag="008">990101')
    end

    # ArchivesSpace exports MARC in the http://www.loc.gov/MARC21/slim
    # namespace, and the single-record push screen hands the exported node
    # straight to the preserver. Every XPath here is written without a
    # namespace prefix, so a record that arrives still carrying its namespace
    # silently matches nothing: Alma's Date Entered on File was left
    # unpreserved and preserved fields were appended after the last field
    # rather than put in tag order. The other examples in this file build
    # nodes without a namespace, which is why this went unnoticed.
    it 'preserves fields from a namespaced ArchivesSpace export' do
      aspace = Nokogiri::XML(<<~XML, &:noblanks).at_xpath('//*[local-name()="record"]')
        <?xml version="1.0" encoding="UTF-8"?>
        <collection xmlns="http://www.loc.gov/MARC21/slim">
          <record>
            <leader>00000npcaa2200000 u 4500</leader>
            <controlfield tag="008">260918i19512007xx                  eng d</controlfield>
            <datafield ind1="0" ind2="0" tag="245">
              <subfield code="a">ArchivesSpace title</subfield>
            </datafield>
            <datafield ind1=" " ind2=" " tag="852">
              <subfield code="a">Repository</subfield>
            </datafield>
          </record>
        </collection>
      XML

      alma = Nokogiri::XML(<<~XML, &:noblanks).at_xpath('./record')
        <record>
          <controlfield tag="008">061207i19512007xx                  eng d</controlfield>
          <datafield ind1=" " ind2=" " tag="035">
            <subfield code="a">(ALA-Ar) 27/10/69</subfield>
          </datafield>
        </record>
      XML

      result = apply(aspace, alma, preserved_tags: ['035'])

      expect(result.date_entered_preserved).to be(true)
      expect(control_value(result, '008')).to start_with('061207')
      expect(result.preserved_counts).to eq({ '035' => 1 })
      expect(datafield_values(result, '035', 'a')).to eq(['(ALA-Ar) 27/10/69'])
      # The 035 belongs between the 008 and the 245, not at the end.
      expect(field_tags(result)).to eq(%w[008 035 245 852])
      expect(result.warnings).to eq([])
    end

    it 'leaves the caller\'s document alone when handed a namespaced node' do
      doc = Nokogiri::XML(<<~XML, &:noblanks)
        <collection xmlns="http://www.loc.gov/MARC21/slim">
          <record>
            <controlfield tag="008">260918i19512007xx                  eng d</controlfield>
          </record>
        </collection>
      XML
      aspace = doc.at_xpath('//*[local-name()="record"]')

      apply(aspace, marc_node(controlfields: { '008' => fixed_008(date_entered: '061207') }))

      expect(doc.root.namespace.href).to eq('http://www.loc.gov/MARC21/slim')
      expect(aspace.at_xpath('//*[local-name()="controlfield"]').text).to start_with('260918')
    end

    it 'returns a warning instead of raising when the ArchivesSpace record has no 008' do
      result = nil

      expect do
        result = apply(
          marc_node(datafields: [['245', '1', '0', [['a', 'No 008 from ArchivesSpace']]]]),
          marc_node(controlfields: { '008' => fixed_008(date_entered: '990101') })
        )
      end.not_to raise_error

      expect(result.date_entered_preserved).to be(false)
      expect(result.warnings).to eq([
        'The ArchivesSpace record has no 008 field, so the Alma "Date Entered on File" could not be preserved.'
      ])
      expect(result.to_xml).to include('No 008 from ArchivesSpace')
    end

    it 'returns a warning instead of raising when the Alma record has no 008' do
      result = nil

      expect do
        result = apply(
          marc_node(controlfields: { '008' => fixed_008(date_entered: '260916') }),
          marc_node(datafields: [['590', ' ', ' ', [['a', 'No Alma 008']]]])
        )
      end.not_to raise_error

      expect(result.date_entered_preserved).to be(false)
      expect(result.warnings).to eq([
        'The Alma record has no 008 field, so there is no "Date Entered on File" to preserve.'
      ])
      expect(control_value(result, '008')).to start_with('260916')
    end

    it 'warns rather than raising when Alma has an 008 too short to contain Date Entered on File' do
      result = apply(
        marc_node(controlfields: { '008' => fixed_008(date_entered: '260916') }),
        marc_node(controlfields: { '008' => '12345' })
      )

      expect(result.date_entered_preserved).to be(false)
      expect(result.warnings).to eq([
        'The Alma 008 field is too short to contain a "Date Entered on File".'
      ])
    end

    it 'copies configured preserve tags wholesale from Alma and replaces outgoing instances' do
      result = apply(
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '260916') },
          datafields: [
            ['245', '1', '0', [['a', 'ArchivesSpace title']]],
            ['590', ' ', ' ', [['a', 'ArchivesSpace local note']]],
            ['590', ' ', ' ', [['a', 'Second ArchivesSpace local note']]],
            ['852', ' ', ' ', [['b', 'aspace-location']]]
          ]
        ),
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '990101') },
          datafields: [
            ['590', ' ', ' ', [['a', 'Alma local note']]],
            ['590', ' ', ' ', [['a', 'Second Alma local note']]],
            ['852', ' ', ' ', [['b', 'alma-location']]]
          ]
        ),
        preserved_tags: %w[590 852]
      )

      expect(result.preserved_counts).to eq('590' => 2, '852' => 1)
      expect(datafield_values(result, '590', 'a')).to eq(['Alma local note', 'Second Alma local note'])
      expect(datafield_values(result, '852', 'b')).to eq(['alma-location'])
      expect(result.to_xml).not_to include('ArchivesSpace local note')
      expect(result.to_xml).not_to include('aspace-location')
    end

    it 'removes outgoing instances of preserved tags when Alma has none to copy' do
      result = apply(
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '260916') },
          datafields: [
            ['245', '1', '0', [['a', 'ArchivesSpace title']]],
            ['590', ' ', ' ', [['a', 'ArchivesSpace local note']]]
          ]
        ),
        marc_node(controlfields: { '008' => fixed_008(date_entered: '990101') }),
        preserved_tags: ['590']
      )

      expect(result.preserved_counts).to eq('590' => 0)
      expect(datafield_values(result, '590', 'a')).to eq([])
      expect(field_tags(result)).to eq(%w[008 245])
    end

    it 'places an inserted numeric tag after the last lower-or-equal tag even when outgoing fields are unsorted' do
      result = apply(
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '260916') },
          datafields: [
            ['100', '1', ' ', [['a', 'Creator']]],
            ['700', '1', ' ', [['a', 'Already out of order']]],
            ['245', '1', '0', [['a', 'Title that appears late']]]
          ]
        ),
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '990101') },
          datafields: [
            ['590', ' ', ' ', [['a', 'Alma local note']]]
          ]
        ),
        preserved_tags: ['590']
      )

      expect(field_tags(result)).to eq(%w[008 100 700 245 590])
    end

    it 'places alphabetic local tags after numeric tags and before later alphabetic tags' do
      result = apply(
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '260916') },
          datafields: [
            ['245', '1', '0', [['a', 'Title']]],
            ['999', ' ', ' ', [['a', 'Last numeric local field']]],
            ['ZZZ', ' ', ' ', [['a', 'Later alphabetic local field']]]
          ]
        ),
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '990101') },
          datafields: [
            ['ABC', ' ', ' ', [['a', 'Alphabetic Alma field']]]
          ]
        ),
        preserved_tags: ['ABC']
      )

      expect(field_tags(result)).to eq(%w[008 245 999 ABC ZZZ])
      expect(datafield_values(result, 'ABC', 'a')).to eq(['Alphabetic Alma field'])
    end

    it 'returns a Result with nil XML and a warning when there is no ArchivesSpace record to prepare' do
      result = apply(nil, marc_node(controlfields: { '008' => fixed_008(date_entered: '990101') }), preserved_tags: ['590'])

      expect(result.record).to be_nil
      expect(result.warnings).to eq(['No ArchivesSpace MARC record to prepare.'])
      expect(result.preserved_counts).to eq({})
      expect(result.date_entered_preserved).to be(false)
      expect(result.to_xml).to be_nil
    end

    it 'returns the outgoing record unchanged and unwarned when there is no Alma record to preserve from' do
      result = apply(
        marc_node(
          controlfields: { '008' => fixed_008(date_entered: '260916') },
          datafields: [['245', '1', '0', [['a', 'New Alma record title']]]]
        ),
        nil,
        preserved_tags: ['590']
      )

      expect(result.warnings).to eq([])
      expect(result.preserved_counts).to eq({})
      expect(result.date_entered_preserved).to be(false)
      expect(field_tags(result)).to eq(%w[008 245])
      expect(result.to_xml).to include('New Alma record title')
    end
  end
end
