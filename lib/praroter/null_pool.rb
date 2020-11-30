module Praroter
  class NullPool < Struct.new(:conn)
    def with
      yield conn
    end
  end
end
