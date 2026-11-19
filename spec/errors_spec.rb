require 'spec_helper'

RSpec.describe AlmaIntegrations::ErrorParser do
  it 'parses namespaced XML errors' do
    body = <<~XML
      <web_service_result xmlns="http://com/exlibris/urm/general/xmlbeans">
        <errorList>
          <error>
            <errorCode>PER_SECOND_THRESHOLD</errorCode>
            <errorMessage>Too many requests</errorMessage>
            <trackingId>xml-track-1</trackingId>
          </error>
        </errorList>
      </web_service_result>
    XML

    errors = described_class.parse(body, 'application/xml')

    expect(errors.map(&:to_h)).to eq([
      {
        'code' => 'PER_SECOND_THRESHOLD',
        'message' => 'Too many requests',
        'tracking_id' => 'xml-track-1'
      }
    ])
  end

  it 'parses JSON error lists' do
    body = JSON.generate(
      'errorList' => {
        'error' => [
          {
            'errorCode' => '401',
            'errorMessage' => 'Invalid API key',
            'trackingId' => 'json-track-1'
          },
          {
            'errorCode' => 'DAILY_THRESHOLD',
            'errorMessage' => 'Daily API threshold exceeded'
          }
        ]
      }
    )

    errors = described_class.parse(body, 'application/json')

    expect(errors.map(&:code)).to eq(%w[401 DAILY_THRESHOLD])
    expect(errors.map(&:message)).to eq(['Invalid API key', 'Daily API threshold exceeded'])
    expect(errors.first.tracking_id).to eq('json-track-1')
  end

  it 'never raises and always returns an Array of AlmaError-compatible entries' do
    bodies = {
      'xml' => ['<web_service_result><errorCode>500</errorCode><errorMessage>Broken</errorMessage></web_service_result>', 'application/xml'],
      'json' => ['{"errorsList":{"error":{"errorCode":"402","errorMessage":"Payment required"}}}', 'application/json'],
      'html gateway page' => ['<html><body><h1>502 Bad Gateway</h1></body></html>', 'text/html'],
      'empty body' => ['', nil],
      'garbage body' => ['not xml, not json, just an upstream failure', nil]
    }

    bodies.each_value do |body, content_type|
      result = nil

      expect { result = described_class.parse(body, content_type) }.not_to raise_error
      expect(result).to be_an(Array)
      expect(result).to all(be_a(AlmaIntegrations::AlmaError))
    end
  end

  it 'falls back to a useful AlmaError for HTML and garbage bodies' do
    html_errors = described_class.parse("<html>\n  <body><h1>503 Service Unavailable</h1></body>\n</html>",
                                        'text/html')
    garbage_errors = described_class.parse('%%%%%%%')

    expect(html_errors.length).to eq(1)
    expect(html_errors.first.code).to be_nil
    expect(html_errors.first.message).to eq('<html> <body><h1>503 Service Unavailable</h1></body> </html>')
    expect(garbage_errors.first.to_s).to eq('%%%%%%%')
  end

  it 'returns an empty array for empty bodies' do
    expect(described_class.parse(nil)).to eq([])
    expect(described_class.parse(" \n\t ")).to eq([])
  end

  it 'describes structured errors and falls back to HTTP status or a generic message' do
    json = JSON.generate(
      'errorList' => {
        'error' => {
          'errorCode' => '401',
          'errorMessage' => 'Invalid API key',
          'trackingId' => 'track-401'
        }
      }
    )

    expect(described_class.describe(json)).to eq('[401] Invalid API key (tracking id: track-401)')
    expect(described_class.describe('', 503)).to eq('Alma returned HTTP 503')
    expect(described_class.describe(nil)).to eq('Alma returned an unreadable error')
  end

  it 'detects per-second and daily threshold codes' do
    errors = [
      AlmaIntegrations::AlmaError.new('ALMA_PER_SECOND_THRESHOLD_EXCEEDED', 'Slow down'),
      AlmaIntegrations::AlmaError.new('DAILY_THRESHOLD', 'Daily allowance exhausted')
    ]

    expect(described_class.per_second_threshold?(errors)).to be(true)
    expect(described_class.daily_threshold?(errors)).to be(true)
    expect(described_class.per_second_threshold?([])).to be(false)
    expect(described_class.daily_threshold?([AlmaIntegrations::AlmaError.new('OTHER', 'No')])).to be(false)
  end

  it 'renders AlmaError as text and hashes without nil fields' do
    error = AlmaIntegrations::AlmaError.new('DAILY_THRESHOLD',
                                           'Daily allowance exhausted',
                                           'daily-track-1')
    message_only = AlmaIntegrations::AlmaError.new(nil, 'Gateway timeout')

    expect(error.to_s).to eq('[DAILY_THRESHOLD] Daily allowance exhausted (tracking id: daily-track-1)')
    expect(error.to_h).to eq('code' => 'DAILY_THRESHOLD',
                             'message' => 'Daily allowance exhausted',
                             'tracking_id' => 'daily-track-1')
    expect(message_only.to_h).to eq('message' => 'Gateway timeout')
  end
end
