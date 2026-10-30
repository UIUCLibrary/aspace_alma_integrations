require 'spec_helper'

RSpec.describe AlmaIntegrations::MarcDiff do
  def diff(alma_source, outgoing_source, settings = nil)
    described_class.new(settings).diff(alma_source, outgoing_source)
  end

  def entry_for(result, tag)
    result['fields'].find { |entry| entry['tag'] == tag.to_s }
  end

  def field_tags(result)
    result['fields'].map { |entry| entry['tag'] }
  end

  def fixed_008(date_entered: '230101', date1: '1999', date2: '    ', place: 'ilu', material: '                 ', language: 'eng', modified: ' ', source: ' ')
    "#{date_entered}s#{date1}#{date2}#{place}#{material}#{language}#{modified}#{source}"
  end

  describe '#diff' do
    it 'reports a full loss when Alma has a 590 the outgoing record drops' do
      result = diff(
        marc_xml(datafields: [['590', ' ', ' ', [['a', 'Alma-only local note']]]]),
        marc_xml(datafields: [['245', '1', '0', [['a', 'Outgoing title']]]])
      )

      entry = entry_for(result, '590')
      expect(entry).to include(
        'tag' => '590',
        'label' => 'Local Note',
        'alma_count' => 1,
        'outgoing_count' => 0,
        'unchanged_count' => 0,
        'full_loss' => true,
        'has_loss' => true,
        'has_change' => false,
        'has_addition' => false,
        'instances_lost' => 1
      )
      expect(entry['lost'].first['subfields']).to eq([{ 'code' => 'a', 'value' => 'Alma-only local note' }])
      expect(result['has_loss']).to be(true)
    end

    it 'reports a partial loss when only some repeated Alma 650s survive' do
      result = diff(
        marc_xml(datafields: [
          ['650', ' ', '7', [['a', 'Archives'], ['2', 'local']]],
          ['650', ' ', '7', [['a', 'Manuscripts'], ['2', 'local']]]
        ]),
        marc_xml(datafields: [
          ['650', ' ', '7', [['a', 'Manuscripts'], ['2', 'local']]]
        ])
      )

      entry = entry_for(result, '650')
      expect(entry).to include(
        'full_loss' => false,
        'has_loss' => true,
        'alma_count' => 2,
        'outgoing_count' => 1,
        'unchanged_count' => 1,
        'instances_lost' => 1
      )
      expect(entry['lost'].first['subfields']).to include('code' => 'a', 'value' => 'Archives')
    end

    it 'reports a change when a surviving field keeps its identity but edits a subfield value' do
      result = diff(
        marc_xml(datafields: [
          ['245', '1', '0', [['a', 'Shared title'], ['b', 'old subtitle']]]
        ]),
        marc_xml(datafields: [
          ['245', '1', '0', [['a', 'Shared title'], ['b', 'new subtitle']]]
        ])
      )

      entry = entry_for(result, '245')
      subfields = entry['modified'].first['subfields']
      expect(entry).to include(
        'has_loss' => false,
        'has_change' => true,
        'has_addition' => false,
        'full_loss' => false
      )
      expect(subfields['changed']).to eq([
        { 'code' => 'b', 'alma' => 'old subtitle', 'outgoing' => 'new subtitle' }
      ])
      expect(subfields['lost']).to eq([])
      expect(subfields['added']).to eq([])
    end

    it 'reports an addition when the outgoing record introduces a new 500' do
      result = diff(
        marc_xml(datafields: [['245', '1', '0', [['a', 'Existing title']]]]),
        marc_xml(datafields: [
          ['245', '1', '0', [['a', 'Existing title']]],
          ['500', ' ', ' ', [['a', 'New ArchivesSpace note']]]
        ])
      )

      entry = entry_for(result, '500')
      expect(entry).to include(
        'alma_count' => 0,
        'outgoing_count' => 1,
        'full_loss' => false,
        'has_loss' => false,
        'has_change' => false,
        'has_addition' => true
      )
      expect(entry['added'].first['subfields']).to eq([{ 'code' => 'a', 'value' => 'New ArchivesSpace note' }])
      expect(result['has_addition']).to be(true)
    end

    it 'omits identical tags entirely so unchanged catalogue data is not reported' do
      result = diff(
        marc_xml(datafields: [['245', '1', '0', [['a', 'Same title']]]]),
        marc_xml(datafields: [['245', '1', '0', [['a', 'Same title']]]])
      )

      expect(entry_for(result, '245')).to be_nil
      expect(field_tags(result)).not_to include('245')
      expect(result['fields']).to eq([])
      expect(result['has_loss']).to be(false)
      expect(result['has_change']).to be(false)
      expect(result['has_addition']).to be(false)
    end

    it 'compares repeated data fields as multisets so reordered 650s do not create false losses' do
      alma = marc_xml(datafields: [
        ['650', ' ', '7', [['a', 'Archives'], ['2', 'local']]],
        ['650', ' ', '7', [['a', 'Manuscripts'], ['2', 'local']]],
        ['650', ' ', '7', [['a', 'Universities'], ['2', 'local']]]
      ])
      outgoing = marc_xml(datafields: [
        ['650', ' ', '7', [['a', 'Universities'], ['2', 'local']]],
        ['650', ' ', '7', [['a', 'Archives'], ['2', 'local']]],
        ['650', ' ', '7', [['a', 'Manuscripts'], ['2', 'local']]]
      ])

      result = diff(alma, outgoing)

      expect(entry_for(result, '650')).to be_nil
      expect(result['fields']).to eq([])
      expect(result['has_loss']).to be(false)
    end

    context 'when Alma GET enrichment adds Network Zone or Community Zone 035s' do
      it 'ignores pure enrichment 035s instead of reporting phantom losses' do
        result = diff(
          marc_xml(datafields: [
            ['035', ' ', ' ', [['a', '(EXLNZ-01CARLI_NETWORK)999']]],
            ['035', ' ', ' ', [['a', '(EXLCZ)99123']]]
          ]),
          marc_xml
        )

        expect(result['enrichment_fields_ignored']).to eq(2)
        expect(entry_for(result, '035')).to be_nil
        expect(result['alma_tag_counts']).not_to have_key('035')
        expect(result['has_loss']).to be(false)
      end

      it 'ignores enrichment 035s while leaving real 035s available for comparison' do
        result = diff(
          marc_xml(datafields: [
            ['035', ' ', ' ', [['a', '(OCoLC)12345']]],
            ['035', ' ', ' ', [['a', '(EXLNZ-01CARLI_NETWORK)999']]]
          ]),
          marc_xml(datafields: [
            ['035', ' ', ' ', [['a', '(OCoLC)12345']]]
          ])
        )

        expect(result['enrichment_fields_ignored']).to eq(1)
        expect(entry_for(result, '035')).to be_nil
        expect(result['alma_tag_counts']['035']).to eq(1)
        expect(result['outgoing_tag_counts']['035']).to eq(1)
        expect(result['has_loss']).to be(false)
      end

      it 'still reports loss of a real 035 when an enrichment 035 is also present' do
        result = diff(
          marc_xml(datafields: [
            ['035', ' ', ' ', [['a', '(OCoLC)12345']]],
            ['035', ' ', ' ', [['a', '(EXLCZ)99123']]]
          ]),
          marc_xml
        )

        entry = entry_for(result, '035')
        expect(result['enrichment_fields_ignored']).to eq(1)
        expect(entry).to include(
          'full_loss' => true,
          'has_loss' => true,
          'instances_lost' => 1
        )
        expect(entry['lost'].first['subfields']).to eq([{ 'code' => 'a', 'value' => '(OCoLC)12345' }])
      end
    end

    it 'normalizes trailing ISBD punctuation and whitespace so harmless formatting does not register as loss' do
      result = diff(
        marc_xml(datafields: [
          ['245', '1', '0', [['a', "  Shared   title :  "], ['b', 'subtitle /']]]
        ]),
        marc_xml(datafields: [
          ['245', '1', '0', [['a', 'Shared title'], ['b', 'subtitle']]]
        ])
      )

      expect(entry_for(result, '245')).to be_nil
      expect(result['fields']).to eq([])
    end

    it 'can normalize case-only differences when case normalization is enabled' do
      result = diff(
        marc_xml(datafields: [['245', '1', '0', [['a', 'Mixed Case Title']]]]),
        marc_xml(datafields: [['245', '1', '0', [['a', 'mixed case title']]]]),
        normalize_case: true
      )

      expect(entry_for(result, '245')).to be_nil
      expect(result['fields']).to eq([])
    end

    it 'reports leader data-position changes while ignoring mechanical leader bytes' do
      alma_leader = '00000nam a2200000 i 4500'
      outgoing_leader = alma_leader.dup
      outgoing_leader[0, 5] = '99999'
      outgoing_leader[5] = 'c'
      outgoing_leader[17] = 'n'
      outgoing_leader[20, 4] = '9999'

      result = diff(
        marc_xml(leader: alma_leader),
        marc_xml(leader: outgoing_leader)
      )

      positions = entry_for(result, 'LDR')['modified'].first['positions']
      expect(positions.map { |run| run['start'] }).to eq([5, 17])
      expect(positions.map { |run| run['label'] }).to eq(['Record status', 'Encoding level'])
      expect(positions).to all(include('kind' => 'change'))
    end

    it 'keeps ignored 001, 003, and 005 control-field details out of headline loss/change flags' do
      result = diff(
        marc_xml(controlfields: {
          '001' => 'alma-001',
          '003' => 'ICU',
          '005' => '20230101000000.0'
        }),
        marc_xml(controlfields: {
          '001' => 'aspace-001',
          '003' => 'AS',
          '005' => '20240101000000.0'
        })
      )

      expect(field_tags(result)).to eq(%w[001 003 005])
      expect(result['fields']).to all(include('ignored' => true))
      expect(result['fields']).to all(include('has_change' => true))
      expect(result['has_change']).to be(false)
      expect(result['has_loss']).to be(false)
      expect(result['has_addition']).to be(false)
    end

    it 'reports positional 008 detail with cataloguing labels and loss/change kinds' do
      result = diff(
        marc_xml(controlfields: {
          '008' => fixed_008(date_entered: '230101', date1: '1999', place: 'ilu', language: 'eng')
        }),
        marc_xml(controlfields: {
          '008' => fixed_008(date_entered: '240101', date1: '2000', place: '   ', language: 'fre')
        })
      )

      positions = entry_for(result, '008')['modified'].first['positions']
      expect(positions).to include(
        include('start' => 1, 'end' => 1, 'kind' => 'change', 'label' => 'Date entered on file'),
        include('start' => 7, 'end' => 10, 'kind' => 'change', 'label' => 'Date 1'),
        include('start' => 15, 'end' => 17, 'kind' => 'loss', 'label' => 'Place of publication'),
        include('start' => 35, 'end' => 37, 'kind' => 'change', 'label' => 'Language')
      )
      expect(entry_for(result, '008')).to include('has_loss' => true, 'has_change' => true)
    end

    it 'reports indicator-only differences without inventing subfield loss' do
      result = diff(
        marc_xml(datafields: [['650', ' ', '7', [['a', 'Archives'], ['2', 'local']]]]),
        marc_xml(datafields: [['650', '1', '7', [['a', 'Archives'], ['2', 'local']]]])
      )

      subfields = entry_for(result, '650')['modified'].first['subfields']
      expect(subfields).to include(
        'indicators_changed' => true,
        'alma_indicators' => ' 7',
        'outgoing_indicators' => '17'
      )
      expect(subfields['lost']).to eq([])
      expect(subfields['added']).to eq([])
      expect(subfields['changed']).to eq([])
      expect(entry_for(result, '650')).to include('has_change' => true, 'has_loss' => false)
    end

    it 'shows subfield-level loss, change, and addition when similar field instances are paired' do
      result = diff(
        marc_xml(datafields: [
          ['245', '1', '0', [['a', 'Shared title'], ['b', 'Alma subtitle'], ['c', 'Alma statement']]]
        ]),
        marc_xml(datafields: [
          ['245', '1', '0', [['a', 'Shared title'], ['b', 'Outgoing subtitle'], ['d', 'Outgoing addition']]]
        ])
      )

      subfields = entry_for(result, '245')['modified'].first['subfields']
      expect(subfields['changed']).to eq([
        { 'code' => 'b', 'alma' => 'Alma subtitle', 'outgoing' => 'Outgoing subtitle' }
      ])
      expect(subfields['lost']).to eq([{ 'code' => 'c', 'value' => 'Alma statement' }])
      expect(subfields['added']).to eq([{ 'code' => 'd', 'value' => 'Outgoing addition' }])
      expect(entry_for(result, '245')).to include(
        'has_loss' => true,
        'has_change' => true,
        'has_addition' => true,
        'subfields_lost' => 1
      )
    end

    it 'treats dissimilar instances of the same tag as a loss plus an addition, not a matched change' do
      result = diff(
        marc_xml(datafields: [['500', ' ', ' ', [['a', 'Alma-only note']]]]),
        marc_xml(datafields: [['500', ' ', ' ', [['a', 'Completely different outgoing note']]]])
      )

      entry = entry_for(result, '500')
      expect(entry['modified']).to eq([])
      expect(entry['lost'].first['subfields']).to eq([{ 'code' => 'a', 'value' => 'Alma-only note' }])
      expect(entry['added'].first['subfields']).to eq([{ 'code' => 'a', 'value' => 'Completely different outgoing note' }])
      expect(entry).to include(
        'has_loss' => true,
        'has_change' => false,
        'has_addition' => true,
        'full_loss' => false
      )
    end

    it 'handles absent records on both sides without raising or reporting loss' do
      expect { diff(nil, nil) }.not_to raise_error

      result = diff(nil, nil)
      expect(result['fields']).to eq([])
      expect(result['alma_tag_counts']).to eq({})
      expect(result['outgoing_tag_counts']).to eq({})
      expect(result['enrichment_fields_ignored']).to eq(0)
      expect(result['has_loss']).to be(false)
      expect(result['has_change']).to be(false)
      expect(result['has_addition']).to be(false)
    end

    it 'handles an absent record on either side as ordinary additions or losses' do
      outgoing_only = diff(nil, marc_xml(datafields: [['245', '1', '0', [['a', 'New title']]]]))
      alma_only = diff(marc_xml(datafields: [['590', ' ', ' ', [['a', 'Existing local note']]]]), nil)

      expect(entry_for(outgoing_only, '245')).to include('has_addition' => true, 'has_loss' => false)
      expect(outgoing_only['has_addition']).to be(true)

      expect(entry_for(alma_only, '590')).to include('full_loss' => true, 'has_loss' => true)
      expect(alma_only['has_loss']).to be(true)
    end
  end
end
