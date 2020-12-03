module Praroter
  module FillyBucket

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
            new_bucket_level, bucket_capacity, fill_rate, scoop = r.evalsha(
              LUA_SCRIPT_HASH,
              keys: [bucket.level_key, bucket.last_updated_key],
              argv: [bucket.capacity, bucket.fill_rate, amount]
            )
            BucketState.new(new_bucket_level, bucket_capacity, fill_rate, scoop)
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
