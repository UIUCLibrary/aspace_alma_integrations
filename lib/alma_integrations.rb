require_relative 'alma_integrations/version'
require_relative 'alma_integrations/errors'
require_relative 'alma_integrations/settings'
require_relative 'alma_integrations/rate_limiter'
require_relative 'alma_integrations/alma_client'
require_relative 'alma_integrations/marc_record'
require_relative 'alma_integrations/marc_labels'
require_relative 'alma_integrations/marc_normalizer'
require_relative 'alma_integrations/marc_diff'
require_relative 'alma_integrations/marc_preserver'
require_relative 'alma_integrations/network_zone'
require_relative 'alma_integrations/identifier_list'
require_relative 'alma_integrations/report_summary'
require_relative 'alma_integrations/report_writer'

# Shared implementation for the ArchivesSpace <-> Alma integrations plugin.
#
# Everything under this namespace is deliberately free of ArchivesSpace
# dependencies: no AppConfig, no JSONModel, no Sequel, no Rails. The backend job
# runners, the frontend controllers and the test suite all load the same code,
# which is the only way the audit report can be trusted to describe what the
# bulk update will actually do.
module AlmaIntegrations
  # Created eagerly: a lazily initialised mutex is itself a race.
  LIMITER_MUTEX = Mutex.new

  class << self
    # Alma's governance limits are enforced per institution, not per API key or
    # per process, so every caller in this process has to draw from one bucket.
    # A job auditing thousands of records and a cataloguer pushing a single
    # record are competing for the same allowance.
    def shared_rate_limiter(requests_per_second = nil)
      rate = normalize_rate(requests_per_second)

      LIMITER_MUTEX.synchronize do
        if @shared_rate_limiter.nil?
          @shared_rate_limiter = RateLimiter.new(:rate => rate)
        elsif rate < @shared_rate_limiter.rate
          # If anything asks for a slower rate, honour it. Taking the minimum
          # means a conservatively configured caller can never be sped up by a
          # more aggressive one that happened to initialise first.
          @shared_rate_limiter.rate = rate
        end

        @shared_rate_limiter
      end
    end

    # Test hook. Not used in normal operation.
    def reset_shared_rate_limiter!
      LIMITER_MUTEX.synchronize { @shared_rate_limiter = nil }
    end

    private

    def normalize_rate(requests_per_second)
      rate = requests_per_second.to_f
      rate > 0 ? rate : Settings::DEFAULTS[:requests_per_second].to_f
    end
  end
end
