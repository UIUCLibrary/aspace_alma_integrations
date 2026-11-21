require 'spec_helper'
require 'cgi'

# Regression tests for MarcPreserver#decode_entities against the ArchivesSpace
# MARC exporter it compensates for.
#
# ArchivesSpace stores notes as mixed content, so an ampersand is held as
# `&amp;`. Its MARC serializer strips tags from that text but does not decode
# entities, then escapes the result again when writing XML:
#
#   backend/app/exporters/serializers/marc21.rb (ArchivesSpace v4.1.1)
#     xml.text sf.text.gsub(/<[^>]*>/, ' ')
#
# The plugin decodes one level of references to undo this. ArchivesSpace may
# fix it upstream, most plausibly by decoding after stripping tags, so these
# specs push the same stored notes through both versions of that step and
# require the plugin to send identical text either way. The CI workflow
# separately warns when the upstream line changes.
RSpec.describe 'ArchivesSpace MARC export compensation' do
  let(:upstream_tag_strip) { /<[^>]*>/ }

  # The serializer's subfield step as shipped: strip tags, then let the XML
  # builder escape the text.
  def export_as_shipped(note)
    exported_record(note.gsub(upstream_tag_strip, ' '))
  end

  # The same step if ArchivesSpace decoded entities after stripping tags.
  def export_if_fixed_upstream(note)
    exported_record(CGI.unescapeHTML(note.gsub(upstream_tag_strip, ' ')))
  end

  def exported_record(text)
    doc = Nokogiri::XML::Builder.new do |xml|
      xml.record {
        xml.datafield(:tag => '520', :ind1 => '2', :ind2 => ' ') {
          xml.subfield(:code => 'a') { xml.text text }
        }
      }
    end
    doc.to_xml
  end

  def sent_to_alma(exported_xml)
    result = AlmaIntegrations::MarcPreserver.new.apply(exported_xml, nil)
    result.record.at_xpath("./datafield[@tag='520']/subfield[@code='a']").text
  end

  # Stored note content => the text Alma should receive.
  {
    'Alsace &amp; Vosges -- 17. Prisoners &amp; prison camps' => 'Alsace & Vosges -- 17. Prisoners & prison camps',
    'Trenches, <emph render="italic">abri</emph>, etc.'       => 'Trenches,  abri , etc.',
    'caf&#233; &#x2014; &quot;quoted&quot; &lt;not a tag&gt;' => 'café — "quoted" <not a tag>',
    'Smith & Jones'                                             => 'Smith & Jones',
    'AT&T; R&D; &bogus; &amp'                                   => 'AT&T; R&D; &bogus; &amp',
    'No references at all.'                                     => 'No references at all.'
  }.each do |note, expected|
    it "sends #{expected.inspect} for a note stored as #{note.inspect}, whether or not upstream decodes" do
      expect(sent_to_alma(export_as_shipped(note))).to eq(expected)
      expect(sent_to_alma(export_if_fixed_upstream(note))).to eq(expected)
    end
  end

  it 'confirms the shipped exporter really does double-escape, which is why the decode exists' do
    expect(export_as_shipped('Alsace &amp; Vosges')).to include('Alsace &amp;amp; Vosges')
  end

  # The one case the two diverge on: a note deliberately storing the visible
  # characters "&amp;" (as `&amp;amp;`). After an upstream fix the plugin would
  # decode it a second time. Pinned here so that, when ArchivesSpace changes,
  # this is the expectation that tells you decode_entities should be removed.
  it 'decodes a doubly-stored reference once against the shipped exporter' do
    expect(sent_to_alma(export_as_shipped('write &amp;amp; for &'))).to eq('write &amp; for &')
    expect(sent_to_alma(export_if_fixed_upstream('write &amp;amp; for &'))).to eq('write & for &')
  end
end
