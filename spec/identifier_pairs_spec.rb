require 'spec_helper'

RSpec.describe AlmaIntegrations::IdentifierPairs do
  # Five real rows from the Alma export the MMS IDs are being loaded from,
  # header included. The two columns that matter are first and fifteenth, with
  # a lot of noise in between -- including a column whose values contain commas
  # and one whose header ends in "(035a)".
  let(:real_csv) do
    <<~CSV
      MMS Id,Electronic location and access,Title (Complete),Author,OCLC Control Number (035a),Location Code,Library Code,Call Number Prefix,Permanent Call Number,Permanent Call Number Type,852 - Holding Local Param 09,Notes,archon instance,archon id,lookup EAD ID
      99313997612205899,http://www.library.illinois.edu/archives/archon/index.php?p=collections/controlcard&id=2407,[Christmas news letter].,University of Illinois (Urbana-Champaign campus). Department of Zoology.,752962266,uax-nc,ARCHIVES,,C. IZz1,Other scheme,$$b ARCHIVES $$c uax-nc $$h C. $$i IZz1 $$t 1 $$x (Marked by year),,UA,2407,UA.15.24.809
      99363582012205899,https://archon.library.illinois.edu/rbml/?p=collections/findingaid&id=28 Access finding aid online,Alvin Doyle Moore fine print collection.,,30861305,rbx-nc,RBML,Q.,Q. Moore 686 A#{"\u2113"}88,Dewey Decimal classification,$$b RBML $$c rbx-nc $$k Q. $$k Moore $$h 686 $$i A#{"\u2113"}88 $$t 1 $$z Box 6 shelved as F,,RBML,28,RBML.02.Moore
      99380621712205899,http://www.library.illinois.edu/rbx/archon/index.php?p=collections/findingaid&id=1490 Finding aid,George Bernard Shaw letters and photographs.,University of Illinois at Urbana-Champaign. Rare Book & Manuscript Library,34296159,rbx-nc,RBML,,Post-1650 MS 0656,Other scheme,$$b RBML $$c rbx-nc $$h Post-1650 MS 0656 $$t 1,,RBML,1490,RBML.01.POST-1650MS0656
      99671113212205899,http://www.library.illinois.edu/archives/archon/index.php?p=collections/controlcard&id=10991&q=34%2F1%2F3 Finding aid,Property Acquisition File 1946-1974,University of Illinois at Urbana-Champaign. LEGAL COUNSEL,,uaros,ARCHIVES,,020.62273 34/1/3,Dewey Decimal classification,$$b ARCHIVES $$c uaros $$h 020.62273 $$i 34/1/3 $$t Copy 1,,UA,10991,UA.34.1.3
      99673033512205899,http://www.library.illinois.edu/archives/archon/index.php?p=collections/controlcard&id=10984,Reference Library Vertical Subject File 1920-2003,University of Illinois at Urbana-Champaign. University Library,,uaos,ARCHIVES,,020.62273 35/3/79,Dewey Decimal classification,$$b ARCHIVES $$c uaos $$h 020.62273 $$i 35/3/79 $$t Copy 1,,UA,10984,UA.35.3.79
    CSV
  end

  describe 'the real Alma export' do
    let(:list) { described_class.parse(real_csv) }

    it 'finds both columns by name in a fifteen column file' do
      expect(list.matched_headers).to be true
      expect(list.mms_column).to eq(0)
      expect(list.collection_column).to eq(14)
    end

    it 'skips the header row' do
      expect(list.header).to start_with('MMS Id,')
      expect(list.rows.length).to eq(5)
    end

    it 'pairs every MMS ID with its EAD ID' do
      expect(list.rows.map { |row| [row.mms_id, row.collection_id] }).to eq(
        [
          ['99313997612205899', 'UA.15.24.809'],
          ['99363582012205899', 'RBML.02.Moore'],
          ['99380621712205899', 'RBML.01.POST-1650MS0656'],
          ['99671113212205899', 'UA.34.1.3'],
          ['99673033512205899', 'UA.35.3.79']
        ]
      )
    end

    it 'is not confused by the commas inside quoted-looking cells or by column 4' do
      # "OCLC Control Number (035a)" holds bare numbers that would pass the MMS
      # pattern if the columns were guessed positionally rather than by name.
      expect(list.rows.map(&:mms_id)).to all(start_with('99'))
      expect(list.problems).to be_empty
    end

    it 'records the line each pair came from, counting the header' do
      expect(list.rows.map(&:line)).to eq([2, 3, 4, 5, 6])
    end
  end

  describe 'column selection' do
    it 'falls back to the first two columns when there is no header' do
      list = described_class.parse("99123456789012345,UA.1.2\n99123456789012346,UA.3.4\n")

      expect(list.header).to be_nil
      expect(list.mms_column).to eq(0)
      expect(list.collection_column).to eq(1)
      expect(list.rows.length).to eq(2)
    end

    it 'accepts explicit column numbers' do
      csv = "ignore,MMS,ignore,EAD\nx,99123456789012345,y,UA.1.2\n"
      list = described_class.parse(csv, :mms_column => 1, :collection_column => 3)

      expect(list.mms_column).to eq(1)
      expect(list.collection_column).to eq(3)
      expect(list.rows.map(&:collection_id)).to eq(['UA.1.2'])
    end

    it 'prefers explicit column numbers over the header names' do
      csv = "MMS Id,lookup EAD ID,other mms,other ead\n1,2,99123456789012345,UA.9.9\n"
      list = described_class.parse(csv, :mms_column => 2, :collection_column => 3)

      expect(list.rows.map { |row| [row.mms_id, row.collection_id] }).to eq([['99123456789012345', 'UA.9.9']])
    end

    it 'handles tab separated files' do
      list = described_class.parse("MMS Id\tlookup EAD ID\n99123456789012345\tUA.1.2\n")

      expect(list.rows.map(&:collection_id)).to eq(['UA.1.2'])
    end

    it 'strips a byte order mark before matching the first header' do
      list = described_class.parse("\uFEFFMMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n")

      expect(list.matched_headers).to be true
      expect(list.mms_column).to eq(0)
    end

    it 'rejects a file with a single column, because a pair needs two' do
      list = described_class.parse("99123456789012345\n99123456789012346\n")

      expect(list.rows).to be_empty
      expect(list.problems.first.reason).to match(/only one column/)
    end
  end

  describe 'bad rows' do
    it 'reports a row with no collection identifier' do
      list = described_class.parse("MMS Id,lookup EAD ID\n99123456789012345,\n")

      expect(list.rows).to be_empty
      expect(list.problems.first.reason).to match(/no collection identifier/)
    end

    it 'reports a row with no MMS ID' do
      list = described_class.parse("MMS Id,lookup EAD ID\n,UA.1.2\n")

      expect(list.rows).to be_empty
      expect(list.problems.first.reason).to match(/no MMS ID/)
    end

    it 'reports a value that is not an MMS ID' do
      list = described_class.parse("MMS Id,lookup EAD ID\n2407,UA.1.2\n")

      expect(list.rows).to be_empty
      expect(list.problems.first.reason).to match(/does not look like an Alma MMS ID/)
    end

    it 'keeps the good rows when one row is bad' do
      csv = "MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\nnonsense,UA.3.4\n99123456789012346,UA.5.6\n"
      list = described_class.parse(csv)

      expect(list.rows.map(&:collection_id)).to eq(['UA.1.2', 'UA.5.6'])
      expect(list.problems.length).to eq(1)
      expect(list.problems.first.line).to eq(3)
    end

    it 'ignores blank lines and comments' do
      csv = "MMS Id,lookup EAD ID\n\n# a note\n99123456789012345,UA.1.2\n"
      list = described_class.parse(csv)

      expect(list.rows.length).to eq(1)
      expect(list.problems).to be_empty
    end

    it 'tolerates the mms: and ead: prefixes the other job forms invite' do
      list = described_class.parse("MMS Id,lookup EAD ID\nmms:99123456789012345,ead:UA.1.2\n")

      expect(list.rows.map { |row| [row.mms_id, row.collection_id] }).to eq([['99123456789012345', 'UA.1.2']])
    end
  end

  describe 'conflicts inside the file' do
    it 'ignores an exactly repeated pair' do
      csv = "MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n99123456789012345,UA.1.2\n"
      list = described_class.parse(csv)

      expect(list.rows.length).to eq(1)
      expect(list.duplicates.length).to eq(1)
      expect(list.problems).to be_empty
    end

    it 'drops both rows when one collection is given two MMS IDs' do
      csv = "MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n99123456789012346,UA.1.2\n"
      list = described_class.parse(csv)

      expect(list.rows).to be_empty
      expect(list.problems.length).to eq(2)
      expect(list.problems.map(&:line)).to eq([2, 3])
      expect(list.problems.first.reason).to match(/different MMS IDs \(lines 2, 3\)/)
    end

    it 'drops both rows when one MMS ID is given to two collections' do
      csv = "MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n99123456789012345,UA.3.4\n"
      list = described_class.parse(csv)

      expect(list.rows).to be_empty
      expect(list.problems.length).to eq(2)
      expect(list.problems.first.reason).to match(/different collections \(lines 2, 3\)/)
    end

    it 'keeps the unaffected rows around a conflict' do
      csv = "MMS Id,lookup EAD ID\n" \
            "99123456789012345,UA.1.2\n" \
            "99123456789012346,UA.3.4\n" \
            "99123456789012347,UA.3.4\n" \
            "99123456789012348,UA.5.6\n"
      list = described_class.parse(csv)

      expect(list.rows.map(&:collection_id)).to eq(['UA.1.2', 'UA.5.6'])
      expect(list.problems.length).to eq(2)
    end
  end

  describe '#merge!' do
    it 'combines two sources and keeps both sets of rows' do
      first = described_class.parse("MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n")
      second = described_class.parse("MMS Id,lookup EAD ID\n99123456789012346,UA.3.4\n")

      first.merge!(second)

      expect(first.rows.map(&:collection_id)).to eq(['UA.1.2', 'UA.3.4'])
      expect(first.problems).to be_empty
    end

    it 'treats a pair repeated across sources as a duplicate, not a conflict' do
      first = described_class.parse("MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n")
      second = described_class.parse("MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n")

      first.merge!(second)

      expect(first.rows.length).to eq(1)
      expect(first.duplicates.length).to eq(1)
      expect(first.problems).to be_empty
    end

    it 'catches a conflict that spans two sources' do
      first = described_class.parse("MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n")
      second = described_class.parse("MMS Id,lookup EAD ID\n99123456789012346,UA.1.2\n")

      first.merge!(second)

      expect(first.rows).to be_empty
      expect(first.problems.length).to eq(2)
      expect(first.problems.first.reason).to match(/different MMS IDs/)
    end

    it 'does not drop unrelated rows that happen to share a line number' do
      first = described_class.parse("MMS Id,lookup EAD ID\n99123456789012345,UA.1.2\n99123456789012346,UA.3.4\n")
      second = described_class.parse("MMS Id,lookup EAD ID\n99123456789012347,UA.5.6\n99123456789012348,UA.3.4\n")

      first.merge!(second)

      # UA.3.4 appears on line 3 of the first source and line 3 of the second
      # with a different MMS ID: only those two rows go.
      expect(first.rows.map(&:collection_id)).to eq(['UA.1.2', 'UA.5.6'])
      expect(first.problems.length).to eq(2)
    end

    it 'carries the problems from both sources forward' do
      first = described_class.parse("MMS Id,lookup EAD ID\nnonsense,UA.1.2\n")
      second = described_class.parse("MMS Id,lookup EAD ID\n99123456789012346,\n")

      first.merge!(second)

      expect(first.problems.length).to eq(2)
    end
  end

  describe '#to_h' do
    it 'summarises the parse for the report' do
      summary = described_class.parse(real_csv).to_h

      expect(summary['total']).to eq(5)
      expect(summary['matched_by_header']).to be true
      expect(summary['mms_column']).to eq(0)
      expect(summary['collection_column']).to eq(14)
    end
  end
end
