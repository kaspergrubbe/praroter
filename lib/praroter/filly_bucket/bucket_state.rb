module Praroter
  module FillyBucket

    class BucketState < Struct.new(:level, :capacity, :fill_rate, :drained)
      def empty?
        level <= 0
      end

      def full?
        level >= capacity
      end
    end

  end
end
