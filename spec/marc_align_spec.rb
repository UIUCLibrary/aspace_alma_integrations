require 'spec_helper'

# The side-by-side view is built from MarcDiff#align, and the two records below
# are real ones supplied by the cataloguers this feature is for. They are here
# rather than as synthetic fixtures because the awkward parts of a real
# comparison -- repeated fields in a different order, a leader whose length
# bytes always differ, control fields that are regenerated on export -- are
# exactly the parts a made-up example tends to leave out.
RSpec.describe AlmaIntegrations::MarcDiff do

  # An IHLC resource. Alma holds the record as it was last written; the
  # ArchivesSpace side has since gained a 100, 351, 520, 610 and 700, and
  # carries no 001 or 005 because those are Alma's to assign.
  ALMA_IHLC = <<~XML.freeze
    <record>
      <leader>00512npcaa2200193 u 4500</leader>
      <controlfield tag="001">99955897860805899</controlfield>
      <controlfield tag="005">20260821135134.0</controlfield>
      <controlfield tag="008">260306i19502000xxu                 mul d</controlfield>
      <datafield ind1=" " ind2=" " tag="040"><subfield code="a">iuhs</subfield><subfield code="b">eng</subfield><subfield code="c">iuhs</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="041"><subfield code="a">eng</subfield><subfield code="a">ger</subfield><subfield code="a">ita</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="049"><subfield code="a">iuhs</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="099"><subfield code="a">IHLC.5001</subfield></datafield>
      <datafield ind1="1" ind2="0" tag="245"><subfield code="a">2 Test,</subfield><subfield code="f">1950-2000</subfield><subfield code="g">1975-1980</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="300"><subfield code="a">20.00</subfield><subfield code="f">Cubic Feet</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="300"><subfield code="a">129</subfield><subfield code="f">folders (20,)</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="546"><subfield code="a"> English ,  German ,  Italian .</subfield></datafield>
      <datafield ind1=" " ind2="0" tag="650"><subfield code="a">United States--Civil War, 1861-1865</subfield></datafield>
      <datafield ind1=" " ind2="0" tag="651"><subfield code="a">Alton (Ill.)</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="852"><subfield code="a">iuhs</subfield></datafield>
    </record>
  XML

  OUTGOING_IHLC = <<~XML.freeze
    <record>
      <leader>00000npcaa2200000 u 4500</leader>
      <controlfield tag="008">260306i19502000xxu                 mul d</controlfield>
      <datafield ind1=" " ind2=" " tag="040"><subfield code="a">iuhs</subfield><subfield code="b">eng</subfield><subfield code="c">iuhs</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="041"><subfield code="a">eng</subfield><subfield code="a">ger</subfield><subfield code="a">ita</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="049"><subfield code="a">iuhs</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="099"><subfield code="a">IHLC.5001</subfield></datafield>
      <datafield ind1="0" ind2=" " tag="100"><subfield code="a">Armour, Philip D.,</subfield><subfield code="e">creator.</subfield></datafield>
      <datafield ind1="1" ind2="0" tag="245"><subfield code="a">2 Test,</subfield><subfield code="f">1950-2000</subfield><subfield code="g">1975-1980</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="300"><subfield code="a">20.00</subfield><subfield code="f">Cubic Feet</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="300"><subfield code="a">129</subfield><subfield code="f">folders (20,)</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="351"><subfield code="a">Test arrangement statement.</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="546"><subfield code="a"> English ,  German ,  Italian .</subfield></datafield>
      <datafield ind1="2" ind2="0" tag="610"><subfield code="a">Illinois State University.</subfield></datafield>
      <datafield ind1=" " ind2="0" tag="650"><subfield code="a">United States--Civil War, 1861-1865</subfield></datafield>
      <datafield ind1=" " ind2="0" tag="651"><subfield code="a">Alton (Ill.)</subfield></datafield>
      <datafield ind1="0" ind2=" " tag="700"><subfield code="a">Atwood, John,</subfield><subfield code="e">creator.</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="852"><subfield code="a">iuhs</subfield></datafield>
    </record>
  XML

  # An ALA archives resource. The two 035s sit at the top of the Alma record and
  # at the bottom of the ArchivesSpace one, which is the case a positional
  # comparison gets wrong.
  ALMA_ALA = <<~XML.freeze
    <record>
      <leader>02149npcaa2200361 u 4500</leader>
      <controlfield tag="001">99527377712205899</controlfield>
      <controlfield tag="005">20260820112747.0</controlfield>
      <controlfield tag="008">061207i19512007xxu                 eng d</controlfield>
      <datafield ind1=" " ind2=" " tag="035"><subfield code="a">(ALA-Ar) 27/10/69</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="035"><subfield code="a">(IU)5273777-uiudb-Voyager</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="040"><subfield code="a">IU-Ar</subfield><subfield code="b">eng</subfield><subfield code="c">IU-Ar</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="099"><subfield code="a">ALA.27.10.69</subfield></datafield>
      <datafield ind1="2" ind2=" " tag="110"><subfield code="a">Buildings and Equipment Section (LAMA),</subfield><subfield code="e">creator.</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="500"><subfield code="a">A local note that ArchivesSpace does not know about.</subfield></datafield>
      <datafield ind1=" " ind2="7" tag="650"><subfield code="a">Public Librarians</subfield><subfield code="2">local</subfield></datafield>
      <datafield ind1=" " ind2="7" tag="650"><subfield code="a">Floor Plans, Architectural</subfield><subfield code="2">local</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="852"><subfield code="a">IU-Ar</subfield></datafield>
    </record>
  XML

  OUTGOING_ALA = <<~XML.freeze
    <record>
      <leader>00000npcaa2200000 u 4500</leader>
      <controlfield tag="008">061207i19512007xxu                 eng d</controlfield>
      <datafield ind1=" " ind2=" " tag="040"><subfield code="a">IU-Ar</subfield><subfield code="b">eng</subfield><subfield code="c">IU-Ar</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="099"><subfield code="a">ALA.27.10.69</subfield></datafield>
      <datafield ind1="2" ind2=" " tag="110"><subfield code="a">Buildings and Equipment Section (LAMA),</subfield><subfield code="e">creator.</subfield></datafield>
      <datafield ind1=" " ind2="7" tag="650"><subfield code="a">Public Librarians</subfield><subfield code="2">local</subfield></datafield>
      <datafield ind1=" " ind2="7" tag="650"><subfield code="a">Floor Plans</subfield><subfield code="2">local</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="852"><subfield code="a">IU-Ar</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="035"><subfield code="a">(ALA-Ar) 27/10/69</subfield></datafield>
      <datafield ind1=" " ind2=" " tag="035"><subfield code="a">(IU)5273777-uiudb-Voyager</subfield></datafield>
    </record>
  XML

  let(:diff) { described_class.new(:ignored_tags => %w[001 003 005], :preserved_tags => %w[035]) }

  describe '#align' do
    def rows_for(alignment, tag)
      alignment['rows'].select { |row| row['tag'] == tag }
    end

    def statuses(alignment)
      alignment['rows'].reject { |row| row['status'] == 'unchanged' }
                       .map { |row| [row['tag'], row['status']] }
    end

    it 'reports the same verdict as #diff for the same pair' do
      alignment = diff.align(ALMA_IHLC, OUTGOING_IHLC)
      comparison = diff.diff(ALMA_IHLC, OUTGOING_IHLC)

      aligned_tags = statuses(alignment).map(&:first).uniq.sort
      diff_tags = comparison['fields'].map { |field| field['tag'] }.uniq.sort

      expect(aligned_tags).to eq(diff_tags)
    end

    it 'pairs repeated fields by content, not by position' do
      alignment = diff.align(ALMA_ALA, OUTGOING_ALA)

      # Both 035s are at the top of one record and the bottom of the other.
      expect(rows_for(alignment, '035').map { |row| row['status'] }).to eq(%w[unchanged unchanged])
    end

    it 'does not report the leader as changed when only its length bytes differ' do
      alignment = diff.align(ALMA_ALA, OUTGOING_ALA)

      leader = rows_for(alignment, 'LDR').first
      expect(leader['status']).to eq('unchanged')
    end

    it 'puts a field only Alma has on the Alma side with nothing opposite it' do
      alignment = diff.align(ALMA_ALA, OUTGOING_ALA)

      row = rows_for(alignment, '500').first
      expect(row['status']).to eq('lost')
      expect(row['alma']['display']).to include('A local note')
      expect(row['outgoing']).to be_nil
    end

    it 'puts a field only ArchivesSpace has on the ArchivesSpace side' do
      alignment = diff.align(ALMA_IHLC, OUTGOING_IHLC)

      row = rows_for(alignment, '351').first
      expect(row['status']).to eq('added')
      expect(row['alma']).to be_nil
      expect(row['outgoing']['display']).to include('Test arrangement statement.')
      expect(row['outgoing_parts'].map { |part| part['status'] }).to eq(['added'])
    end

    it 'labels each subfield of an edited field on both sides' do
      alignment = diff.align(ALMA_ALA, OUTGOING_ALA)

      row = rows_for(alignment, '650').find { |candidate| candidate['status'] == 'changed' }

      expect(row['alma_parts']).to include(
        a_hash_including('code' => 'a', 'value' => 'Floor Plans, Architectural',
                         'status' => 'changed', 'counterpart' => 'Floor Plans')
      )
      expect(row['outgoing_parts']).to include(
        a_hash_including('code' => 'a', 'value' => 'Floor Plans',
                         'status' => 'changed', 'counterpart' => 'Floor Plans, Architectural')
      )
      # The $2 is untouched and must not be highlighted.
      expect(row['alma_parts']).to include(a_hash_including('code' => '2', 'status' => 'unchanged'))
    end

    it 'marks the differing character positions of a control field' do
      alma = ALMA_ALA.sub('061207i19512007', '061207i19512008')
      alignment = diff.align(alma, OUTGOING_ALA)

      row = rows_for(alignment, '008').first
      expect(row['status']).to eq('changed')
      expect(row['positions'].first).to include('start' => 14, 'end' => 14)
      expect(row['positions'].first['label']).to eq('Date 2')
    end

    it 'keeps ignored control fields in the view but flags them as ignored' do
      alignment = diff.align(ALMA_IHLC, OUTGOING_IHLC)

      row = rows_for(alignment, '001').first
      expect(row['status']).to eq('lost')
      expect(row['ignored']).to be(true)
    end

    it 'shows Alma-generated 035s without treating them as a loss' do
      alma = ALMA_ALA.sub(
        '<datafield ind1=" " ind2=" " tag="035"><subfield code="a">(ALA-Ar) 27/10/69</subfield></datafield>',
        '<datafield ind1=" " ind2=" " tag="035"><subfield code="a">(ALA-Ar) 27/10/69</subfield></datafield>' \
        '<datafield ind1=" " ind2=" " tag="035"><subfield code="a">(EXLNZ-01CARLI_NETWORK)991234</subfield></datafield>'
      )

      alignment = diff.align(alma, OUTGOING_ALA)
      enrichment = alignment['rows'].select { |row| row['enrichment'] }

      expect(enrichment.length).to eq(1)
      expect(enrichment.first['status']).to eq('ignored')
      expect(enrichment.first['alma']['display']).to include('EXLNZ')

      # The enrichment 035 must not show up as a lost field in the report.
      field = diff.diff(alma, OUTGOING_ALA)['fields'].find { |candidate| candidate['tag'] == '035' }
      expect(field).to be_nil
    end

    it 'renders every field of both records exactly once' do
      alignment = diff.align(ALMA_IHLC, OUTGOING_IHLC)

      alma_rendered = alignment['rows'].count { |row| row['alma'] }
      outgoing_rendered = alignment['rows'].count { |row| row['outgoing'] }

      alma = AlmaIntegrations::MarcRecord.parse(ALMA_IHLC)
      outgoing = AlmaIntegrations::MarcRecord.parse(OUTGOING_IHLC)

      expect(alma_rendered).to eq(alma.fields.length + 1)
      expect(outgoing_rendered).to eq(outgoing.fields.length + 1)
    end

    it 'counts the rows by status' do
      alignment = diff.align(ALMA_IHLC, OUTGOING_IHLC)

      expect(alignment['counts']).to include('lost' => 2, 'added' => 4)
    end

    it 'copes with a record that has no counterpart at all' do
      alignment = diff.align('<record><leader>00000npcaa2200000 u 4500</leader></record>', OUTGOING_IHLC)

      expect(alignment['rows'].map { |row| row['status'] }.uniq).to contain_exactly('added', 'unchanged')
    end
  end
end
