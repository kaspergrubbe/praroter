module Praroter
  module FillyBucket

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

  end
end
