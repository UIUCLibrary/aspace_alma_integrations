require 'spec_helper'

RSpec.describe AlmaIntegrations::RateLimiter do
  def fake_time(start_at = 0.0)
    mutex = Mutex.new
    state = { :now => start_at.to_f, :sleeps => [] }
    fake = Object.new

    fake.define_singleton_method(:clock) do
      -> { mutex.synchronize { state[:now] } }
    end

    fake.define_singleton_method(:sleeper) do
      lambda do |seconds|
        mutex.synchronize do
          state[:sleeps] << seconds
          state[:now] += seconds
        end
      end
    end

    fake.define_singleton_method(:advance) do |seconds|
      mutex.synchronize { state[:now] += seconds }
    end

    fake.define_singleton_method(:now) do
      mutex.synchronize { state[:now] }
    end

    fake.define_singleton_method(:sleeps) do
      mutex.synchronize { state[:sleeps].dup }
    end

    fake
  end

  def limiter_with(fake, rate:, interval: 1.0)
    described_class.new(:rate => rate,
                        :interval => interval,
                        :clock => fake.clock,
                        :sleeper => fake.sleeper)
  end

  it 'permits an initial burst up to capacity and then throttles' do
    time = fake_time
    limiter = limiter_with(time, :rate => 3)

    waits = 4.times.map { limiter.acquire }

    expect(waits.first(3)).to eq([0.0, 0.0, 0.0])
    expect(waits.last).to be_within(0.00001).of(1.0 / 3.0)
    expect(time.sleeps).to contain_exactly(be_within(0.00001).of(1.0 / 3.0))
    expect(limiter.total_waited).to be_within(0.00001).of(1.0 / 3.0)
  end

  it 'refills tokens over simulated time without sleeping for real' do
    time = fake_time
    limiter = limiter_with(time, :rate => 4)

    4.times { expect(limiter.acquire).to eq(0.0) }
    time.advance(0.5)

    expect(limiter.acquire).to eq(0.0)
    expect(limiter.acquire).to eq(0.0)
    expect(limiter.acquire).to be_within(0.00001).of(0.25)
    expect(time.sleeps).to eq([0.25])
  end

  it 'never refills above the bucket capacity' do
    time = fake_time
    limiter = limiter_with(time, :rate => 2)

    2.times { limiter.acquire }
    time.advance(100.0)

    expect(limiter.acquire).to eq(0.0)
    expect(limiter.acquire).to eq(0.0)
    expect(limiter.acquire).to be_within(0.00001).of(0.5)
    expect(time.sleeps).to eq([0.5])
  end

  it 'refills under the old rate and clamps tokens when rate is changed' do
    time = fake_time
    limiter = limiter_with(time, :rate => 4)

    4.times { limiter.acquire }
    time.advance(0.5)

    limiter.rate = 1

    expect(limiter.rate).to eq(1.0)
    expect(limiter.acquire).to eq(0.0)
    expect(limiter.acquire).to be_within(0.00001).of(1.0)
    expect(time.sleeps).to eq([1.0])
  end

  it 'accumulates the total simulated wait time' do
    time = fake_time
    limiter = limiter_with(time, :rate => 2)

    2.times { limiter.acquire }
    3.times { expect(limiter.acquire).to be_within(0.00001).of(0.5) }

    expect(limiter.total_waited).to be_within(0.00001).of(1.5)
  end

  it 'does not issue the same token twice under concurrent callers' do
    time = fake_time
    limiter = limiter_with(time, :rate => 2)
    start = Queue.new
    results = Queue.new
    thread_count = 5
    acquires_per_thread = 4
    total_acquires = thread_count * acquires_per_thread

    threads = thread_count.times.map do
      Thread.new do
        start.pop
        acquires_per_thread.times { results << limiter.acquire }
      end
    end

    thread_count.times { start << true }
    threads.each(&:join)

    waits = []
    waits << results.pop until results.empty?

    expect(waits.length).to eq(total_acquires)
    expect(waits.count(&:zero?)).to eq(2)
    expect(time.sleeps.length).to eq(total_acquires - 2)
    expect(time.sleeps).to all(be_within(0.00001).of(0.5))
    expect(limiter.total_waited).to be_within(0.00001).of((total_acquires - 2) * 0.5)
    expect(time.now).to be_within(0.00001).of((total_acquires - 2) * 0.5)
  end

  it 'rejects non-positive rates' do
    expect { described_class.new(:rate => 0) }.to raise_error(ArgumentError, /rate/)
    expect { limiter_with(fake_time, :rate => 1).rate = 0 }.to raise_error(ArgumentError, /rate/)
  end
end
