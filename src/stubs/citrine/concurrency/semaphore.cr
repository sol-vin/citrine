# Citrine Concurrency - Counting Semaphore Primitive
# Resource-bounded cooperative concurrency control

module Citrine
  # Counting semaphore primitive for limiting concurrent fiber access to shared hardware resources
  # (e.g. DMA channels, VU0 pipelines, audio voices).
  class Semaphore
    # Magic canary word ("SEMA") ensuring memory integrity.
    CANARY_VALUE = 0x53454D41_u32 # "SEMA"

    # Number of currently available permits.
    getter permits : Int32
    # Upper bound of permits that can be held or released.
    getter max_permits : Int32
    @canary : UInt32

    # Creates a new counting semaphore with initial `permits` and optional `max_permits`.
    def initialize(@permits : Int32, @max_permits : Int32 = permits)
      if @permits < 0
        Citrine.panic("Semaphore initialization error: negative permits (#{@permits})")
      end
      @canary = CANARY_VALUE
    end

    # Acquires `count` permits, cooperatively yielding until available or timing out.
    def acquire(count : Int32 = 1, timeout_yields : Int32 = 10_000)
      validate_canary!
      if count <= 0
        Citrine.panic("Semaphore acquire error: non-positive count (#{count})")
      end

      yields = 0
      while @permits < count
        Citrine.yield
        yields += 1
        if yields > timeout_yields
          Citrine.panic("Semaphore timeout: exceeded #{timeout_yields} yields waiting for #{count} permits")
        end
      end

      @permits -= count
    end

    # Attempts to acquire `count` permits immediately without blocking. Returns true on success.
    def try_acquire(count : Int32 = 1) : Bool
      validate_canary!
      return false if count <= 0 || @permits < count

      @permits -= count
      true
    end

    # Releases `count` permits back to the pool. Detects capacity overflows.
    def release(count : Int32 = 1)
      validate_canary!
      if count <= 0
        Citrine.panic("Semaphore release error: non-positive count (#{count})")
      end
      if @permits + count > @max_permits
        Citrine.panic("Semaphore overflow: releasing #{count} permits would exceed max (#{@max_permits})")
      end

      @permits += count
    end

    # Corrupts canary value for testing defensive crash diagnostics.
    def corrupt_canary_for_testing!
      @canary = 0xBAD00000_u32
    end

    private def validate_canary!
      if @canary != CANARY_VALUE
        Citrine.panic("Semaphore memory corruption: canary 0x#{@canary.to_s(16)} != 0x#{CANARY_VALUE.to_s(16)}")
      end
    end
  end
end
