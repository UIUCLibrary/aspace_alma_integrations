# frozen_string_literal: true

require 'nokogiri'

# Stub out ArchivesSpace-specific gems that are not available in the test
# environment so that loading alma_integrator.rb succeeds without the full
# ArchivesSpace installation.
%w[advanced_query_builder].each do |lib|
  $LOADED_FEATURES << "#{lib}.rb" unless $LOADED_FEATURES.any? { |f| f.end_with?("#{lib}.rb") }
end

# Stub out ArchivesSpace dependencies that AlmaIntegrator requires at load time
# but that are not needed when unit-testing preserve_alma_marc_fields.

# Minimal stub for AdvancedQueryBuilder
class AdvancedQueryBuilder; end

# Minimal stub for AlmaRequester
class AlmaRequester; end

# Minimal stub for AppConfig – behaves like the ArchivesSpace hash-like config
module AppConfig
  @store = {}

  def self.[]=(key, value)
    @store[key] = value
  end

  def self.[](key)
    @store[key]
  end

  def self.has_key?(key)
    @store.key?(key)
  end

  def self.reset!
    @store = {}
  end
end

# Minimal stub for I18n used in AlmaIntegrator
module I18n
  def self.t(key, **_opts)
    key
  end
end

# Minimal stub for JSONModel
module JSONModel
  module HTTP
    def self.backend_url
      'http://localhost:8089'
    end
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Reset AppConfig between examples
  config.before(:each) do
    AppConfig.reset!
  end
end
