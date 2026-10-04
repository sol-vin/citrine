# Citrine Physics 2D & Fixed-Point Subsystem
# Modular engine abstraction - require "citrine/physics"

# Q16.16 fixed-point numeric type for deterministic physics simulations
# and platforms without hardware FPU acceleration.
struct FixedPoint
  # Raw 32-bit integer representation (16 integer bits, 16 fractional bits).
  property raw : Int32

  # Creates a `FixedPoint` instance from raw integer value.
  def initialize(@raw : Int32 = 0)
  end

  # Converts a 32-bit floating point number to Q16.16 fixed-point.
  def self.from_float(f : Float32) : FixedPoint
    FixedPoint.new((f * 65536.0_f32).to_i32)
  end

  # Converts an integer to Q16.16 fixed-point.
  def self.from_int(i : Int32) : FixedPoint
    FixedPoint.new(i << 16)
  end

  # Converts this fixed-point value back to Float32.
  def to_float : Float32
    @raw.to_f32 / 65536.0_f32
  end

  # Truncates fractional bits and returns integer portion.
  def to_int : Int32
    @raw >> 16
  end

  # Fixed-point addition.
  def +(other : FixedPoint) : FixedPoint
    FixedPoint.new(@raw + other.raw)
  end

  # Fixed-point subtraction.
  def -(other : FixedPoint) : FixedPoint
    FixedPoint.new(@raw - other.raw)
  end

  # Fixed-point multiplication with 64-bit intermediate accumulator.
  def *(other : FixedPoint) : FixedPoint
    p = @raw.to_i64 * other.raw.to_i64
    FixedPoint.new((p >> 16).to_i32)
  end

  # Fixed-point division with 64-bit dividend scaling.
  def /(other : FixedPoint) : FixedPoint
    num = (@raw.to_i64 << 16)
    FixedPoint.new((num / other.raw.to_i64).to_i32)
  end
end

# 2D Axis-Aligned Bounding Box (AABB) for broadphase collision detection.
struct AABB
  # Upper-left X coordinate.
  property x : Float32
  # Upper-left Y coordinate.
  property y : Float32
  # Box width.
  property w : Float32
  # Box height.
  property h : Float32

  # Creates an AABB bounding box.
  def initialize(@x : Float32, @y : Float32, @w : Float32, @h : Float32)
  end

  # Returns true if this bounding box overlaps with `other` AABB.
  def overlaps?(other : AABB) : Bool
    @x < (other.x + other.w) && (@x + @w) > other.x &&
      @y < (other.y + other.h) && (@y + @h) > other.y
  end

  # Returns true if point `(px, py)` lies inside the bounding box.
  def contains?(px : Float32, py : Float32) : Bool
    px >= @x && px <= (@x + @w) && py >= @y && py <= (@y + @h)
  end
end

# 2D Circle collider defined by center and radius.
struct CircleCollider
  # Center X coordinate.
  property x : Float32
  # Center Y coordinate.
  property y : Float32
  # Circle radius.
  property radius : Float32

  # Creates a circle collider.
  def initialize(@x : Float32, @y : Float32, @radius : Float32)
  end

  # Returns true if this circle intersects with `other` circle collider.
  def overlaps?(other : CircleCollider) : Bool
    dx = @x - other.x
    dy = @y - other.y
    r_sum = @radius + other.radius
    (dx * dx + dy * dy) <= (r_sum * r_sum)
  end

  # Returns true if this circle intersects with axis-aligned bounding `box`.
  def overlaps_aabb?(box : AABB) : Bool
    nearest_x = Citrine::Physics2D.clamp(@x, box.x, box.x + box.w)
    nearest_y = Citrine::Physics2D.clamp(@y, box.y, box.y + box.h)
    dx = @x - nearest_x
    dy = @y - nearest_y
    (dx * dx + dy * dy) <= (@radius * @radius)
  end
end

module Citrine
  # 2D physics math helpers, intersection tests, and Verlet integration primitives.
  module Physics2D
    # Clamps `val` within `[min_val, max_val]`.
    def self.clamp(val : Float32, min_val : Float32, max_val : Float32) : Float32
      if val < min_val
        min_val
      elsif val > max_val
        max_val
      else
        val
      end
    end

    # Checks intersection between two 2D rectangles.
    def self.check_collision_recs(x1 : Float32, y1 : Float32, w1 : Float32, h1 : Float32,
                                  x2 : Float32, y2 : Float32, w2 : Float32, h2 : Float32) : Bool
      x1 < (x2 + w2) && (x1 + w1) > x2 && y1 < (y2 + h2) && (y1 + h1) > y2
    end

    # Checks intersection between two circles.
    def self.check_collision_circles(x1 : Float32, y1 : Float32, r1 : Float32,
                                     x2 : Float32, y2 : Float32, r2 : Float32) : Bool
      dx = x1 - x2
      dy = y1 - y2
      r_sum = r1 + r2
      (dx * dx + dy * dy) <= (r_sum * r_sum)
    end

    # Checks intersection between circle and rectangle.
    def self.check_collision_circle_rec(cx : Float32, cy : Float32, radius : Float32,
                                        rx : Float32, ry : Float32, rw : Float32, rh : Float32) : Bool
      nearest_x = clamp(cx, rx, rx + rw)
      nearest_y = clamp(cy, ry, ry + rh)
      dx = cx - nearest_x
      dy = cy - nearest_y
      (dx * dx + dy * dy) <= (radius * radius)
    end
  end

  # Verlet-integrated point particle for cloth, rope, and soft-body simulations.
  struct VerletParticle
    # Current X position.
    property x : Float32
    # Current Y position.
    property y : Float32
    # Previous X position used for velocity deduction.
    property old_x : Float32
    # Previous Y position used for velocity deduction.
    property old_y : Float32
    # Accumulated acceleration along X-axis.
    property ax : Float32
    # Accumulated acceleration along Y-axis.
    property ay : Float32

    # Creates a Verlet particle at `(x, y)` with zero initial velocity.
    def initialize(@x : Float32, @y : Float32)
      @old_x = @x
      @old_y = @y
      @ax = 0.0_f32
      @ay = 0.0_f32
    end

    # Advances particle simulation by `dt` seconds under gravitational force `gravity`.
    def update(dt : Float32, gravity : Float32)
      vx = (@x - @old_x) * 0.98_f32
      vy = (@y - @old_y) * 0.98_f32

      @old_x = @x
      @old_y = @y

      @x += vx + @ax * dt * dt
      @y += vy + (@ay + gravity) * dt * dt

      @ax = 0.0_f32
      @ay = 0.0_f32
    end

    # Constrains particle within bounding rectangle and handles elastic collision restitution.
    def constrain(min_x : Float32, min_y : Float32, max_x : Float32, max_y : Float32, bounce : Float32 = 0.7_f32)
      if @x < min_x
        vx = (@x - @old_x) * bounce
        @x = min_x
        @old_x = @x + vx
      elsif @x > max_x
        vx = (@x - @old_x) * bounce
        @x = max_x
        @old_x = @x + vx
      end

      if @y < min_y
        vy = (@y - @old_y) * bounce
        @y = min_y
        @old_y = @y + vy
      elsif @y > max_y
        vy = (@y - @old_y) * bounce
        @y = max_y
        @old_y = @y + vy
      end
    end
  end
end
