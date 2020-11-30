# Runs a mild benchmark and prints out the average time a call to 'throttle!' takes.

require 'praroter'
require 'benchmark'
require 'redis'
require 'securerandom'

def average_ms(ary)
  ary.map { |x| x * 1000 }.inject(0, &:+) / ary.length
end

redis = Redis.new

times = []
50.times do
  times << Benchmark.realtime {
    rl = Praroter::FillyBucket::Creator.new(redis: redis)
    b = rl.setup_bucket(key: "throttle-login-email", capacity: 60, fill_rate: 2)
    b.throttle!
  }
end

puts average_ms times

times = []
50.times do
  email = SecureRandom.hex(20)
  ip = SecureRandom.hex(10)
  times << Benchmark.realtime {
    rl = Praroter::FillyBucket::Creator.new(redis: redis)
    b = rl.setup_bucket(key: "#{email}-#{ip}", capacity: 60, fill_rate: 2)
    b.throttle!
  }
end

puts average_ms times
