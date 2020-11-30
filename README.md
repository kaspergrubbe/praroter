# Praroter

This is built on top of, and forked from the excellent gem named Prorate by WeTransfer: https://github.com/WeTransfer/prorate

It was forked because we had slightly different needs for our endpoints:

- We bill calls based on how long the request takes (Prorate is built to bill per requests)
- We only know how long the request took by the end of the request cycle so we have to bill after the work is done (Prorate bills in the beginning of the request)
- Because we bill by the end of the request, we allow consumers to "owe" us time, that they have to pay back by waiting longer.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'praroter'
```

And then execute:

```shell
bundle install
```

Or install it yourself as:

```shell
gem install praroter
```

## Implementation

The simplest mode of operation is throttling an endpoint, this is done by:

- 1. First check if the bucket is empty
- 2. Then do work
- 3. Drain the amount of work done from bucket

## Naïve Rails implementation

Within your Rails controller:

```ruby
def index
  # 1. First check if the bucket is empty
  # -----------------------------------------------------------
  redis = Redis.new
  rate_limiter = Praroter::FillyBucket::Creator.new(redis: redis)
  bucket = rate_limiter.setup_bucket(
    key: [request.ip, params.require(:email)].join,
    fill_rate: 2, # per second
    capacity: 20 # default, acts as a buffer
  )
  bucket.throttle! # This will throw Prarotor::Throttled if level is negative
  request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # 2. Then do work
  # -----------------------------------------------------------
  sleep(2.242)

  # 3. Drain the amount of work from bucket
  # -----------------------------------------------------------
  request_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  request_diff = ((request_end - request_start) * 1000).to_i
  bucket.drain(request_diff)

  render plain: "Home"
end
```

To capture that exception, add this to the controller:

```ruby
rescue_from Praroter::Throttled do |e|
  response.set_header('X-Ratelimit-Level', e.bucket_state.level)
  response.set_header('X-Ratelimit-Capacity', e.bucket_state.capacity)
  response.set_header('X-Ratelimit-Retry-After', e.retry_in_seconds)
  render nothing: true, status: 429
end
```

## Prettier Rails implementation

Within your initializers:

```ruby
require 'prarotor'

redis = Redis.new
Rails.configuration.rate_limiter = Praroter::FillyBucket::Creator.new(redis: redis)
```

Within your Rails controller:

```ruby
def index
  # 1. First check if the bucket is empty
  # -----------------------------------------------------------
  ratelimit_bucket.throttle!

  # 3. Drain the amount of work from bucket
  # -----------------------------------------------------------
  ratelimit_bucket.drain_block do
    # 2. Then do work
    # ---------------------------------------------------------
    sleep(2.242)
  end
end

protected

def ratelimit_bucket
  @ratelimit_bucket ||= Rails.configuration.rate_limiter.setup_bucket(
    key: [request.ip, params.require(:email)].join,
    fill_rate: 2, # per second
    capacity: 20 # default, acts as a buffer
  )
end
```

## Perfect Rails implementation

Within your initializers:

```ruby
require 'prarotor'

redis = Redis.new
Rails.configuration.rate_limiter = Praroter::FillyBucket::Creator.new(redis: redis)
```

Within your Rails controller:

```ruby
around_action :api_ratelimit

def index
  # 2. Then do work
  # ---------------------------------------------------------
  sleep(2.242)
end

rescue_from Praroter::FillyBucket::Throttled do |e|
  response.set_header('X-Ratelimit-Level', e.bucket_state.level)
  response.set_header('X-Ratelimit-Capacity', e.bucket_state.capacity)
  response.set_header('X-Ratelimit-Retry-After', e.retry_in_seconds)
  render nothing: true, status: 429
end

protected

def api_ratelimit
  # 1. First check if the bucket is empty
  # -----------------------------------------------------------
  ratelimit_bucket.throttle!

  # 3. Drain the amount of work from bucket
  # -----------------------------------------------------------
  bucket_state = ratelimit_bucket.drain_block do
    yield
  end
  response.set_header('X-Ratelimit-Level', bucket_state.level)
  response.set_header('X-Ratelimit-Capacity', bucket_state.capacity)
end

def ratelimit_bucket
  @ratelimit_bucket ||= Rails.configuration.rate_limiter.setup_bucket(
    key: [request.ip, params.require(:email)].join,
    fill_rate: 2, # per second
    capacity: 20 # default, acts as a buffer
  )
end
```

## Why Lua?

Praroter is a fork of Prorate, here's what they are saying about the choice of Lua:

Prorate is implementing throttling using the "Leaky Bucket" algorithm and is extensively described [here](https://github.com/WeTransfer/prorate/blob/master/lib/prorate/throttle.rb). The implementation is using a Lua script, because is the only language available which runs _inside_ Redis. Thanks to the speed benefits of Lua the script runs fast enough to apply it on every throttle call.

Using a Lua script in Prorate helps us achieve the following guarantees:

- **The script will run atomically.** The script is evaluated as a single Redis command. This ensures that the commands in the Lua script will never be interleaved with another client: they will always execute together.
- **Any usages of time will use the Redis time.** Throttling requires a consistent and monotonic _time source_. The only monotonic and consistent time source which is usable in the context of Prorate, is the `TIME` result of Redis itself. We are throttling requests from different machines, which will invariably have clock drift between them. This way using the Redis server `TIME` helps achieve consistency.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/kaspergrubbe/praroter.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
