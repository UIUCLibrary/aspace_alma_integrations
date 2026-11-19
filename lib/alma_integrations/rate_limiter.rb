module AlmaIntegrations
  # A token bucket that keeps the whole process under Alma's per-second
  # governance threshold.
  #
  # Alma's threshold is enforced per *institution*, so every thread in the
  # ArchivesSpace process needs to draw from the same bucket. Callers should
  # share a single instance (see AlmaIntegrations.shared_rate_limiter).
  #
  # The clock and sleeper are injectable so the behaviour can be tested without
  # real time passing.
  class RateLimiter

    attr_reader :interval

    def rate
      @mutex.synchronize { @rate }
    end

    def initialize(rate: 19, interval: 1.0, clock: nil, sleeper: nil)
      rate = rate.to_f
      interval = interval.to_f

      raise ArgumentError, 'rate must be positive' unless rate > 0
      raise ArgumentError, 'interval must be positive' unless interval > 0

      @rate = rate
      @interval = interval
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @mutex = Mutex.new
      @tokens = rate
      @last_refill = @clock.call
      @total_waited = 0.0
    end

    # Blocks until a request may be made. Returns the number of seconds spent
    # waiting (0.0 when a token was immediately available).
    def acquire
      waited = 0.0

      @mutex.synchronize do
        loop do
          refill

          if @tokens >= 1.0
            @tokens -= 1.0
            break
          end

          delay = seconds_until_next_token
          @sleeper.call(delay)
          waited += delay
        end

        @total_waited += waited
      end

      waited
    end

    # Pause every caller for at least `seconds`. Used when Alma tells us we have
    # exceeded the per-second threshold despite our own throttling -- the limit
    # is institution-wide, so somebody else may be using the quota.
    def penalize(seconds)
      return if seconds.nil? || seconds <= 0

      @mutex.synchronize do
        @sleeper.call(seconds)
        # Start from an empty bucket so the burst that follows a penalty does not
        # immediately trip the threshold again.
        @tokens = 0.0
        @last_refill = @clock.call
      end
    end

    # Lowers (or raises) the sustained rate. The bucket is never allowed to hold
    # more tokens than the new rate permits, so a reduction takes effect
    # immediately rather than after the existing burst drains.
    def rate=(new_rate)
      new_rate = new_rate.to_f
      raise ArgumentError, 'rate must be positive' unless new_rate > 0

      @mutex.synchronize do
        refill
        @rate = new_rate
        @tokens = [@tokens, new_rate].min
      end
    end

    def total_waited
      @mutex.synchronize { @total_waited }
    end

    private

    def refill
      now = @clock.call
      elapsed = now - @last_refill
      return if elapsed <= 0

      @last_refill = now
      @tokens = [@tokens + (elapsed * (@rate / @interval)), @rate].min
    end

    def seconds_until_next_token
      needed = 1.0 - @tokens
      seconds = (needed * @interval) / @rate
      # Never sleep for an unbounded amount, and never busy-spin either.
      [[seconds, 0.001].max, @interval].min
    end
  end
end
