require 'spec_helper'
require 'securerandom'

describe Prorate::Throttle do
  describe '#throttle!' do
    let(:throttle_name) { 'leecher-%s' % SecureRandom.hex(4) }
    it 'throttles and raises an exception' do
      r = Redis.new
      t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 2, period: 2, block_for: 5, name: throttle_name)
      t << 'request-id'
      t << 'user-id'

      t.throttle!
      t.throttle!
      expect {
        t.throttle!
      }.to raise_error(Prorate::Throttled)
    end
    
    it 'uses the given parameters to differentiate between users' do
      r = Redis.new
      4.times { |i|
        t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 3, period: 2, block_for: 2, name: throttle_name)
        t << i
        3.times { t.throttle! }
      }
    end

    it 'applies a long block, even if the rolling window for the throttle is shorter' do
      r = Redis.new
      # Exhaust the request limit
      t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 4, period: 1, block_for: 60, name: throttle_name)
      4.times do
        t.throttle!
      end

      expect {
        t.throttle!
      }.to raise_error(Prorate::Throttled)

      sleep 1.5 # The counters have expired and the rolling window has passed, but the block is still set

      expect {
        t.throttle!
      }.to raise_error(Prorate::Throttled)
    end

    it 'raises an error if the block is triggered, and then releases it after block_for seconds' do
      r = Redis.new
      # Exhaust the request limit
      4.times do
        t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 4, period: 1, block_for: 2, name: throttle_name)
        t.throttle!
      end
      # bucket is now full; next request will overflow it
      expect {
        t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 4, period: 1, block_for: 1, name: throttle_name)
        t.throttle!
      }.to raise_error(Prorate::Throttled)
      
      sleep 1.5
      
      # This one should pass again
      t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 4, period: 1, block_for: 1, name: throttle_name)
      t.throttle!
    end
    
    it 'logs all the things' do
      buf = StringIO.new
      logger = Logger.new(buf)
      logger.level = 0
      r = Redis.new
      t = Prorate::Throttle.new(redis: r, logger: logger, limit: 64, period: 15, block_for: 30, name: throttle_name)
      expect(logger).to receive(:info).exactly(32).times.and_call_original
      32.times { t.throttle! }
      expect(buf.string).not_to be_empty
    end

    it 'reloads the lua script when needed' do
      r = Redis.new
      r.script(:flush)
      t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 30, period: 10, block_for: 2, name: throttle_name)
      expect(File).to receive(:read).and_call_original
      expect(r).to receive(:evalsha).exactly(2).times.and_call_original
      expect {
        t.throttle!
      }.not_to raise_error
    end

    it 'raises an error when the script hash is not what was expected' do
      r = Redis.new
      r.script(:flush)
      t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 30, period: 10, block_for: 2, name: throttle_name)
      expect(File).to receive(:read).and_return(' this is not my script :( ')
      expect {
        t.throttle!
      }.to raise_error(Prorate::ScriptHashMismatch)
    end

    it 'does not keep keys around for longer than necessary' do
      r = Redis.new
      t = Prorate::Throttle.new(redis: r, logger: Prorate::NullLogger, limit: 2, period: 2, block_for: 3, name: throttle_name)

      discriminator_string = Digest::SHA1.hexdigest(Marshal.dump([throttle_name]))
      bucket_key = throttle_name + ':' + discriminator_string + '.value'
      last_updated_key = throttle_name + ':' + discriminator_string + '.last_update'
      block_key = throttle_name + ':' + discriminator_string + '.block'

      # At the start all key should be empty
      expect(r.get(bucket_key)).to be_nil
      expect(r.get(last_updated_key)).to be_nil
      expect(r.get(block_key)).to be_nil

      2.times do
        t.throttle!
      end

      # We are not blocked yet
      expect(r.get(bucket_key)).not_to be_nil
      expect(r.get(last_updated_key)).not_to be_nil
      expect(r.get(block_key)).to be_nil
      expect{
        t.throttle!
      }.to raise_error(Prorate::Throttled)
      # Now the block key should be set as well, and the other two should still be set
      expect(r.get(bucket_key)).not_to be_nil
      expect(r.get(last_updated_key)).not_to be_nil
      expect(r.get(block_key)).not_to be_nil
      sleep 2.2
      # After <period> time elapses without anything happening, the keys can be deleted.
      # the block should still be there though
      expect(r.get(bucket_key)).to be_nil
      expect(r.get(last_updated_key)).to be_nil
      expect(r.get(block_key)).not_to be_nil
      sleep 1
      # Now the block should be gone as well
      expect(r.get(bucket_key)).to be_nil
      expect(r.get(last_updated_key)).to be_nil
      expect(r.get(block_key)).to be_nil
    end
  end
end
