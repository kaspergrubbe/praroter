# Runs a mild benchmark and prints out the average time a call to 'throttle!' takes.

require 'praroter'
require 'benchmark'
require 'redis'
require 'securerandom'

def average_ms(ary)
  ary.map { |x| x * 1000 }.inject(0, &:+) / ary.length
end

redis = Redis.new

script_path = File.join(__dir__, "lib", "praroter", "filly_bucket.lua").gsub("/scripts", "")
LUA_SCRIPT_CODE = File.read(script_path)
LUA_SCRIPT_HASH = Digest::SHA1.hexdigest(LUA_SCRIPT_CODE)
redis_script_hash = redis.script(:load, LUA_SCRIPT_CODE)

raise "LUA/REDIS SCRIPT MISMATCH" if LUA_SCRIPT_HASH != redis_script_hash

times = []
15.times do
  times << Benchmark.realtime {
    key = "api"
    redis.evalsha(
      redis_script_hash,
      keys: ["filly_bucket.#{key}.bucket_level", "filly_bucket.#{key}.last_updated"],
      argv: [120, 50, 10]
    )
  }
end

puts average_ms times
def key_for_ts(ts)
  "th:%s:%d" % [@id, ts]
end

times = []
15.times do
  sec, _ = redis.time # Use Redis time instead of the system timestamp, so that all the nodes are consistent
  ts = sec.to_i # All Redis results are strings
  k = key_for_ts(ts)
  times << Benchmark.realtime {
    redis.multi do |txn|
      # Increment the counter
      txn.incr(k)
      txn.expire(k, 120)

      span_start = ts - 120
      span_end = ts + 1
      possible_keys = (span_start..span_end).map { |prev_time| key_for_ts(prev_time) }

      # Fetch all the counter values within the time window. Despite the fact that this
      # will return thousands of elements for large sliding window sizes, the values are
      # small and an MGET in Redis is pretty cheap, so perf should stay well within limits.
      txn.mget(*possible_keys)
    end
  }
end

puts average_ms times
