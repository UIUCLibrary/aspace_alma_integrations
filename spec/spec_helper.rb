require 'json'
require 'tempfile'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'alma_integrations'

# The shared library is deliberately free of ArchivesSpace dependencies so that
# it can be exercised outside a running instance. Nothing in spec/ may require
# anything from backend/ or frontend/.
RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.after(:each) do
    AlmaIntegrations.reset_shared_rate_limiter!
  end
end

module MarcHelpers
  module_function

  # Builds a MARCXML record from a compact description so specs read as MARC
  # rather than as XML plumbing.
  #
  #   marc_xml(leader: '00000nam a2200000 i 4500',
  #            controlfields: { '008' => '240101s2001    iau...' },
  #            datafields: [['035', ' ', ' ', [['a', '(OCoLC)123']]]])
  def marc_xml(leader: nil, controlfields: {}, datafields: [])
    parts = []
    parts << "    <leader>#{leader}</leader>" unless leader.nil?

    controlfields.each do |tag, value|
      parts << %(    <controlfield tag="#{tag}">#{value}</controlfield>)
    end

    datafields.each do |tag, ind1, ind2, subfields|
      parts << %(    <datafield tag="#{tag}" ind1="#{ind1}" ind2="#{ind2}">)
      Array(subfields).each do |code, value|
        parts << %(      <subfield code="#{code}">#{value}</subfield>)
      end
      parts << '    </datafield>'
    end

    "<record>\n#{parts.join("\n")}\n</record>"
  end

  def marc_record(**kwargs)
    AlmaIntegrations::MarcRecord.parse(marc_xml(**kwargs))
  end

  def marc_node(**kwargs)
    Nokogiri::XML(marc_xml(**kwargs), &:noblanks).at_css('record')
  end
end

RSpec.configure do |config|
  config.include MarcHelpers
end
