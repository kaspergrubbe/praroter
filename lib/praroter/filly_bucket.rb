module Praroter

  module FillyBucket

    class BucketState < Struct.new(:level, :capacity, :fill_rate)
      def empty?
        level <= 0
      end

      def full?
        level >= capacity
      end
    end

    class Bucket
      attr_reader :key, :fill_rate, :capacity

      def initialize(key, fill_rate, capacity, creator)
        @key = key
        @fill_rate = fill_rate
        @capacity = capacity
        @creator = creator
      end

      def state
        @creator.run_lua_bucket_script(self, 0)
      end

      def empty?
        state.empty?
      end

      def full?
        state.full?
      end

      def throttle!
        bucket_state = state
        if bucket_state.empty?
          remaining_block_time = ((bucket_state.capacity - bucket_state.level).abs / bucket_state.fill_rate) + 3
          raise Praroter::Throttled.new(bucket_state, remaining_block_time)
        end
        bucket_state
      end

      def drain(amount)
        raise ArgumentError, "drain amount must be positive" if amount < 0
        @creator.run_lua_bucket_script(self, amount)
      end

      def drain_block
        work_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        work_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        drain(((work_end - work_start) * 1000).to_i)
      end

      def level_key
        "filly_bucket.#{key}.bucket_level"
      end

      def last_updated_key
        "filly_bucket.#{key}.last_updated"
      end
    end

    class Creator
      LUA_SCRIPT_CODE = File.read(File.join(__dir__, "filly_bucket.lua"))
      LUA_SCRIPT_HASH = Digest::SHA1.hexdigest(LUA_SCRIPT_CODE)

      def initialize(redis:)
        @redis = redis.respond_to?(:with) ? redis : NullPool.new(redis)
      end

      def setup_bucket(key:, fill_rate:, capacity:)
        Praroter::FillyBucket::Bucket.new(key, fill_rate, capacity, self)
      end

      def run_lua_bucket_script(bucket, amount)
        @redis.with do |r|
          begin
            # The script returns a tuple of "whole tokens, microtokens"
            # to be able to smuggle the float across (similar to Redis TIME command)
            new_bucket_level, bucket_capacity, fill_rate = r.evalsha(
              LUA_SCRIPT_HASH,
              keys: [bucket.level_key, bucket.last_updated_key],
              argv: [bucket.capacity, bucket.fill_rate, amount]
            )
            BucketState.new(new_bucket_level, bucket_capacity, fill_rate)
          rescue Redis::CommandError => e
            if e.message.include? "NOSCRIPT"
              # The Redis server has never seen this script before. Needs to run only once in the entire lifetime
              # of the Redis server, until the script changes - in which case it will be loaded under a different SHA
              r.script(:load, LUA_SCRIPT_CODE)
              retry
            else
              raise e
            end
          end
        end
      end

    end

  end

end
