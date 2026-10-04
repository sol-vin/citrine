# Citrine Concurrency - Mutual Exclusion Primitive
# Owner-tracked cooperative mutex with safety canary validation

module Citrine
  # Cooperative mutual exclusion lock with owner-fiber tracking, re-entrant deadlock detection,
  # yield timeouts, and memory-safety canaries.
  class Mutex
    # Magic canary word ("LOCK") ensuring memory buffer integrity.
    CANARY_VALUE = 0x4C4F434B_u32 # "LOCK"

    # Returns true if the mutex is currently held by a fiber.
    getter? locked : Bool
    # The Fiber ID of the lock holder, or `nil` if free.
    getter owner_fiber_id : UInt32?
    @canary : UInt32

    # Creates a new unlocked mutex.
    def initialize
      @locked = false
      @owner_fiber_id = nil
      @canary = CANARY_VALUE
    end

    # Acquires the lock, cooperatively yielding CPU execution until available.
    # Detects recursive re-entrant deadlocks and timeouts.
    def lock(timeout_yields : Int32 = 10_000)
      validate_canary!
      current_fiber = Citrine.fiber_id

      # Re-entrant deadlock detection
      if @locked && @owner_fiber_id == current_fiber
        Citrine.panic("Mutex deadlock: Fiber ##{current_fiber} attempted to recursively acquire non-reentrant Mutex")
      end

      yields = 0
      while !try_lock
        Citrine.yield
        yields += 1
        if yields > timeout_yields
          Citrine.panic("Mutex lock timeout: Fiber ##{current_fiber} timed out waiting for Mutex owned by Fiber ##{@owner_fiber_id}")
        end
      end
    end

    # Attempts to acquire the lock immediately without yielding. Returns true on success.
    def try_lock : Bool
      validate_canary!
      if @locked
        false
      else
        @locked = true
        @owner_fiber_id = Citrine.fiber_id
        true
      end
    end

    # Releases the lock. Verifies the calling fiber is the actual lock owner.
    def unlock
      validate_canary!
      current_fiber = Citrine.fiber_id
      unless @locked
        Citrine.panic("Mutex error: attempted to unlock an unlocked Mutex")
      end

      # Non-owner unlock attempt detection
      if @owner_fiber_id != current_fiber
        Citrine.panic("Mutex invariant violation: Fiber ##{current_fiber} tried to unlock Mutex owned by Fiber ##{@owner_fiber_id}")
      end

      @locked = false
      @owner_fiber_id = nil
    end

    # Executes `block` holding the lock, ensuring `unlock` is always invoked upon return.
    def synchronize(&block)
      lock
      begin
        yield
      ensure
        unlock
      end
    end

    # Corrupts internal canary word to verify defensive memory crash handling during unit tests.
    def corrupt_canary_for_testing!
      @canary = 0xBAD00000_u32
    end

    private def validate_canary!
      if @canary != CANARY_VALUE
        Citrine.panic("Mutex memory corruption: canary 0x#{@canary.to_s(16)} != 0x#{CANARY_VALUE.to_s(16)}")
      end
    end
  end
end
