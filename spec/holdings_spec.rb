require 'spec_helper'

RSpec.describe AlmaIntegrations::HoldingRecord do
  describe '.call_number' do
    it 'uses the EAD ID with its dots intact' do
      expect(described_class.call_number(:ead_id => ' UA.39.2.28 ', :identifier => ['IHLC'])).to eq('UA.39.2.28')
    end

    it 'falls back to the identifier parts joined by dots' do
      expect(described_class.call_number(:ead_id => '', :identifier => ['MS', '123', nil, ' '])).to eq('MS.123')
    end

    it 'is nil when there is nothing to use' do
      expect(described_class.call_number(:ead_id => nil, :identifier => [nil])).to be_nil
    end
  end

  describe '.build' do
    let(:xml) do
      described_class.build(:library => 'ARCHIVES', :location => 'uaros', :call_number => 'UA.39.2.28',
                            :date => Time.new(2026, 11, 13))
    end
    let(:doc) { Nokogiri::XML(xml) }

    it 'describes a multipart item holding' do
      expect(doc.at_xpath('/holding/record/leader').text[6]).to eq('v')
    end

    it 'writes an 852 under other scheme with library, location and EAD call number' do
      field = doc.at_xpath("//datafield[@tag='852']")
      expect(field['ind1']).to eq('8')
      subfields = field.xpath('subfield').map { |sf| [sf['code'], sf.text] }
      expect(subfields).to eq([%w[b ARCHIVES], %w[c uaros], %w[h UA.39.2.28]])
    end

    it 'stamps the 008 with the date entered' do
      expect(doc.at_xpath("//controlfield[@tag='008']").text).to start_with('261113')
    end

    it 'omits $h when there is no call number' do
      doc = Nokogiri::XML(described_class.build(:library => 'ARCHIVES', :location => 'uaros', :call_number => nil))
      expect(doc.at_xpath("//subfield[@code='h']")).to be_nil
    end
  end
end

RSpec.describe AlmaIntegrations::HoldingLocations do
  let(:location) { AlmaIntegrations::HoldingLocations::Location }

  describe '.locations_url' do
    it 'swaps the bibs API for the configuration API' do
      url = described_class.locations_url('https://api-na.hosted.exlibrisgroup.com/almaws/v1/bibs/', 'ARCHIVES')
      expect(url).to eq('https://api-na.hosted.exlibrisgroup.com/almaws/v1/conf/libraries/ARCHIVES/locations')
    end

    it 'escapes the library code' do
      expect(described_class.locations_url('https://x/almaws/v1/bibs', 'A B/C')).to end_with('/libraries/A%20B%2FC/locations')
    end
  end

  describe '.from_alma' do
    it 'reads code and name for each location' do
      body = { 'location' => [{ 'code' => 'uaros', 'name' => 'Oak Street Vaults' }, { 'code' => '' }],
               'total_record_count' => 2 }.to_json

      expect(described_class.from_alma('ARCHIVES', body)).to eq([location.new('ARCHIVES', 'uaros', 'Oak Street Vaults')])
    end

    it 'returns nothing for a library with no locations' do
      expect(described_class.from_alma('ARCHIVES', '{"total_record_count":0}')).to eq([])
    end

    it 'raises on a body that is not a location list' do
      expect { described_class.from_alma('ARCHIVES', '<html/>') }.to raise_error(JSON::ParserError)
    end
  end

  describe '.from_config' do
    it 'accepts pairs and an optional display name, translating unnamed codes' do
      entries = [%w[ARCHIVES uaros], ['ARCHIVES', 'uavlt', 'Vault'], ['', 'x']]
      result = described_class.from_config(entries, :translate => ->(code) { code == 'uaros' ? 'Oak Street' : '' })

      expect(result).to eq([location.new('ARCHIVES', 'uaros', 'Oak Street'), location.new('ARCHIVES', 'uavlt', 'Vault')])
    end
  end

  describe '.available' do
    it 'drops locations already holding the BIB, and duplicates' do
      locations = [location.new('ARCHIVES', 'uaros', 'A'), location.new('ARCHIVES', 'uaros', 'A'),
                   location.new('ARCHIVES', 'uavlt', 'B'), location.new('OTHER', 'uavlt', 'C')]

      result = described_class.available(locations, [%w[ARCHIVES uavlt], [nil, 'uaros']])
      expect(result.map(&:to_a)).to eq([%w[OTHER uavlt C]])
    end
  end

  describe 'drop-down values' do
    it 'round-trips library and code' do
      param = location.new('ARCHIVES', 'ua|ros', 'A').to_param
      expect(described_class.parse_param(param)).to eq(%w[ARCHIVES ua|ros])
    end

    it 'rejects anything else' do
      expect(described_class.parse_param('uaros')).to be_nil
      expect(described_class.parse_param('["ARCHIVES",""]')).to be_nil
    end
  end

  describe 'Location#label' do
    it 'shows the name with the code, or the code alone' do
      expect(location.new('L', 'uaros', 'Oak Street').label).to eq('Oak Street (uaros)')
      expect(location.new('L', 'uaros', '').label).to eq('uaros')
    end
  end
end
