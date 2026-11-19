require 'spec_helper'
require 'stringio'
require 'tempfile'

REPORT_WRITER_SPEC_TEMP_ROOT = File.expand_path(__dir__)

RSpec.describe AlmaIntegrations::ReportWriter do
  around do |example|
    previous_tmpdir = ENV['TMPDIR']
    ENV['TMPDIR'] = REPORT_WRITER_SPEC_TEMP_ROOT

    example.run
  ensure
    if previous_tmpdir.nil?
      ENV.delete('TMPDIR')
    else
      ENV['TMPDIR'] = previous_tmpdir
    end
  end

  def with_writer(parameters = {})
    writer = described_class.new(parameters)

    yield writer
  ensure
    writer.close unless writer.nil?
  end

  def report_text(writer, summary = { 'records' => { 'total' => 0 }, 'fields' => [] })
    io = StringIO.new
    writer.write(io, summary)
    io.string
  end

  it 'emits valid JSON with summary before the streamed records array' do
    records = [
      { 'mms_id' => '991', 'status' => 'audited' },
      { 'mms_id' => '992', 'status' => 'skipped' },
      { 'mms_id' => '993', 'status' => 'errored' }
    ]
    summary = { 'records' => { 'total' => 3, 'audited' => 1 }, 'fields' => [] }

    with_writer('ignored_tags' => %w[001 003 005]) do |writer|
      records.each { |record| writer.add_record(record) }
      writer.add_error('mms_id' => '993', 'message' => 'Alma timeout')

      text = report_text(writer, summary)
      parsed = JSON.parse(text)

      expect(parsed['report_version']).to eq(AlmaIntegrations::REPORT_VERSION)
      expect(parsed['plugin_version']).to eq(AlmaIntegrations::VERSION)
      expect(parsed['parameters']).to eq('ignored_tags' => %w[001 003 005])
      expect(parsed['summary']).to eq(summary)
      expect(parsed['records']).to eq(records)
      expect(parsed['errors']).to eq([
        { 'mms_id' => '993', 'message' => 'Alma timeout' }
      ])
      expect(text.index('"summary"')).to be < text.index('"records"')
    end
  end

  it 'tracks record and error counts while spooling' do
    with_writer do |writer|
      expect(writer.record_count).to eq(0)
      expect(writer.error_count).to eq(0)

      writer.add_record('mms_id' => '991')
      writer.add_record('mms_id' => '992')
      writer.add_error('mms_id' => '992', 'message' => 'Failed')

      expect(writer.record_count).to eq(2)
      expect(writer.error_count).to eq(1)
    end
  end

  it 'writes empty arrays when no records or errors were spooled' do
    with_writer do |writer|
      parsed = JSON.parse(report_text(writer))

      expect(parsed['summary']).to eq('records' => { 'total' => 0 }, 'fields' => [])
      expect(parsed['records']).to eq([])
      expect(parsed['errors']).to eq([])
    end
  end

  it 'prevents more records from being added once the final report is written' do
    with_writer do |writer|
      report_text(writer)

      expect { writer.add_record('mms_id' => '991') }.to raise_error(AlmaIntegrations::Error, /already been finished/)
      expect { writer.add_error('mms_id' => '991') }.to raise_error(AlmaIntegrations::Error, /already been finished/)
    end
  end

  it 'round-trips JsonLinesWriter entries in order' do
    entries = [
      { 'mms_id' => '991', 'status' => 'ready' },
      { 'mms_id' => '992', 'status' => 'ready', 'losses' => %w[035 500] }
    ]
    writer = AlmaIntegrations::JsonLinesWriter.new('json-lines-writer-spec')
    path = nil

    begin
      entries.each { |entry| writer.add(entry) }
      path = writer.file.path
      seen = []

      AlmaIntegrations::JsonLinesWriter.each(path) do |entry, error|
        expect(error).to be_nil
        seen << entry
      end

      expect(writer.count).to eq(2)
      expect(seen).to eq(entries)
    ensure
      writer.close
      File.unlink(path) if path && File.exist?(path)
    end
  end

  it 'yields an error for a malformed JSON Lines row without losing readable rows' do
    file = Tempfile.new(['json-lines-malformed-spec', '.jsonl'], REPORT_WRITER_SPEC_TEMP_ROOT)
    path = file.path

    begin
      file.write("#{JSON.generate('mms_id' => '991')}\n")
      file.write('{"mms_id":')
      file.flush
      file.close

      yielded = []

      expect do
        AlmaIntegrations::JsonLinesWriter.each(path) do |entry, error|
          yielded << [entry, error]
        end
      end.not_to raise_error

      expect(yielded.length).to eq(2)
      expect(yielded.first).to eq([{ 'mms_id' => '991' }, nil])
      expect(yielded.last.first).to be_nil
      expect(yielded.last.last).to be_a(String)
      expect(yielded.last.last).not_to be_empty
    ensure
      file.close unless file.closed?
      file.unlink
    end
  end

  # A real audit writes to a Tempfile, not a StringIO. StringIO holds a string
  # and never transcodes, so it will accept ASCII-8BIT bytes that a real file
  # rejects outright -- which is exactly how a UTF-8 bug reached production
  # here. These cases go through a real file on disk, the same way the job
  # runner does, so the encoding behaviour under test is the real one.
  def report_via_file(writer, summary = { 'records' => { 'total' => 0 }, 'fields' => [] })
    file = Tempfile.new(['report-writer-spec', '.json'], REPORT_WRITER_SPEC_TEMP_ROOT)

    begin
      # Mirrors AlmaAuditRunner#finalise.
      file.binmode
      writer.write(file, summary)
      file.flush

      File.read(file.path, :encoding => 'UTF-8')
    ensure
      file.close unless file.closed?
      file.unlink
    end
  end

  it 'writes records containing non-ASCII MARC data to a real file' do
    # Every one of these is a byte above 0x7F, which is what the old code could
    # not convert. The BOM in particular is the "\xEF" reported from the field.
    records = [
      { 'mms_id' => '991', 'title' => 'Sacré bleu' },
      { 'mms_id' => '992', 'title' => '中文編目錄' },
      { 'mms_id' => '993', 'title' => "\uFEFFNaïve café — résumé" }
    ]

    with_writer do |writer|
      records.each { |record| writer.add_record(record) }
      writer.add_error('mms_id' => '994', 'message' => 'Alma timeout on Übersetzung')

      text = nil
      expect { text = report_via_file(writer) }.not_to raise_error

      parsed = JSON.parse(text)
      expect(parsed['records']).to eq(records)
      expect(parsed['errors'].first['message']).to eq('Alma timeout on Übersetzung')
    end
  end

  it 'preserves non-ASCII characters exactly rather than mangling them' do
    marc = '<record><datafield tag="245"><subfield code="a">Boiçano — Études</subfield></datafield></record>'

    with_writer do |writer|
      writer.add_record('mms_id' => '991', 'alma_marc' => marc)

      parsed = JSON.parse(report_via_file(writer))

      expect(parsed['records'].first['alma_marc']).to eq(marc)
    end
  end

  it 'writes non-ASCII data that arrives as binary, as Nokogiri#to_xml can return' do
    # MarcRecord#to_xml delegates to Nokogiri, which may hand back a string
    # tagged ASCII-8BIT even though the bytes are UTF-8.
    marc = '<record><subfield code="a">café</subfield></record>'.dup.force_encoding('ASCII-8BIT')

    with_writer do |writer|
      writer.add_record('mms_id' => '991', 'alma_marc' => marc)

      parsed = JSON.parse(report_via_file(writer))

      expect(parsed['records'].first['alma_marc']).to eq(marc.dup.force_encoding('UTF-8'))
    end
  end
end
