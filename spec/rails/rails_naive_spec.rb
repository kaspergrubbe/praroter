# frozen_string_literal: true

require "rack/test"
require "action_controller/railtie"
require "spec_helper"

RSpec.describe "Naive Rails example" do
  include Rack::Test::Methods

  class NaiveTestApp < Rails::Application
    config.root = __dir__
    config.hosts << "example.org"
    config.hosts.clear
    config.session_store :cookie_store, key: "cookie_store_key"
    secrets.secret_key_base = "secret_key_base"

    config.logger = Logger.new($stdout)
    Rails.logger  = config.logger

    routes.draw do
      get "/naive" => "naive_test#naive"
    end
  end

  class NaiveTestController < ActionController::Base
    include Rails.application.routes.url_helpers

    rescue_from Praroter::Throttled do |e|
      response.set_header('X-Ratelimit-Cost', e.bucket_state.drained)
      response.set_header('X-Ratelimit-Level', e.bucket_state.level)
      response.set_header('X-Ratelimit-Capacity', e.bucket_state.capacity)
      response.set_header('X-Ratelimit-Retry-After', e.retry_in_seconds)
      head 429
    end

    def naive
      # 1. First check if the bucket is empty
      # -----------------------------------------------------------
      redis = Redis.new
      rate_limiter = Praroter::FillyBucket::Creator.new(redis: redis)
      bucket = rate_limiter.setup_bucket(
        key: request.headers['TESTRUN'],
        fill_rate: 600, # per second
        capacity: 4000  # default, acts as a buffer
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
      bucket_state = bucket.drain(request_diff)
      response.set_header('X-Ratelimit-Cost', bucket_state.drained)
      response.set_header('X-Ratelimit-Level', bucket_state.level)
      response.set_header('X-Ratelimit-Capacity', bucket_state.capacity)

      render plain: "Hello"
    end

  end

  def app
    NaiveTestApp
  end

  let(:testrun_id) { Random.srand }

  it 'should respond correctly' do
    loop do
      header "testrun", testrun_id
      get '/naive'

      if last_response.headers["X-Ratelimit-Retry-After"].present?
        expect(last_response.status).to eq 429
        expect(last_response.headers["X-Ratelimit-Cost"]).to be_present
        expect(last_response.headers["X-Ratelimit-Capacity"]).to be_present
        expect(last_response.headers["X-Ratelimit-Level"]).to be_present

        sleep(last_response.headers["X-Ratelimit-Retry-After"])
        break
      else
        expect(last_response.status).to eq 200
        expect(last_response.headers["X-Ratelimit-Cost"]).to be_present
        expect(last_response.headers["X-Ratelimit-Capacity"]).to be_present
        expect(last_response.headers["X-Ratelimit-Level"]).to be_present
        expect(last_response.headers["X-Ratelimit-Retry-After"]).to_not be_present
      end
    end

    # We've waited the amount of time the API told us to wait, the next call should pass
    header "testrun", testrun_id
    get '/naive'
    expect(last_response.status).to eq 200
    expect(last_response.headers["X-Ratelimit-Cost"]).to be_present
    expect(last_response.headers["X-Ratelimit-Capacity"]).to be_present
    expect(last_response.headers["X-Ratelimit-Level"]).to be_present
    expect(last_response.headers["X-Ratelimit-Retry-After"]).to_not be_present
  end

end
