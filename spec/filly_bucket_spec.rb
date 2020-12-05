require 'spec_helper'
require 'securerandom'
require 'connection_pool'

describe Praroter::FillyBucket::Bucket do
  # There is timing involved in Praroter, and some issues can be intermittent.
  # To make sure _both_ code and tests are resilient, we should run multiple iterations
  # of the test and do it in a reproducible way.
  # one of the ways to make it reproducible is to use random names which are reproduced
  # with the same RSpec seed
  randomness = Random.new(RSpec.configuration.seed)
  random_bucket_name = -> {
    (1..32).map do
      # bytes 97 to 122 are printable lowercase a-z
      randomness.rand(97..122)
    end.pack("C*")
  }

  describe 'in a happy path' do
    let(:bucket_name) { random_bucket_name.call }
    let(:r) { Redis.new }
    let(:pool) { ConnectionPool.new { r } }

    it 'is able to use a ConnectionPool' do
      creator = Praroter::FillyBucket::Creator.new(redis: pool)
      bucket = creator.setup_bucket(key: bucket_name, fill_rate: 1, capacity: 2)
      expect(bucket.state.level).to eq 2
    end

    it 'is able to use a naked Redis connection' do
      creator = Praroter::FillyBucket::Creator.new(redis: r)
      bucket = creator.setup_bucket(key: bucket_name, fill_rate: 1, capacity: 2)
      expect(bucket.state.level).to eq 2
    end

    it "accepts the number of tokens and returns the new bucket level" do
      creator = Praroter::FillyBucket::Creator.new(redis: r)
      bucket = creator.setup_bucket(key: bucket_name, fill_rate: 1, capacity: 20)

      # Nothing should be written into Redis just when creating the object in Ruby
      expect(r.get(bucket.level_key)).to be_nil
      expect(r.get(bucket.last_updated_key)).to be_nil

      expect(bucket.state.level).to eq 20

      # Since we haven't put in any tokens, asking for the levels should not have created
      # any Redis keys as we do not need them
      expect(r.get(bucket.level_key)).to be_nil
      expect(r.get(bucket.last_updated_key)).to be_nil

      sleep(0.2) # Bucket should stay full and not go over capacity
      bucket_state = bucket.state
      expect(bucket_state.level).to be <= 20
      expect(bucket_state).to be_full

      # Since we drained the keys should have been created
      bucket_state = bucket.drain(2)
      expect(r.get(bucket.level_key)).not_to be_nil
      expect(r.get(bucket.last_updated_key)).not_to be_nil
      expect(bucket_state.level).to eq 18

      sleep(1)
      bucket_state = bucket.state
      expect(bucket_state).not_to be_full
      expect(bucket_state.level).to be_within(0.1).of(20 - 1)

      # If we take out more tokens than there are, we should allow negative numbers
      sleep(1)
      bucket_state = bucket.drain(30)
      expect(bucket_state).not_to be_full
      expect(bucket_state).to be_empty
      expect(bucket_state.level).to be_within(0.1).of(-10)

      # We need to make sure the keys which we set have a TTL and that the TTL
      # is reasonable. We cannot check whether the key has been expired or not because deletion in
      # Redis is somewhat best-effort - there is no guarantee that something will be deleted at
      # the given TTL, so testing for it is not very useful
      difference = (bucket_state.level..bucket.capacity).size

      expect(r.ttl(bucket.level_key)).to be_within(0.5).of(difference)
      expect(r.ttl(bucket.last_updated_key)).to be_within(0.5).of(difference)
    end

    it 'should give error when fed a negative number' do
      creator = Praroter::FillyBucket::Creator.new(redis: pool)
      bucket = creator.setup_bucket(key: bucket_name, fill_rate: 1, capacity: 10)

      expect { bucket.drain(0) }.to_not raise_error
      expect { bucket.drain(-1) }.to raise_error(ArgumentError, "drain amount must be a positive number")
      expect { bucket.drain(nil) }.to raise_error(ArgumentError, "drain amount must be an integer")
    end

    it 'should bounce back to capacity after being negative' do
      creator = Praroter::FillyBucket::Creator.new(redis: pool)
      bucket = creator.setup_bucket(key: bucket_name, fill_rate: 1, capacity: 10)

      bucket_state = bucket.drain(20)
      expect(bucket_state).not_to be_full
      expect(bucket_state).to be_empty
      expect(bucket_state.level).to be_within(0.1).of(-10)

      previous_level = nil
      while bucket.state.level != 10
        level = bucket.state.level

        if previous_level
          expect(level).to be > previous_level
        end
        previous_level = level
        sleep(2)
      end

      expect(bucket.state.level).to eq(10)
    end
  end

  describe 'key generation' do
    it 'should interpolate the keys' do
      creator = Praroter::FillyBucket::Creator.new(redis: ConnectionPool.new { Redis.new })
      b1 = Praroter::FillyBucket::Bucket.new("user42", 250, 10_000, creator)

      expect(b1.level_key).to eq "filly_bucket.user42.bucket_level"
      expect(b1.last_updated_key).to eq "filly_bucket.user42.last_updated"
    end

    it 'should interpolate the keys' do
      creator = Praroter::FillyBucket::Creator.new(redis: ConnectionPool.new { Redis.new })
      b2 = creator.setup_bucket(key: "user43", fill_rate: 250, capacity: 10_000)

      expect(b2.level_key).to eq "filly_bucket.user43.bucket_level"
      expect(b2.last_updated_key).to eq "filly_bucket.user43.last_updated"
    end
  end

  describe 'draining' do
    it 'should drain multiple buckets' do
      creator = Praroter::FillyBucket::Creator.new(redis: ConnectionPool.new { Redis.new })
      b3 = creator.setup_bucket(key: random_bucket_name.call, fill_rate: 250, capacity: 10_000)
      b4 = creator.setup_bucket(key: random_bucket_name.call, fill_rate: 250, capacity: 10_000)

      bs1 = b3.drain(1_000)
      expect(bs1.drained).to eq 1_000
      expect(bs1.level).to eq 9_000
      expect(bs1.capacity).to eq 10_000

      bs2 = b4.drain(2_000)
      expect(bs2.drained).to eq 2_000
      expect(bs2.level).to eq 8_000
      expect(bs2.capacity).to eq 10_000
    end

    it 'should drain same bucket multiple times' do
      creator = Praroter::FillyBucket::Creator.new(redis: ConnectionPool.new { Redis.new })
      bucket = creator.setup_bucket(key: random_bucket_name.call, fill_rate: 250, capacity: 10_000)

      bs1 = bucket.drain(1)
      expect(bs1.drained).to eq 1
      expect(bs1.level).to eq 9_999
      expect(bs1.capacity).to eq 10_000

      bs1 = bucket.drain(1_000)
      expect(bs1.drained).to eq 1_000
      expect(bs1.level).to eq 8_999
      expect(bs1.capacity).to eq 10_000
    end
  end
end
