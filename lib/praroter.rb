require "praroter/version"
require "redis"

module Praroter
  Dir.glob(__dir__ + '/praroter/**/*.rb').sort.each do |path|
    require path
  end
end
