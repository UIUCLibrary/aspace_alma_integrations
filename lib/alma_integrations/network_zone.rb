require_relative 'marc_record'

module AlmaIntegrations
  # Detects whether an Alma bib is linked to a Network Zone record.
  #
  # This matters for the audit because a bib PUT does not behave the same way for
  # an NZ-linked Institution Zone record: Alma replaces only the local fields
  # (those flagged with $9 LOCAL) and leaves the shared, network-managed fields
  # alone. A plain "everything in Alma that is not in the outgoing record is a
  # loss" reading of the diff overstates what would actually happen to those
  # records, so they are flagged in the report and excluded from bulk updates
  # unless the operator explicitly opts in.
  module NetworkZone

    NZ_PATTERN = /\A\(EXLNZ-(?<network>[^)]*)\)(?<id>.*)\z/.freeze
    CZ_PATTERN = /\A\(EXLCZ\)?(?<id>.*)\z/.freeze
    LOCAL_SUBFIELD_CODE = '9'.freeze
    LOCAL_SUBFIELD_VALUE = 'local'.freeze

    Detection = Struct.new(:linked, :nz_mms_id, :network_code, :cz_id, :local_tags) do
      def linked?
        !!linked
      end

      def to_h
        {
          'linked' => linked?,
          'nz_mms_id' => nz_mms_id,
          'network_code' => network_code,
          'cz_id' => cz_id,
          'local_tags' => Array(local_tags)
        }.reject { |_, value| value.nil? }
      end
    end

    module_function

    def detect(source)
      record = MarcRecord.parse(source)

      nz_mms_id = nil
      network_code = nil
      cz_id = nil
      local_tags = []

      record.fields.each do |field|
        next if field.control?

        field.subfields.each do |code, value|
          if code == LOCAL_SUBFIELD_CODE && value.to_s.strip.casecmp(LOCAL_SUBFIELD_VALUE).zero?
            local_tags << field.tag
            next
          end

          next unless field.tag == '035'

          if (match = NZ_PATTERN.match(value.to_s))
            nz_mms_id ||= match[:id]
            network_code ||= match[:network]
          elsif (match = CZ_PATTERN.match(value.to_s))
            cz_id ||= match[:id]
          end
        end
      end

      local_tags.uniq!

      Detection.new(!nz_mms_id.nil? || !local_tags.empty?, nz_mms_id, network_code, cz_id, local_tags)
    end
  end
end
