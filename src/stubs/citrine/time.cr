# Citrine High-Precision Time, Timers & Frame Stepping
# Modular engine abstraction - require "citrine/time"

# Represents a duration of time in seconds or milliseconds.
struct TimeSpan
  # Elapsed duration in seconds.
  property total_seconds : Float32

  # Creates a `TimeSpan` of `total_seconds`.
  def initialize(@total_seconds : Float32 = 0.0_f32)
  end

  # Creates a `TimeSpan` from seconds `s`.
  def self.from_seconds(s : Float32) : TimeSpan
    TimeSpan.new(s)
  end

  # Creates a `TimeSpan` from milliseconds `ms`.
  def self.from_milliseconds(ms : Float32) : TimeSpan
    TimeSpan.new(ms / 1000.0_f32)
  end

  # Returns duration in milliseconds.
  def total_milliseconds : Float32
    @total_seconds * 1000.0_f32
  end

  # Adds two time spans.
  def +(other : TimeSpan) : TimeSpan
    TimeSpan.new(@total_seconds + other.total_seconds)
  end

  # Subtracts two time spans.
  def -(other : TimeSpan) : TimeSpan
    TimeSpan.new(@total_seconds - other.total_seconds)
  end

  # Compares whether this duration is less than `other`.
  def <(other : TimeSpan) : Bool
    @total_seconds < other.total_seconds
  end

  # Compares whether this duration is less than or equal to `other`.
  def <=(other : TimeSpan) : Bool
    @total_seconds <= other.total_seconds
  end

  # Compares whether this duration is greater than `other`.
  def >(other : TimeSpan) : Bool
    @total_seconds > other.total_seconds
  end

  # Compares whether this duration is greater than or equal to `other`.
  def >=(other : TimeSpan) : Bool
    @total_seconds >= other.total_seconds
  end
end

module Citrine
  alias TimeSpan = ::TimeSpan

  # System time, frame delta, and hardware monotonic clock access.
  module Time
    alias Span = ::Time::Span

    # Captures current high-resolution instant.
    def self.instant
      ::Time.instant
    end

    @@simulated_now : Float32 = 0.0_f32
    @@frame_counter : UInt64 = 0_u64

    # Returns elapsed seconds since engine start.
    def self.now : Float32
      @@simulated_now
    end

    # Returns monotonic microsecond counter derived from EE Timer hardware.
    def self.monotonic_us : UInt64
      # Emulates EE Timer count (147.456 MHz clock / 16)
      (@@simulated_now * 1_000_000.0_f32).to_u64
    end

    # Returns frame delta time in seconds (e.g. 0.016667 for 60 FPS).
    def self.delta_time : Float32
      Citrine.get_delta_time
    end

    # Returns current measured frames per second.
    def self.fps : Int32
      Citrine.get_fps.to_i32
    end

    # Manually advances the simulated clock by `dt` seconds and increments frame counter.
    def self.tick_frame(dt : Float32)
      @@simulated_now += dt
      @@frame_counter += 1_u64
    end
  end

  # Countdown or periodic timer for gameplay events and cooldowns.
  struct Timer
    # Target duration in seconds before firing.
    property duration : Float32
    # Elapsed duration accumulated so far.
    property elapsed : Float32
    # Whether the timer is currently actively advancing.
    property running : Bool
    # Whether the timer resets automatically upon completion.
    property looping : Bool

    # Creates a timer with target `duration` and optional `looping` behavior.
    def initialize(@duration : Float32, @looping : Bool = false)
      @elapsed = 0.0_f32
      @running = true
    end

    # Advances the timer by `dt` seconds. Returns true if the timer triggered during this tick.
    def tick(dt : Float32) : Bool
      return false unless @running

      @elapsed += dt
      if @elapsed >= @duration
        if @looping
          @elapsed -= @duration
        else
          @running = false
          @elapsed = @duration
        end
        return true
      end

      false
    end

    # Returns true if timer has reached or passed its target duration.
    def finished? : Bool
      @elapsed >= @duration
    end

    # Returns normalized completion progress in `[0.0, 1.0]`.
    def progress : Float32
      return 1.0_f32 if @duration <= 0.0_f32
      pct = @elapsed / @duration
      pct = 0.0_f32 if pct < 0.0_f32
      pct = 1.0_f32 if pct > 1.0_f32
      pct
    end

    # Resets elapsed time to 0 and marks timer as running.
    def reset
      @elapsed = 0.0_f32
      @running = true
    end

    # Pauses timer progression.
    def pause
      @running = false
    end

    # Resumes paused timer.
    def resume
      @running = true
    end
  end

  # Fixed-timestep accumulator for deterministic physics and network simulation.
  struct FrameTimer
    # Fixed delta time consumed per sub-step (e.g. 1/60s).
    property fixed_delta : Float32
    # Accumulated unconsumed frame time.
    property accumulator : Float32
    # Maximum physics ticks allowed per frame to prevent spiral of death.
    property max_substeps : Int32

    # Creates a fixed-timestep frame accumulator.
    def initialize(@fixed_delta : Float32 = 1.0_f32 / 60.0_f32, @max_substeps : Int32 = 5)
      @accumulator = 0.0_f32
    end

    # Accumulates variable frame delta `dt` and executes `block` for each fixed substep available.
    def update(dt : Float32, &block : Float32 -> Nil)
      @accumulator += dt
      steps = 0
      while @accumulator >= @fixed_delta && steps < @max_substeps
        yield @fixed_delta
        @accumulator -= @fixed_delta
        steps += 1
      end
    end
  end
end
