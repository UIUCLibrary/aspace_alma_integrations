require 'json'
require 'tempfile'
require 'time'

require_relative 'version'

module AlmaIntegrations
  # Writes the audit report to disk without ever holding the whole thing in
  # memory. An audit may cover many thousands of records and each record may
  # carry a full MARC snapshot, so records are spooled to a temporary file as
  # they are produced and copied into the final document at the end.
  #
  # The summary is only complete once every record has been seen, but it is far
  # more useful at the top of the document than the bottom, so the spool is
  # replayed underneath it rather than the document being written in the order
  # the data arrives.
  class ReportWriter
    ENCODING = 'UTF-8'.freeze

    attr_reader :record_count, :error_count

    def initialize(parameters = {})
      @parameters = parameters || {}
      @record_count = 0
      @error_count = 0

      @records = new_spool('alma-audit-records')
      @errors = new_spool('alma-audit-errors')
      @closed = false
    end

    # Each record is written as one line of JSON. Nothing downstream depends on
    # that framing -- it just makes the spool cheap to append to and cheap to
    # replay.
    def add_record(record)
      raise Error, 'Report has already been finished' if @closed

      @records.puts(JSON.generate(record))
      @record_count += 1
      nil
    end

    def add_error(error)
      raise Error, 'Report has already been finished' if @closed

      @errors.puts(JSON.generate(error))
      @error_count += 1
      nil
    end

    # Assembles the final document. +summary+ is anything that responds to
    # #to_h, which in practice is a ReportSummary.
    def write(io, summary)
      @closed = true
      @records.flush
      @errors.flush

      io.set_encoding(ENCODING) if io.respond_to?(:set_encoding)

      io.write("{\n")
      write_pair(io, 'report_version', REPORT_VERSION)
      io.write(",\n")
      write_pair(io, 'plugin_version', VERSION)
      io.write(",\n")
      write_pair(io, 'generated_at', Time.now.utc.iso8601)
      io.write(",\n")
      write_pair(io, 'parameters', @parameters)
      io.write(",\n")
      write_pair(io, 'summary', summary.respond_to?(:to_h) ? summary.to_h : summary)
      io.write(",\n")

      copy_spool(io, @records, 'records')
      io.write(",\n")
      copy_spool(io, @errors, 'errors')

      io.write("\n}\n")
      io.flush if io.respond_to?(:flush)
      io
    end

    # Releases the spool files. Safe to call more than once.
    def close
      @closed = true
      [@records, @errors].each do |spool|
        next if spool.nil?

        begin
          spool.close unless spool.closed?
          spool.unlink
        rescue StandardError
          # A spool we cannot clean up is not worth failing a completed audit
          # over; the operating system will reap it.
          nil
        end
      end
      @records = nil
      @errors = nil
      nil
    end

    private

    def new_spool(name)
      spool = Tempfile.new([name, '.jsonl'])
      spool.binmode
      spool
    end

    def write_pair(io, key, value)
      io.write(JSON.generate(key.to_s))
      io.write(': ')
      io.write(JSON.generate(value))
    end

    # Replays a spool file into the document as a JSON array. Lines are streamed
    # through verbatim -- they are already valid JSON, so there is no reason to
    # parse and re-generate them.
    def copy_spool(io, spool, key)
      io.write(JSON.generate(key.to_s))
      io.write(": [")

      spool.rewind
      first = true
      spool.each_line do |line|
        line = line.strip
        next if line.empty?

        io.write(first ? "\n" : ",\n")
        io.write(line)
        first = false
      end

      io.write(first ? ']' : "\n]")
      nil
    end
  end

  # A line-delimited JSON file. Used for the two internal artefacts that are
  # read back record by record rather than loaded whole: the update plan handed
  # from an audit to a bulk update, and the pre-update MARC snapshot.
  class JsonLinesWriter
    def initialize(prefix)
      @file = Tempfile.new([prefix, '.jsonl'])
      @file.binmode
      @count = 0
    end

    attr_reader :count

    def add(entry)
      @file.puts(JSON.generate(entry))
      @count += 1
      nil
    end

    def file
      @file.flush
      @file.rewind
      @file
    end

    def close
      @file.close unless @file.nil? || @file.closed?
    rescue StandardError
      nil
    end

    # Reads a line-delimited JSON file one entry at a time. A malformed line is
    # yielded as an error rather than aborting the read, so a truncated file
    # still produces everything that was written before the truncation.
    def self.each(path)
      return enum_for(:each, path) unless block_given?

      File.open(path, 'r:UTF-8') do |file|
        file.each_line do |line|
          line = line.strip
          next if line.empty?

          begin
            yield(JSON.parse(line), nil)
          rescue JSON::ParserError => e
            yield(nil, e.message)
          end
        end
      end
    end
  end
end
