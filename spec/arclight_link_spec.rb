require 'spec_helper'

RSpec.describe AlmaIntegrations::ArclightLink do
  let(:base) { 'https://arclight.archivesspace-stage.library.illinois.edu' }

  def link(overrides = {})
    described_class.new(AlmaIntegrations::Settings.new({ :arclight_base_url => base }.merge(overrides)))
  end

  def record(xml = nil)
    xml ||= <<~XML
      <record>
        <leader>00000npcaa2200000 u 4500</leader>
        <controlfield tag="008">210101i19001999xx eng d</controlfield>
        <datafield tag="099" ind1=" " ind2=" "><subfield code="a">UA.39.2.28</subfield></datafield>
        <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Papers</subfield></datafield>
      </record>
    XML

    Nokogiri::XML(xml, &:noblanks).root
  end

  def field_956(node)
    node.xpath("./datafield[@tag='956']")
  end

  def subfield(field, code)
    field.xpath("./subfield[@code='#{code}']").map(&:text)
  end

  describe '#configured?' do
    it 'is off until a base URL is set' do
      expect(described_class.new(AlmaIntegrations::Settings.new).configured?).to be(false)
    end

    it 'is on once a base URL is set' do
      expect(link.configured?).to be(true)
    end

    it 'refuses a base URL that is not http(s)' do
      expect(link(:arclight_base_url => 'javascript:alert(1)').configured?).to be(false)
      expect(link(:arclight_base_url => 'ftp://example.edu').configured?).to be(false)
      expect(link(:arclight_base_url => 'not a url').configured?).to be(false)
    end

    it 'drops a trailing slash so URLs do not double up' do
      expect(link(:arclight_base_url => "#{base}/").base_url).to eq(base)
    end
  end

  describe '#collection_slug' do
    it 'turns dots into dashes' do
      expect(link.collection_slug(:ead_id => 'UA.39.2.28')).to eq('UA-39-2-28')
    end

    it 'leaves an already-dashed ID alone' do
      expect(link.collection_slug(:ead_id => 'UA-39-2-28')).to eq('UA-39-2-28')
    end

    it 'joins the parts of an identifier array with dots first' do
      expect(link.collection_slug(:identifier => %w[UA 39 2 28])).to eq('UA-39-2-28')
    end

    it 'parses the JSON array ArchivesSpace stores identifiers as' do
      expect(link.collection_slug(:identifier => '["UA","39","2","28"]')).to eq('UA-39-2-28')
    end

    it 'ignores the empty trailing parts of a short identifier' do
      expect(link.collection_slug(:identifier => ['MS', '123', nil, ''])).to eq('MS-123')
    end

    it 'prefers the EAD ID and falls back to the identifier' do
      expect(link.collection_slug(:ead_id => 'eadid', :identifier => %w[UA 39])).to eq('eadid')
      expect(link.collection_slug(:ead_id => '  ', :identifier => %w[UA 39])).to eq('UA-39')
    end

    it 'can be pinned to one source or the other' do
      pinned = link(:arclight_id_source => 'identifier')
      expect(pinned.collection_slug(:ead_id => 'eadid', :identifier => %w[UA 39])).to eq('UA-39')

      pinned = link(:arclight_id_source => 'ead_id')
      expect(pinned.collection_slug(:ead_id => nil, :identifier => %w[UA 39])).to be_nil
    end

    it 'is nil when there is nothing to build a slug from' do
      expect(link.collection_slug).to be_nil
      expect(link.collection_slug(:ead_id => '   ', :identifier => [])).to be_nil
    end
  end

  describe '#url' do
    it 'builds the collection URL' do
      expect(link.url(:ead_id => 'UA.39.2.28')).to eq("#{base}/catalog/UA-39-2-28")
    end

    it 'builds the component URL from a bare ref ID' do
      expect(link.url(:ead_id => 'UA.39.2.28', :ref_id => '80b4613bcd0cd11d67353612dafcfb17'))
        .to eq("#{base}/catalog/UA-39-2-28_aspace_80b4613bcd0cd11d67353612dafcfb17")
    end

    it 'does not double the aspace_ prefix when given the EAD element ID' do
      expect(link.url(:ead_id => 'UA.39.2.28', :ref_id => 'aspace_80b4613bcd0cd11d67353612dafcfb17'))
        .to eq("#{base}/catalog/UA-39-2-28_aspace_80b4613bcd0cd11d67353612dafcfb17")
    end

    it 'escapes a slug that is not URL-safe' do
      expect(link.url(:ead_id => 'MS 1/2?x')).to eq("#{base}/catalog/MS%201%2F2%3Fx")
    end

    it 'is nil when unconfigured or when there is no slug' do
      expect(described_class.new(AlmaIntegrations::Settings.new).url(:ead_id => 'x')).to be_nil
      expect(link.url).to be_nil
    end
  end

  describe '#apply' do
    it 'adds a 956 with the URL and the configured link text' do
      node = record
      href = link.apply(node, :ead_id => 'UA.39.2.28')

      expect(href).to eq("#{base}/catalog/UA-39-2-28")

      fields = field_956(node)
      expect(fields.length).to eq(1)
      expect(subfield(fields.first, 'u')).to eq([href])
      expect(subfield(fields.first, 'y')).to eq(['Finding aid online'])
      expect(fields.first['ind1']).to eq('4')
      expect(fields.first['ind2']).to eq('2')
    end

    it 'lets a caller override the link text' do
      node = record
      link.apply(node, :ead_id => 'UA.39.2.28', :link_text => 'Browse the collection guide')

      expect(subfield(field_956(node).first, 'y')).to eq(['Browse the collection guide'])
    end

    it 'falls back to the configured text when the override is blank' do
      node = record
      link.apply(node, :ead_id => 'UA.39.2.28', :link_text => '   ')

      expect(subfield(field_956(node).first, 'y')).to eq(['Finding aid online'])
    end

    it 'omits $y entirely when no text is configured' do
      node = record
      link(:arclight_link_text => '').apply(node, :ead_id => 'UA.39.2.28')

      expect(subfield(field_956(node).first, 'y')).to be_empty
      expect(subfield(field_956(node).first, 'u')).not_to be_empty
    end

    it 'honours configured indicators' do
      node = record
      link(:arclight_indicators => '40').apply(node, :ead_id => 'UA.39.2.28')

      expect(field_956(node).first['ind1']).to eq('4')
      expect(field_956(node).first['ind2']).to eq('0')
    end

    it 'falls back to the default when the configured indicators are malformed' do
      node = record
      link(:arclight_indicators => 'nonsense').apply(node, :ead_id => 'UA.39.2.28')

      expect(field_956(node).first['ind1']).to eq('4')
      expect(field_956(node).first['ind2']).to eq('2')
    end

    it 'keeps the record in tag order' do
      node = record
      link.apply(node, :ead_id => 'UA.39.2.28')

      tags = node.xpath('./controlfield | ./datafield').map { |f| f['tag'] }
      expect(tags).to eq(%w[008 099 245 956])
    end

    it 'inserts before a higher local tag rather than at the end' do
      node = record(<<~XML)
        <record>
          <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Papers</subfield></datafield>
          <datafield tag="999" ind1=" " ind2=" "><subfield code="a">local</subfield></datafield>
        </record>
      XML

      link.apply(node, :ead_id => 'UA.39.2.28')
      expect(node.xpath('./datafield').map { |f| f['tag'] }).to eq(%w[245 956 999])
    end

    it 'replaces a 956 that already points at the same Arclight' do
      node = record(<<~XML)
        <record>
          <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Papers</subfield></datafield>
          <datafield tag="956" ind1="4" ind2="2">
            <subfield code="u">#{base}/catalog/OLD-SLUG</subfield>
            <subfield code="y">Stale text</subfield>
          </datafield>
        </record>
      XML

      link.apply(node, :ead_id => 'UA.39.2.28')

      fields = field_956(node)
      expect(fields.length).to eq(1)
      expect(subfield(fields.first, 'u')).to eq(["#{base}/catalog/UA-39-2-28"])
    end

    it 'leaves a 956 that points somewhere else alone' do
      node = record(<<~XML)
        <record>
          <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Papers</subfield></datafield>
          <datafield tag="956" ind1="4" ind2="0">
            <subfield code="u">https://elsewhere.example.edu/thing</subfield>
          </datafield>
        </record>
      XML

      link.apply(node, :ead_id => 'UA.39.2.28')

      urls = field_956(node).map { |f| subfield(f, 'u') }.flatten
      expect(urls).to contain_exactly('https://elsewhere.example.edu/thing',
                                      "#{base}/catalog/UA-39-2-28")
    end

    # An Arclight mounted at the root of a host shares that host with whatever
    # else the library runs there, so the base URL alone is not enough to tell
    # our link apart from somebody else's. Only a record page is ours.
    it 'leaves a 956 pointing elsewhere on the same host alone' do
      node = record(<<~XML)
        <record>
          <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Papers</subfield></datafield>
          <datafield tag="956" ind1="4" ind2="0">
            <subfield code="u">#{base}/vufind/Record/9</subfield>
          </datafield>
          <datafield tag="956" ind1="4" ind2="2">
            <subfield code="u">#{base}/catalog/OLD-SLUG</subfield>
          </datafield>
        </record>
      XML

      link.apply(node, :ead_id => 'UA.39.2.28')

      urls = field_956(node).map { |f| subfield(f, 'u') }.flatten
      expect(urls).to contain_exactly("#{base}/vufind/Record/9",
                                      "#{base}/catalog/UA-39-2-28")
    end

    it 'is idempotent' do
      node = record
      link.apply(node, :ead_id => 'UA.39.2.28')
      link.apply(node, :ead_id => 'UA.39.2.28')

      expect(field_956(node).length).to eq(1)
    end

    it 'does nothing when unconfigured, when there is no slug, or with no record' do
      node = record
      expect(described_class.new(AlmaIntegrations::Settings.new).apply(node, :ead_id => 'UA.39.2.28')).to be_nil
      expect(link.apply(node)).to be_nil
      expect(link.apply(nil, :ead_id => 'UA.39.2.28')).to be_nil
      expect(field_956(node)).to be_empty
    end
  end
end
