# Citrine Concurrency - Memory Safety & Diagnostics Subsystem
# Canary guard bands, deadlock cycle detection, and linear channel ownership tracking

module Citrine
  module Concurrency
    # Runtime safety validators, stack canary audit checks, deadlock cycle detection,
    # and linear handle ownership guards.
    module Safety
      # Magic 64-bit integer placed at the highest address of a fiber stack buffer.
      CANARY_TOP    = 0xDEADBEEF_CAFEF00D_u64
      # Magic 64-bit integer placed at the lowest address of a fiber stack buffer.
      CANARY_BOTTOM = 0xFEEDFACE_01234567_u64

      # Verification structure guarding against fiber stack underflows and overflows on EE MIPS.
      struct StackCanary
        # Top-of-stack guard band value.
        property top_canary : UInt64
        # Bottom-of-stack guard band value.
        property bottom_canary : UInt64

        # Initializes canaries to standard magic patterns.
        def initialize(@top_canary = CANARY_TOP, @bottom_canary = CANARY_BOTTOM)
        end

        # Returns true if neither top nor bottom canary has been overwritten.
        def valid? : Bool
          @top_canary == CANARY_TOP && @bottom_canary == CANARY_BOTTOM
        end

        # Panics immediately if either stack canary is invalid.
        def audit!(fiber_id : UInt32)
          unless valid?
            Citrine.panic("Fiber ##{fiber_id} Stack Canary Corrupted: top=0x#{@top_canary.to_s(16)}, bottom=0x#{@bottom_canary.to_s(16)}")
          end
        end
      end

      # Tracks fiber resource dependencies to detect circular deadlock chains and starvation.
      class DeadlockDetector
        # Resource synchronization types that can block a fiber.
        enum ResourceType
          # Blocked waiting to receive from channel.
          ChannelReceive
          # Blocked waiting to send to full channel.
          ChannelSend
          # Blocked waiting to acquire mutex lock.
          MutexLock
        end

        # Individual dependency wait record.
        record Dependency, fiber_id : UInt32, resource_type : ResourceType, resource_id : UInt32

        @wait_graph : Array(Dependency)

        # Creates a new deadlock detector.
        def initialize
          @wait_graph = [] of Dependency
        end

        # Records that `fiber_id` is blocked waiting for resource of type `type`.
        def record_wait(fiber_id : UInt32, type : ResourceType, resource_id : UInt32)
          @wait_graph << Dependency.new(fiber_id, type, resource_id)
        end

        # Clears blocked status for `fiber_id`.
        def record_wake(fiber_id : UInt32)
          @wait_graph.reject! { |d| d.fiber_id == fiber_id }
        end

        # Detects if all active fibers are blocked in a circular or unresolvable wait condition.
        def detect_deadlock(active_fiber_count : Int32) : Bool
          return false if active_fiber_count <= 1
          # If all active fibers are blocked on resources
          blocked_fibers = @wait_graph.map(&.fiber_id).uniq
          blocked_fibers.size >= active_fiber_count
        end

        # Formats diagnostic summary of all blocked fibers and pending resources.
        def deadlock_report : String
          io = IO::Memory.new
          io.puts "[CITRINE CONCURRENCY PANIC] Deadlock Detected Across #{wait_count} Dependencies:"
          @wait_graph.each do |dep|
            io.puts "  - Fiber ##{dep.fiber_id} waiting on #{dep.resource_type} (Resource ID: #{dep.resource_id})"
          end
          io.to_s
        end

        # Number of currently active wait dependencies.
        def wait_count : Int32
          @wait_graph.size
        end

        # Clears all wait graph records.
        def clear
          @wait_graph.clear
        end
      end

      # Enforces linear affine ownership invariants across channels to prevent use-after-free and data races.
      class LinearOwnershipTracker
        @owned_handles : Hash(UInt32, UInt32) # Handle -> Owner Fiber ID

        # Creates an empty linear ownership tracker.
        def initialize
          @owned_handles = Hash(UInt32, UInt32).new
        end

        # Registers `handle` as owned exclusively by `owner_fiber_id`.
        def register(handle : UInt32, owner_fiber_id : UInt32)
          @owned_handles[handle] = owner_fiber_id
        end

        # Transfers handle ownership through a channel to a recipient fiber. Panics on invariant violation.
        def transfer!(handle : UInt32, from_fiber_id : UInt32, to_fiber_id : UInt32)
          current_owner = @owned_handles[handle]?
          if current_owner && current_owner != from_fiber_id
            Citrine.panic("Linear Ownership Violation: Fiber ##{from_fiber_id} attempted to transfer handle ##{handle} owned by Fiber ##{current_owner}")
          end
          @owned_handles[handle] = to_fiber_id
        end

        # Returns the current owner Fiber ID for `handle`, or `nil` if untracked.
        def owner_of(handle : UInt32) : UInt32?
          @owned_handles[handle]?
        end

        # Releases tracked ownership of `handle`. Panics if calling fiber is not the registered owner.
        def release(handle : UInt32, fiber_id : UInt32)
          current_owner = @owned_handles[handle]?
          if current_owner && current_owner != fiber_id
            Citrine.panic("Linear Ownership Violation: Fiber ##{fiber_id} attempted to release handle ##{handle} owned by Fiber ##{current_owner}")
          end
          @owned_handles.delete(handle)
        end
      end
    end
  end
end
