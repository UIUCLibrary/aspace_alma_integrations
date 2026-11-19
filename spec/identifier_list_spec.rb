require 'spec_helper'

RSpec.describe AlmaIntegrations::IdentifierList do
  it 'parses plain lines while ignoring blank lines and comments' do
    list = described_class.parse("991234567\n\n# a cataloguer note\nMS-1234\n")

    expect(list.entries.map { |entry| [entry.raw, entry.value, entry.kind, entry.line, entry.explicit] }).to eq([
      ['991234567', '991234567', :mms, 1, false],
      ['MS-1234', 'MS-1234', :collection, 4, false]
    ])
    expect(list.mms_ids).to eq(%w[991234567])
    expect(list.collection_ids).to eq(%w[MS-1234])
    expect(list.problems).to be_empty
    expect(list.total_lines).to eq(4)
  end

  it 'parses a selected CSV column, skips a header row, and records empty selected cells' do
    csv = <<~CSV
      Name,MMS ID
      Alpha,991234567
      "Beta, Inc.",991234568
      Missing,""
    CSV

    list = described_class.parse(csv, :column => 1)

    expect(list.header).to eq('MMS ID')
    expect(list.entries.map(&:value)).to eq(%w[991234567 991234568])
    expect(list.entries).to all(be_mms)
    expect(list.problems.map(&:to_h)).to eq([
      {
        'raw' => 'Missing,""',
        'line' => 4,
        'reason' => 'no value in the selected column'
      }
    ])
  end

  it 'parses TSV input' do
    tsv = "identifier\ttitle\nMS-1\tCollection One\nMS-2\tCollection Two\n"

    list = described_class.parse(tsv, :column => 0)

    expect(list.header).to eq('identifier')
    expect(list.collection_ids).to eq(%w[MS-1 MS-2])
    expect(list.mms_ids).to eq([])
  end

  it 'handles Windows CRLF endings and a UTF-8 BOM' do
    list = described_class.parse("\uFEFFidentifier\r\nmms:991234567\r\nead:MS-1234\r\n")

    expect(list.header).to eq('identifier')
    expect(list.entries.map { |entry| [entry.value, entry.kind, entry.line, entry.explicit] }).to eq([
      ['991234567', :mms, 2, true],
      ['MS-1234', :collection, 3, true]
    ])
  end

  it 'de-duplicates by normalized kind and value while preserving different kinds' do
    list = described_class.parse("991234567\n991234567\nmms:991234567\nead:991234567\nMS-1\nMS-1\n")

    expect(list.entries.map { |entry| [entry.value, entry.kind] }).to eq([
      ['991234567', :mms],
      ['991234567', :collection],
      ['MS-1', :collection]
    ])
    expect(list.duplicates.map { |entry| [entry.value, entry.kind, entry.line, entry.explicit] }).to eq([
      ['991234567', :mms, 2, false],
      ['991234567', :mms, 3, true],
      ['MS-1', :collection, 6, false]
    ])
    expect(list.to_h).to include(
      'total' => 3,
      'mms_ids' => 1,
      'collection_ids' => 2,
      'duplicates' => 3,
      'problems' => 0
    )
  end

  it 'classifies explicit prefixes with a third return value that records explicit typing' do
    list = described_class.parse('')

    expect(list.send(:classify, 'mms:99123')).to eq([:mms, '99123', true])
    expect(list.send(:classify, 'mms_id:991234567')).to eq([:mms, '991234567', true])
    expect(list.send(:classify, 'ead:MS-1234')).to eq([:collection, 'MS-1234', true])
    expect(list.send(:classify, '991234567')).to eq([:mms, '991234567', false])
    expect(list.send(:classify, 'MS-1234')).to eq([:collection, 'MS-1234', false])
  end

  it 'marks prefixed lines so a form-level MMS override does not clobber explicit collection IDs' do
    list = described_class.parse("ead:MS-1234\n991234567\nLOCAL-2\n")

    list.entries.each do |entry|
      entry.kind = :mms unless entry.explicit
    end

    expect(list.entries.map { |entry| [entry.value, entry.kind, entry.explicit] }).to eq([
      ['MS-1234', :collection, true],
      ['991234567', :mms, false],
      ['LOCAL-2', :mms, false]
    ])
  end

  it 'records too-short CSV rows and missing values after prefixes as problems' do
    list = described_class.parse("name,identifier\nMS-1,ok\nMS-2\n", :column => 1)

    expect(list.entries.map(&:value)).to eq(%w[ok])
    expect(list.problems.map(&:to_h)).to eq([
      {
        'raw' => 'MS-2',
        'line' => 3,
        'reason' => 'line has fewer than 2 columns'
      }
    ])

    prefixed = described_class.parse("mms:   \n")

    expect(prefixed.entries).to be_empty
    expect(prefixed.problems.map(&:to_h)).to eq([
      {
        'raw' => 'mms:',
        'line' => 1,
        'reason' => 'no value after the identifier prefix'
      }
    ])
  end
end
