# Citrine High-Precision Time, Timers & Frame Stepping
# Modular engine abstraction - require "citrine/time"

struct TimeSpan
  property total_seconds : Float32

  def initialize(@total_seconds : Float32 = 0.0_f32)
  end

  def self.from_seconds(s : Float32) : TimeSpan
    TimeSpan.new(s)
  end

  def self.from_milliseconds(ms : Float32) : TimeSpan
    TimeSpan.new(ms / 1000.0_f32)
  end

  def total_milliseconds : Float32
    @total_seconds * 1000.0_f32
  end

  def +(other : TimeSpan) : TimeSpan
    TimeSpan.new(@total_seconds + other.total_seconds)
  end

  def -(other : TimeSpan) : TimeSpan
    TimeSpan.new(@total_seconds - other.total_seconds)
  end

  def <(other : TimeSpan) : Bool
    @total_seconds < other.total_seconds
  end

  def <=(other : TimeSpan) : Bool
    @total_seconds <= other.total_seconds
  end

  def >(other : TimeSpan) : Bool
    @total_seconds > other.total_seconds
  end

  def >=(other : TimeSpan) : Bool
    @total_seconds >= other.total_seconds
  end
end

module Citrine
  alias TimeSpan = ::TimeSpan

  module Time
    alias Span = ::Time::Span

    def self.instant
      ::Time.instant
    end

    @@simulated_now : Float32 = 0.0_f32
    @@frame_counter : UInt64 = 0_u64

    def self.now : Float32
      @@simulated_now
    end

    def self.monotonic_us : UInt64
      # Emulates EE Timer count (147.456 MHz clock / 16)
      (@@simulated_now * 1_000_000.0_f32).to_u64
    end

    def self.delta_time : Float32
      Citrine.get_delta_time
    end

    def self.fps : Int32
      Citrine.get_fps
    end

    def self.tick_frame(dt : Float32)
      @@simulated_now += dt
      @@frame_counter += 1_u64
    end
  end

  struct Timer
    property duration : Float32
    property elapsed : Float32
    property running : Bool
    property looping : Bool

    def initialize(@duration : Float32, @looping : Bool = false)
      @elapsed = 0.0_f32
      @running = true
    end

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

    def finished? : Bool
      @elapsed >= @duration
    end

    def progress : Float32
      return 1.0_f32 if @duration <= 0.0_f32
      pct = @elapsed / @duration
      pct = 0.0_f32 if pct < 0.0_f32
      pct = 1.0_f32 if pct > 1.0_f32
      pct
    end

    def reset
      @elapsed = 0.0_f32
      @running = true
    end

    def pause
      @running = false
    end

    def resume
      @running = true
    end
  end

  struct FrameTimer
    property fixed_delta : Float32
    property accumulator : Float32
    property max_substeps : Int32

    def initialize(@fixed_delta : Float32 = 1.0_f32 / 60.0_f32, @max_substeps : Int32 = 5)
      @accumulator = 0.0_f32
    end

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
