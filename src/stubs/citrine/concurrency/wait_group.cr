# Citrine Concurrency - WaitGroup Synchronization Primitive
# Cooperatively synchronizes a collection of fibers

module Citrine
  # Synchronization primitive that waits for a collection of concurrent fibers to finish.
  # Provides SPRAM-safe canary auditing to detect memory corruption or buffer overflows.
  #
  # Example:
  # ```crystal
  # wg = Citrine::WaitGroup.new
  # 4.times do
  #   wg.add(1)
  #   spawn do
  #     do_work
  #     wg.done
  #   end
  # end
  # wg.wait
  # ```
  class WaitGroup
    CANARY_VALUE = 0x57414954_u32 # "WAIT"

    # Current count of outstanding unfinished tasks.
    getter count : Int32

    @canary : UInt32

    # Initializes a new WaitGroup counter with canary validation.
    def initialize
      @count = 0
      @canary = CANARY_VALUE
    end

    # Increments the wait counter by `delta`. Panics if counter becomes negative.
    def add(delta : Int32 = 1)
      validate_canary!
      @count += delta
      if @count < 0
        Citrine.panic("WaitGroup underflow: negative counter (#{@count}) detected")
      end
    end

    # Decrements the wait counter by 1. Equivalent to `add(-1)`.
    def done
      add(-1)
    end

    # Cooperatively yields execution until the counter reaches zero.
    # Panics if `timeout_yields` is exceeded to prevent deadlocks.
    def wait(timeout_yields : Int32 = 10_000)
      validate_canary!
      yields = 0
      while @count > 0
        Citrine.yield
        yields += 1
        if yields > timeout_yields
          Citrine.panic("WaitGroup deadlock: exceeded #{timeout_yields} yields waiting for #{@count} tasks")
        end
      end
    end

    # Corrupts internal canary for hardware auditing and fault-injection testing.
    def corrupt_canary_for_testing!
      @canary = 0xBAD00000_u32
    end

    private def validate_canary!
      if @canary != CANARY_VALUE
        Citrine.panic("WaitGroup memory corruption: canary 0x#{@canary.to_s(16)} != 0x#{CANARY_VALUE.to_s(16)}")
      end
    end
  end
end
