# The Throttled exception gets raised when a throttle is triggered.
#
# The exception carries additional attributes which can be used for
# error tracking and for creating a correct Retry-After HTTP header for
# a 429 response
class Praroter::Throttled < StandardError
  # @attr [Integer] for how long the caller will be blocked, in seconds.
  attr_reader :retry_in_seconds

  attr_reader :bucket_state

  def initialize(bucket_state, try_again_in)
    @bucket_state = bucket_state
    @retry_in_seconds = try_again_in
    super("Throttled, please lower your temper and try again in #{retry_in_seconds} seconds")
  end
end
