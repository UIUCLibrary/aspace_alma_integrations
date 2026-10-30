# Shared fixture lookup for the development-only Alma stub.
#
# Required by both halves of the stub: the frontend patches AlmaRequester, which
# the single-record push screen uses, and the backend patches AlmaClient, which
# the audit and bulk update jobs use. They are different HTTP clients with
# different response objects, but they ask Alma the same questions, so the part
# that answers them lives here.
#
# See dev_plugin/frontend/alma_stub.rb for why this exists at all.
module AlmaFixtures

  def self.dir
    ENV['ALMA_STUB_DIR'].to_s
  end

  def self.enabled?
    !dir.empty? && File.directory?(dir)
  end

  # A fixture is a MARC <record> named after the MMS ID, with default.xml used
  # for any ID that has no file of its own.
  def self.record_for(mms_id)
    candidate = File.join(dir, "#{mms_id}.xml")
    candidate = File.join(dir, 'default.xml') unless File.file?(candidate)

    return nil unless File.file?(candidate)

    File.read(candidate, :encoding => 'UTF-8').sub(/\A<\?xml[^>]*\?>\s*/, '')
  end

  # The <bibs> envelope Alma returns. The mms_id element matters: the
  # multi-record fetch keys off it to tell the records apart.
  def self.bibs_xml(mms_ids)
    found = Array(mms_ids).map { |id| [id, record_for(id)] }.reject { |_, record| record.nil? }

    return [errors_xml(Array(mms_ids).join(',')), 0] if found.empty?

    body = found.map do |mms_id, record|
      <<~XML
        <bib>
          <mms_id>#{mms_id}</mms_id>
          <record_format>marc21</record_format>
          #{record}
        </bib>
      XML
    end

    [%(<bibs total_record_count="#{found.length}">\n#{body.join}\n</bibs>), found.length]
  end

  def self.errors_xml(label)
    <<~XML
      <bibs total_record_count="0">
        <errorsExist>true</errorsExist>
        <errorList>
          <error>
            <errorCode>402203</errorCode>
            <errorMessage>Input parameters mmsId #{label} is not valid.</errorMessage>
          </error>
        </errorList>
      </bibs>
    XML
  end
end
