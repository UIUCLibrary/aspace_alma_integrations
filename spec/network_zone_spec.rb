require 'spec_helper'

RSpec.describe AlmaIntegrations::NetworkZone do
  it 'detects a bib linked to a Network Zone record through an EXLNZ 035' do
    detection = described_class.detect(
      marc_xml(:datafields => [
                 ['035', ' ', ' ', [['a', '(EXLNZ-01CARLI_NETWORK)991234']]]
               ])
    )

    expect(detection).to be_linked
    expect(detection.nz_mms_id).to eq('991234')
    expect(detection.network_code).to eq('01CARLI_NETWORK')
    expect(detection.cz_id).to be_nil
    expect(detection.local_tags).to eq([])
  end

  it 'does not link ordinary local 035 values' do
    detection = described_class.detect(
      marc_xml(:datafields => [
                 ['035', ' ', ' ', [['a', '(OCoLC)123456']]]
               ])
    )

    expect(detection).not_to be_linked
    expect(detection.nz_mms_id).to be_nil
    expect(detection.network_code).to be_nil
    expect(detection.cz_id).to be_nil
  end

  it 'captures a Community Zone identifier without treating it as Network Zone linked' do
    detection = described_class.detect(
      marc_xml(:datafields => [
                 ['035', ' ', ' ', [['a', '(EXLCZ)99567']]]
               ])
    )

    expect(detection).not_to be_linked
    expect(detection.cz_id).to eq('99567')
    expect(detection.to_h).to eq(
      'linked' => false,
      'cz_id' => '99567',
      'local_tags' => []
    )
  end

  it 'uses the first NZ identifier and records unique local tags across multiple fields' do
    detection = described_class.detect(
      marc_xml(:datafields => [
                 ['035', ' ', ' ', [['a', '(EXLNZ-FIRST_NETWORK)991'], ['z', '(EXLNZ-SECOND_NETWORK)992']]],
                 ['590', ' ', ' ', [['a', 'Local note'], ['9', 'LOCAL']]],
                 ['590', ' ', ' ', [['a', 'Another local note'], ['9', 'local']]],
                 ['599', ' ', ' ', [['a', 'Not local'], ['9', 'not-local']]]
               ])
    )

    expect(detection).to be_linked
    expect(detection.nz_mms_id).to eq('991')
    expect(detection.network_code).to eq('FIRST_NETWORK')
    expect(detection.local_tags).to eq(%w[590])
  end

  it 'treats malformed 035 values as not linked and does not raise' do
    detection = nil

    expect do
      detection = described_class.detect(
        marc_xml(:datafields => [
                   ['035', ' ', ' ', [['a', 'EXLNZ-01CARLI_NETWORK)991234'],
                                      ['z', '(EXLNZ-01CARLI_NETWORK991234'],
                                      ['z', '(EXL NZ)991234']]]
                 ])
      )
    end.not_to raise_error

    expect(detection).not_to be_linked
    expect(detection.nz_mms_id).to be_nil
    expect(detection.network_code).to be_nil
    expect(detection.cz_id).to be_nil
  end

  it 'reports local-field linkage even without an NZ 035' do
    detection = described_class.detect(
      marc_xml(:datafields => [
                 ['590', ' ', ' ', [['a', 'Institution-only note'], ['9', ' local ']]]
               ])
    )

    expect(detection).to be_linked
    expect(detection.nz_mms_id).to be_nil
    expect(detection.local_tags).to eq(%w[590])
  end

  it 'serializes the detection in the expected report shape' do
    detection = described_class.detect(
      marc_xml(:datafields => [
                 ['035', ' ', ' ', [['a', '(EXLNZ-01CARLI_NETWORK)991234'], ['z', '(EXLCZ)99567']]],
                 ['590', ' ', ' ', [['a', 'Institution-only note'], ['9', 'LOCAL']]]
               ])
    )

    expect(detection.to_h).to eq(
      'linked' => true,
      'nz_mms_id' => '991234',
      'network_code' => '01CARLI_NETWORK',
      'cz_id' => '99567',
      'local_tags' => %w[590]
    )
  end
end
