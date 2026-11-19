require 'spec_helper'

RSpec.describe AlmaIntegrations::MarcNormalizer do
  describe '#call' do
    it 'collapses repeated whitespace and strips surrounding whitespace by default' do
      normalizer = described_class.new

      expect(normalizer.call("  A\t title\n with   spacing  ")).to eq('A title with spacing')
    end

    it 'removes trailing ISBD punctuation without touching meaningful internal punctuation' do
      normalizer = described_class.new

      expect(normalizer.call('Title proper :')).to eq('Title proper')
      expect(normalizer.call('Title proper /')).to eq('Title proper')
      expect(normalizer.call('Series statement ;')).to eq('Series statement')
      expect(normalizer.call('A title: a subtitle.')).to eq('A title: a subtitle')
    end

    it 'does not normalize punctuation-only content out of existence' do
      normalizer = described_class.new

      expect(normalizer.call(' ... ')).to eq('...')
      expect(normalizer.call(' / ')).to eq('/')
    end

    it 'keeps case differences by default because case normalization is opt-in' do
      normalizer = described_class.new

      expect(normalizer.call('Mixed Case Title')).to eq('Mixed Case Title')
    end

    it 'folds case when casing normalization is enabled' do
      normalizer = described_class.new(casing: true)

      expect(normalizer.call('Mixed Case Title :')).to eq('mixed case title')
    end

    it 'allows whitespace and punctuation normalization to be disabled independently' do
      expect(described_class.new(whitespace: false, punctuation: false).call("  Title   :  ")).to eq("  Title   :  ")
      expect(described_class.new(whitespace: true, punctuation: false).call("  Title   :  ")).to eq('Title :')
      expect(described_class.new(whitespace: false, punctuation: true).call("  Title   :  ")).to eq('  Title')
    end

    it 'exposes value as an alias for call' do
      normalizer = described_class.new

      expect(normalizer.value('Title /')).to eq(normalizer.call('Title /'))
    end
  end
end
