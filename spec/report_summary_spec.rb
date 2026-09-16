require 'spec_helper'

RSpec.describe AlmaIntegrations::ReportSummary do
  def diff_between(alma_datafields:, outgoing_datafields:, settings: {}, alma_controlfields: {}, outgoing_controlfields: {})
    AlmaIntegrations::MarcDiff.new(settings).diff(
      marc_xml(:controlfields => alma_controlfields, :datafields => alma_datafields),
      marc_xml(:controlfields => outgoing_controlfields, :datafields => outgoing_datafields)
    )
  end

  def fields_by_tag(summary_hash)
    summary_hash['fields'].each_with_object({}) { |row, out| out[row['tag']] = row }
  end

  it 'counts audited records and per-tag losses, changes, and additions' do
    settings = { :recommend_threshold => 0.5, :preserved_tags => %w[500] }
    summary = described_class.new(settings)
    summary.record_submitted(3)

    summary.add_record(
      diff_between(
        :settings => settings,
        :alma_datafields => [
          ['035', ' ', ' ', [['a', '(OCoLC)111']]],
          ['500', ' ', ' ', [['a', 'Public note'], ['5', 'UIU']]],
          ['245', '1', '0', [['a', 'Collection'], ['b', 'old subtitle']]]
        ],
        :outgoing_datafields => [
          ['500', ' ', ' ', [['a', 'Public note']]],
          ['245', '1', '0', [['a', 'Collection'], ['b', 'new subtitle']]],
          ['650', ' ', '0', [['a', 'Archives']]]
        ]
      )
    )
    summary.add_record(
      diff_between(
        :settings => settings,
        :alma_datafields => [
          ['035', ' ', ' ', [['a', '(OCoLC)222']]]
        ],
        :outgoing_datafields => []
      ),
      :network_zone_linked => true
    )

    result = summary.to_h
    records = result['records']
    fields = fields_by_tag(result)

    expect(records).to include(
      'total' => 3,
      'audited' => 2,
      'errored' => 0,
      'skipped' => 0,
      'network_zone_linked' => 1,
      'with_loss' => 2,
      'with_change' => 1,
      'with_addition' => 1,
      'identical' => 0
    )

    expect(fields['035']).to include(
      'label' => 'System Control Number',
      'records_in_alma' => 2,
      'records_in_outgoing' => 0,
      'records_with_loss' => 2,
      'records_with_full_loss' => 2,
      'records_with_partial_loss' => 0,
      'instances_lost' => 2,
      'subfields_lost' => 0,
      'loss_ratio' => 1.0,
      'ignored' => false,
      'preserved' => false
    )
    expect(fields['500']).to include(
      'records_in_alma' => 1,
      'records_in_outgoing' => 1,
      'records_with_loss' => 1,
      'records_with_full_loss' => 0,
      'records_with_partial_loss' => 1,
      'instances_lost' => 0,
      'subfields_lost' => 1,
      'loss_ratio' => 0.5,
      'preserved' => true
    )
    expect(fields['245']).to include(
      'records_with_change' => 1,
      'records_with_loss' => 0,
      'records_with_addition' => 0,
      'change_ratio' => 0.5
    )
    expect(fields['650']).to include(
      'records_in_alma' => 0,
      'records_in_outgoing' => 1,
      'records_with_addition' => 1,
      'records_with_loss' => 0
    )
  end

  it 'only populates records.total through record_submitted' do
    summary = described_class.new

    summary.add_record(
      diff_between(
        :alma_datafields => [
          ['245', '1', '0', [['a', 'Same title']]]
        ],
        :outgoing_datafields => [
          ['245', '1', '0', [['a', 'Same title']]]
        ]
      )
    )

    expect(summary.to_h['records']).to include('total' => 0, 'audited' => 1, 'identical' => 1)

    summary.record_submitted(2)

    expect(summary.to_h['records']['total']).to eq(2)
  end

  it 'tallies errors and skips by kind and de-duplicates warnings' do
    summary = described_class.new

    summary.add_error(:alma_fetch)
    summary.add_error('alma_fetch')
    summary.add_skipped(:unpublished)
    summary.add_warning('Check the Alma API key before retrying.')
    summary.add_warning('Check the Alma API key before retrying.')

    result = summary.to_h

    expect(result['records']).to include('errored' => 2, 'skipped' => 1)
    expect(result['errors_by_kind']).to eq('alma_fetch' => 2, 'unpublished' => 1)
    expect(result['warnings']).to eq(['Check the Alma API key before retrying.'])
  end

  it 'warns when records linked to the Network Zone are audited' do
    summary = described_class.new

    summary.add_record(
      diff_between(
        :alma_datafields => [],
        :outgoing_datafields => []
      ),
      :network_zone_linked => true
    )

    expect(summary.to_h['warnings'].join).to include('1 of the audited records are linked to a Network Zone record')
  end

  it 'recommends non-preserved, non-ignored tags that lose data at or above the threshold' do
    settings = { :recommend_threshold => 0.5, :preserved_tags => %w[500], :ignored_tags => %w[001] }
    summary = described_class.new(settings)

    2.times { summary.record_submitted }
    summary.add_record(
      diff_between(
        :settings => settings,
        :alma_controlfields => { '001' => 'old-control-number' },
        :outgoing_controlfields => {},
        :alma_datafields => [
          ['035', ' ', ' ', [['a', '(OCoLC)111']]],
          ['500', ' ', ' ', [['a', 'Public note'], ['5', 'UIU']]]
        ],
        :outgoing_datafields => [
          ['500', ' ', ' ', [['a', 'Public note']]]
        ]
      )
    )
    summary.add_record(
      diff_between(
        :settings => settings,
        :alma_datafields => [
          ['035', ' ', ' ', [['a', '(OCoLC)222']]]
        ],
        :outgoing_datafields => []
      )
    )

    expect(summary.to_h['recommended_preserve_tags']).to eq([
      {
        'tag' => '035',
        'label' => 'System Control Number',
        'records_with_loss' => 2,
        'loss_ratio' => 1.0
      }
    ])
  end

  it 'discloses control fields excluded from headline summary counts' do
    settings = { :ignored_tags => %w[001] }
    summary = described_class.new(settings)
    diff = diff_between(:settings => settings,
                        :alma_controlfields => { '001' => 'old-control-number' },
                        :outgoing_controlfields => {},
                        :alma_datafields => [],
                        :outgoing_datafields => [])

    summary.add_record(diff)
    result = summary.to_h
    fields = fields_by_tag(result)

    expect(result['records']).to include('with_loss' => 0, 'identical' => 1)
    expect(fields['001']).to include('ignored' => true, 'records_with_loss' => 1)
    expect(result['excluded_from_summary']).to eq([
      {
        'tag' => '001',
        'label' => 'Control Number',
        'reason' => 'Differs mechanically on every record; see the per-record detail in the JSON report.'
      }
    ])
  end
end
