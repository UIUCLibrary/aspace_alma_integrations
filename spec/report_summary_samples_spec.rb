require 'spec_helper'

RSpec.describe AlmaIntegrations::ReportSummary do

  def diff_for(tag, kind)
    field = {
      'tag' => tag,
      'label' => 'Test Field',
      'ignored' => false,
      'preserved' => false,
      'alma_count' => 1,
      'outgoing_count' => 1,
      'unchanged_count' => 0,
      'full_loss' => false,
      'has_loss' => kind == 'loss',
      'has_change' => kind == 'change',
      'has_addition' => kind == 'addition',
      'instances_lost' => 0,
      'subfields_lost' => 0,
      'lost' => [],
      'added' => [],
      'modified' => []
    }

    {
      'has_loss' => kind == 'loss',
      'has_change' => kind == 'change',
      'has_addition' => kind == 'addition',
      'fields' => [field],
      'warnings' => []
    }
  end

  def record(index)
    {
      'mms_id' => "9911111111111#{index}",
      'title' => "Record #{index}",
      'resource_uri' => "/repositories/2/resources/#{index}"
    }
  end

  let(:summary) { described_class.new({}) }

  it 'records which records were affected, per field and per kind' do
    summary.add_record(diff_for('035', 'loss'), :record => record(1))
    summary.add_record(diff_for('035', 'loss'), :record => record(2))
    summary.add_record(diff_for('035', 'change'), :record => record(3))

    result = summary.to_h
    field = result['fields'].find { |candidate| candidate['tag'] == '035' }

    expect(field['samples']['loss']).to eq([0, 1])
    expect(field['samples']['change']).to eq([2])
    expect(result['sampled_records'].map { |entry| entry['title'] })
      .to eq(['Record 1', 'Record 2', 'Record 3'])
  end

  it 'refers to one record once however many fields it appears under' do
    diff = diff_for('035', 'loss')
    diff['fields'] << diff_for('245', 'loss')['fields'].first.merge('tag' => '245')
    summary.add_record(diff, :record => record(1))

    result = summary.to_h

    expect(result['sampled_records'].length).to eq(1)
    expect(result['fields'].find { |f| f['tag'] == '035' }['samples']['loss']).to eq([0])
    expect(result['fields'].find { |f| f['tag'] == '245' }['samples']['loss']).to eq([0])
  end

  it 'counts every record even once it has stopped sampling them' do
    total = described_class::SAMPLE_LIMIT + 25
    total.times { |index| summary.add_record(diff_for('035', 'loss'), :record => record(index)) }

    result = summary.to_h
    field = result['fields'].find { |candidate| candidate['tag'] == '035' }

    expect(field['records_with_loss']).to eq(total)
    expect(field['samples']['loss'].length).to eq(described_class::SAMPLE_LIMIT)
    expect(result['samples_truncated']).to be(true)
    expect(result['sample_limit']).to eq(described_class::SAMPLE_LIMIT)
  end

  it 'caps the pool of sampled records across all fields' do
    total = described_class::SAMPLE_RECORD_LIMIT + 10
    total.times do |index|
      summary.add_record(diff_for("6#{format('%02d', index % 100)}", 'loss'), :record => record(index))
    end

    result = summary.to_h

    expect(result['sampled_records'].length).to eq(described_class::SAMPLE_RECORD_LIMIT)
    expect(result['samples_truncated']).to be(true)
  end

  it 'does not claim truncation when everything fitted' do
    summary.add_record(diff_for('035', 'loss'), :record => record(1))

    expect(summary.to_h['samples_truncated']).to be(false)
  end

  it 'carries on when the caller has no identity for a record' do
    summary.add_record(diff_for('035', 'loss'), :record => nil)

    result = summary.to_h
    field = result['fields'].find { |candidate| candidate['tag'] == '035' }

    expect(field['records_with_loss']).to eq(1)
    expect(field['samples']['loss']).to be_empty
    expect(result['sampled_records']).to be_empty
  end

  it 'every sample index points at a record in the pool' do
    30.times { |index| summary.add_record(diff_for('035', 'loss'), :record => record(index)) }

    result = summary.to_h
    pool = result['sampled_records']

    result['fields'].each do |field|
      field['samples'].each_value do |indexes|
        indexes.each { |index| expect(pool[index]).not_to be_nil }
      end
    end
  end
end
