require 'spec_helper'

RSpec.describe AlmaIntegrations::Settings do
  def with_app_config(app_config)
    had_app_config = Object.const_defined?(:AppConfig, false)
    previous_app_config = Object.const_get(:AppConfig) if had_app_config

    Object.send(:remove_const, :AppConfig) if had_app_config
    Object.const_set(:AppConfig, app_config)

    yield
  ensure
    Object.send(:remove_const, :AppConfig) if Object.const_defined?(:AppConfig, false)
    Object.const_set(:AppConfig, previous_app_config) if had_app_config
  end

  def without_app_config
    had_app_config = Object.const_defined?(:AppConfig, false)
    previous_app_config = Object.const_get(:AppConfig) if had_app_config

    Object.send(:remove_const, :AppConfig) if had_app_config

    yield
  ensure
    Object.send(:remove_const, :AppConfig) if Object.const_defined?(:AppConfig, false)
    Object.const_set(:AppConfig, previous_app_config) if had_app_config
  end

  def app_config_with(values)
    Object.new.tap do |config|
      config.instance_variable_set(:@values, values)

      def config.has_key?(key)
        @values.key?(key)
      end

      def config.[](key)
        @values.fetch(key)
      end
    end
  end

  describe 'defaults' do
    it 'provides safe, sane defaults for an unconfigured plugin' do
      settings = described_class.new

      expect(settings[:api_url]).to be_nil
      expect(settings[:api_key]).to be_nil
      expect(settings[:requests_per_second]).to eq(19)
      expect(settings[:requests_per_second]).to be < 25
      expect(settings[:daily_quota_floor]).to eq(1000)
      expect(settings[:mms_field]).to eq('string_2')
      expect(settings[:ignored_tags]).to eq(%w[001 003 005])
      expect(settings[:ignore_value_patterns].map(&:source)).to include('\\A\\(EXLNZ-', '\\A\\(EXLCZ')
      expect(settings[:preserved_tags]).to eq([])
      expect(settings[:bulk_fetch_size]).to eq(100)
      expect(settings[:recommend_threshold]).to eq(0.25)
      expect(settings[:store_alma_marc]).to be(true)
      expect(settings[:store_outgoing_marc]).to be(false)
      expect(settings[:include_unpublished]).to be(false)
      expect(settings[:include_nz_linked]).to be(false)
      expect(settings[:stale_version_check]).to be(true)
      expect(settings[:check_aspace_changes]).to be(true)
    end

    it 'ignores nil overrides so a partial configuration cannot erase defaults' do
      settings = described_class.new(:requests_per_second => nil,
                                     'mms_field' => 'user_defined_1',
                                     :preserved_tags => %w[590])

      expect(settings[:requests_per_second]).to eq(19)
      expect(settings.fetch(:mms_field)).to eq('user_defined_1')
      expect(settings.fetch(:missing, 'fallback')).to eq('fallback')
      expect(settings[:preserved_tags]).to eq(%w[590])
    end

    it 'merges new values without mutating the original settings' do
      original = described_class.new(:preserved_tags => %w[590])
      merged = original.merge('preserved_tags' => %w[590 650],
                              :include_unpublished => true)

      expect(original[:preserved_tags]).to eq(%w[590])
      expect(original[:include_unpublished]).to be(false)
      expect(merged[:preserved_tags]).to eq(%w[590 650])
      expect(merged[:include_unpublished]).to be(true)
    end
  end

  describe '.from_app_config' do
    it 'falls back to defaults without raising when AppConfig is undefined' do
      without_app_config do
        settings = nil

        expect { settings = described_class.from_app_config }.not_to raise_error
        expect(settings[:requests_per_second]).to eq(19)
        expect(settings[:api_url]).to be_nil
      end
    end

    it 'reads an AppConfig-like object and stringifies tag and field values' do
      config = app_config_with(
        :alma_api_url => 'https://api-na.hosted.exlibrisgroup.com/almaws/v1',
        :alma_apikey => 'secret-api-key',
        :alma_marc_fields_to_preserve => [590, '650'],
        :alma_mms_id_field => :string_3,
        :alma_requests_per_second => 7,
        :alma_daily_quota_floor => 250,
        :alma_max_retries => 9,
        :alma_open_timeout => 3,
        :alma_read_timeout => 45,
        :alma_bulk_fetch_size => 25,
        :alma_audit_recommend_threshold => 0.5,
        :alma_include_unpublished => true,
        :alma_audit_store_alma_marc => false,
        :alma_audit_report_retention_days => 30,
        :alma_audit_ignored_tags => ['001', 9]
      )

      with_app_config(config) do
        settings = described_class.from_app_config(:store_outgoing_marc => true)

        expect(settings[:api_url]).to eq('https://api-na.hosted.exlibrisgroup.com/almaws/v1')
        expect(settings[:api_key]).to eq('secret-api-key')
        expect(settings[:preserved_tags]).to eq(%w[590 650])
        expect(settings[:mms_field]).to eq('string_3')
        expect(settings[:requests_per_second]).to eq(7)
        expect(settings[:daily_quota_floor]).to eq(250)
        expect(settings[:max_retries]).to eq(9)
        expect(settings[:open_timeout]).to eq(3)
        expect(settings[:read_timeout]).to eq(45)
        expect(settings[:bulk_fetch_size]).to eq(25)
        expect(settings[:recommend_threshold]).to eq(0.5)
        expect(settings[:include_unpublished]).to be(true)
        expect(settings[:store_alma_marc]).to be(false)
        expect(settings[:store_outgoing_marc]).to be(true)
        expect(settings[:report_retention_days]).to eq(30)
        expect(settings[:ignored_tags]).to eq(%w[001 9])
      end
    end

    it 'treats missing AppConfig keys as absent rather than exceptional' do
      config = app_config_with(:alma_requests_per_second => 6)

      with_app_config(config) do
        settings = nil

        expect { settings = described_class.from_app_config }.not_to raise_error
        expect(settings[:requests_per_second]).to eq(6)
        expect(settings[:daily_quota_floor]).to eq(1000)
        expect(settings[:api_key]).to be_nil
      end
    end

    it 'defensively ignores AppConfig implementations that raise' do
      broken_config = Object.new

      def broken_config.has_key?(_key)
        raise 'AppConfig backend is unavailable'
      end

      def broken_config.[](_key)
        raise 'should never be reached'
      end

      with_app_config(broken_config) do
        settings = nil

        expect { settings = described_class.from_app_config }.not_to raise_error
        expect(settings.to_h).to include(described_class::DEFAULTS)
      end
    end
  end

  describe '#diff_parameters' do
    it 'exposes reportable comparison parameters but never leaks the Alma API key' do
      secret = 'top-secret-alma-api-key'
      settings = described_class.new(:api_key => secret,
                                     :ignored_tags => %w[001 005],
                                     :preserved_tags => %w[590],
                                     :include_unpublished => true,
                                     :store_outgoing_marc => true)

      params = settings.diff_parameters

      expect(params.keys).to contain_exactly('ignored_tags',
                                             'preserved_tags',
                                             'normalize_whitespace',
                                             'normalize_punctuation',
                                             'normalize_case',
                                             'include_unpublished',
                                             'store_alma_marc',
                                             'store_outgoing_marc',
                                             'mms_field')
      expect(params).not_to have_key('api_key')
      expect(params).not_to have_key(:api_key)
      expect(JSON.generate(params)).not_to include(secret)
      expect(params['ignored_tags']).to eq(%w[001 005])
      expect(params['preserved_tags']).to eq(%w[590])
      expect(params['include_unpublished']).to be(true)
      expect(params['store_outgoing_marc']).to be(true)
    end
  end
end
