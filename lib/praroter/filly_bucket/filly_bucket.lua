-- this is required to be able to use TIME and writes; basically it lifts the script into IO
redis.replicate_commands()

-- Redis documentation recommends passing the keys separately so that Redis
-- can - in the future - verify that they live on the same shard of a cluster, and
-- raise an error if they are not. As far as can be understood this functionality is not
-- yet present, but if we can make a little effort to make ourselves more future proof
-- we should.
local bucket_level_key = KEYS[1]
local last_updated_key = KEYS[2]

local bucket_capacity = tonumber(ARGV[1]) -- How many tokens is the bucket allowed to contain
local fill_rate = tonumber(ARGV[2])
local scoop = tonumber(ARGV[3]) -- How many tokens to remove

-- Take a timestamp
local redis_time = redis.call("TIME") -- Array of [seconds, microseconds]
local now = tonumber(redis_time[1]) + (tonumber(redis_time[2]) / 1000000)

-- get current bucket level. The throttle key might not exist yet in which
-- case we default to bucket_capacity
local bucket_level = tonumber(redis.call("GET", bucket_level_key)) or bucket_capacity

-- ...and then perform the leaky bucket fillup/leak. We need to do this also when the bucket has
-- just been created because the initial fillup to add might be so high that it will
-- immediately overflow the bucket and trigger the throttle, on the first call.
local last_updated = tonumber(redis.call("GET", last_updated_key)) or now -- use sensible default of 'now' if the key does not exist

-- Add the number of tokens dripped since last call
local dt = now - last_updated
local new_bucket_level = bucket_level + (fill_rate * dt) - scoop

-- and _then_ and add the tokens we fillup with
new_bucket_level = math.min(bucket_capacity, new_bucket_level)

-- Compute the key TTL for the bucket. We are interested in how long it takes the bucket
-- to leak all the way to bucket_capacity, as this is the time when the values stay relevant. We pad with 1 second
-- to have a little cushion.
local key_lifetime = nil
if new_bucket_level < 0 then -- if new_bucket_level is negative, then the TTL need to be longer
  key_lifetime = math.ceil((math.abs(bucket_capacity - new_bucket_level) / fill_rate) + 1)
else
  key_lifetime = math.ceil((bucket_capacity / fill_rate) + 1)
end

if new_bucket_level == bucket_capacity then
  return {new_bucket_level, bucket_capacity, fill_rate, scoop}
else
  -- Save the new bucket level
  redis.call("SETEX", bucket_level_key, key_lifetime, new_bucket_level)

  -- Record when we updated the bucket so that the amount of tokens leaked
  -- can be correctly determined on the next invocation
  redis.call("SETEX", last_updated_key, key_lifetime, now)

  return {new_bucket_level, bucket_capacity, fill_rate, scoop}
end
