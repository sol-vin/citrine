# Citrine Concurrency - Once Primitive
# Guarantees single-run execution across concurrent fibers

module Citrine
  # Thread-safe and fiber-safe initialization primitive.
  # Guarantees that an initialization routine executes exactly once,
  # even when invoked simultaneously by multiple concurrent fibers.
  #
  # Example:
  # ```crystal
  # once = Citrine::Once.new
  # once.do do
  #   init_heavy_hardware_resource
  # end
  # ```
  class Once
    # Returns true if the wrapped block has completed execution.
    getter? done : Bool

    @mutex : Citrine::Mutex

    # Initializes an un-triggered Once sentinel.
    def initialize
      @done = false
      @mutex = Citrine::Mutex.new
    end

    # Executes the given block if and only if no previous call to `do` has succeeded.
    def do(&block)
      return if @done

      @mutex.synchronize do
        unless @done
          yield
          @done = true
        end
      end
    end
  end
end
