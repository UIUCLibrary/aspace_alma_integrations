# frozen_string_literal: true

require 'spec_helper'
require_relative '../../frontend/models/alma_integrator'

# Helper that builds a minimal MARC <record> XML string whose <datafield> and
# <controlfield> elements are supplied by the caller.
def marc_record(*fields_xml)
  <<~XML
    <?xml version="1.0"?>
    <record>
      #{fields_xml.join("\n  ")}
    </record>
  XML
end

# Build a hash matching the shape that AlmaIntegrator passes to
# preserve_alma_marc_fields: { 'content' => <Nokogiri record node> }
def marc_hash(xml_string)
  doc = Nokogiri::XML(xml_string, &:noblanks)
  { 'content' => doc.at_css('record') }
end

RSpec.describe AlmaIntegrator, '#preserve_alma_marc_fields' do
  subject(:integrator) { described_class.new('http://example.com/bibs', 'dummy_key') }

  # Convenience: return the tag order of all control/datafields in the result XML
  def field_tags(xml_string)
    Nokogiri::XML(xml_string).css('controlfield, datafield').map { |f| f['tag'] }
  end

  # ------------------------------------------------------------------
  # 008 Date Entered on File (positions 00–05)
  # ------------------------------------------------------------------
  describe '008 Date Entered on File preservation' do
    context 'when Alma 008/00-05 differs from ASpace 008/00-05' do
      it 'replaces ASpace 008/00-05 with the value from Alma' do
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">950315s2025    xxu                 eng d</controlfield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        result_doc = Nokogiri::XML(result_xml)
        result_008 = result_doc.at_css('controlfield[@tag="008"]').text

        expect(result_008[0, 6]).to eq('950315')
        expect(result_008[6..]).to eq('s2025    xxu                 eng d')
      end
    end

    context 'when Alma 008/00-05 already matches ASpace 008/00-05' do
      it 'leaves the 008 field unchanged' do
        shared_008 = '950315s2025    xxu                 eng d'
        aspace = marc_hash(marc_record(
          "<controlfield tag=\"008\">#{shared_008}</controlfield>"
        ))
        alma = marc_hash(marc_record(
          "<controlfield tag=\"008\">#{shared_008}</controlfield>"
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        result_doc = Nokogiri::XML(result_xml)
        result_008 = result_doc.at_css('controlfield[@tag="008"]').text

        expect(result_008).to eq(shared_008)
      end
    end
  end

  # ------------------------------------------------------------------
  # AppConfig[:alma_marc_fields_to_preserve] – basic field copying
  # ------------------------------------------------------------------
  describe 'preservation of configured additional MARC fields' do
    context 'when no fields are configured' do
      it 'does not copy any additional Alma fields' do
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="245" ind1="1" ind2="0"><subfield code="a">Title</subfield></datafield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)12345678</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        result_doc = Nokogiri::XML(result_xml)

        expect(result_doc.css('datafield[@tag="035"]')).to be_empty
      end
    end

    context 'when a field tag is configured' do
      before { AppConfig[:alma_marc_fields_to_preserve] = ['035'] }

      it 'removes the ASpace version of that field and copies the Alma version' do
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">aspace-generated-035</subfield></datafield>',
          '<datafield tag="245" ind1="1" ind2="0"><subfield code="a">Title</subfield></datafield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)12345678</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        result_doc = Nokogiri::XML(result_xml)
        fields_035 = result_doc.css('datafield[@tag="035"]')

        expect(fields_035.length).to eq(1)
        expect(fields_035.first.at_css('subfield[@code="a"]').text).to eq('(OCoLC)12345678')
      end

      it 'copies multiple Alma instances of a configured field' do
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="245" ind1="1" ind2="0"><subfield code="a">Title</subfield></datafield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)11111111</subfield></datafield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)22222222</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        result_doc = Nokogiri::XML(result_xml)
        fields_035 = result_doc.css('datafield[@tag="035"]')

        expect(fields_035.length).to eq(2)
        expect(fields_035.map { |f| f.at_css('subfield[@code="a"]').text }).to contain_exactly(
          '(OCoLC)11111111',
          '(OCoLC)22222222'
        )
      end
    end
  end

  # ------------------------------------------------------------------
  # PR #6: Correct numerical tag order insertion
  # ------------------------------------------------------------------
  describe 'numerical tag order insertion (PR #6 fix)' do
    before { AppConfig[:alma_marc_fields_to_preserve] = ['035'] }

    context 'when higher-numbered fields exist in the ASpace record' do
      it 'inserts the copied field before the first higher-numbered field' do
        # ASpace has: 008, 040, 100, 245 — no 035
        # Alma has: 008, 035
        # Expected result order after merge: 008, 035, 040, 100, 245
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="040" ind1=" " ind2=" "><subfield code="a">DLC</subfield></datafield>',
          '<datafield tag="100" ind1="1" ind2=" "><subfield code="a">Author</subfield></datafield>',
          '<datafield tag="245" ind1="1" ind2="0"><subfield code="a">Title</subfield></datafield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)12345678</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        tags = field_tags(result_xml)

        # 035 must appear somewhere before 040, 100, and 245
        idx_035 = tags.index('035')
        idx_040 = tags.index('040')
        expect(idx_035).not_to be_nil
        expect(idx_040).not_to be_nil
        expect(idx_035).to be < idx_040
      end

      it 'produces a record whose control/data fields are in ascending numerical tag order' do
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="040" ind1=" " ind2=" "><subfield code="a">DLC</subfield></datafield>',
          '<datafield tag="245" ind1="1" ind2="0"><subfield code="a">Title</subfield></datafield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)12345678</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        tags = field_tags(result_xml)

        expect(tags).to eq(tags.sort_by(&:to_i))
      end
    end

    context 'when no higher-numbered field exists in the ASpace record' do
      it 'appends the copied field at the end of the record' do
        # ASpace has only: 008 — preserving 900 means it should go at the end
        AppConfig[:alma_marc_fields_to_preserve] = ['900']
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="900" ind1=" " ind2=" "><subfield code="a">local note</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        tags = field_tags(result_xml)

        expect(tags.last).to eq('900')
      end
    end

    context 'when preserving multiple fields from different tags' do
      it 'places each field in its correct numerical position' do
        AppConfig[:alma_marc_fields_to_preserve] = ['035', '500']

        # ASpace: 008, 100, 245, 600
        # Alma adds: 035 (between 008 and 100) and 500 (between 245 and 600)
        # Expected order: 008, 035, 100, 245, 500, 600
        aspace = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="100" ind1="1" ind2=" "><subfield code="a">Author</subfield></datafield>',
          '<datafield tag="245" ind1="1" ind2="0"><subfield code="a">Title</subfield></datafield>',
          '<datafield tag="600" ind1="1" ind2="0"><subfield code="a">Subject</subfield></datafield>'
        ))
        alma = marc_hash(marc_record(
          '<controlfield tag="008">260101s2025    xxu                 eng d</controlfield>',
          '<datafield tag="035" ind1=" " ind2=" "><subfield code="a">(OCoLC)12345678</subfield></datafield>',
          '<datafield tag="500" ind1=" " ind2=" "><subfield code="a">General note</subfield></datafield>'
        ))

        result_xml = integrator.preserve_alma_marc_fields(aspace, alma)
        tags = field_tags(result_xml)

        expect(tags).to eq(tags.sort_by(&:to_i))
        expect(tags).to include('035', '500')
      end
    end
  end
end
