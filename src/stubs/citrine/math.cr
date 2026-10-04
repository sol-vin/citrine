# Citrine Standard Math Library
# Modular engine abstraction - require "citrine/math"

module Citrine
  # Standard mathematical constants, trigonometry approximations,
  # interpolation routines, and geometric utility functions.
  module Math
    # Mathematical constant Pi (\(\pi \approx 3.14159265\)).
    PI = 3.141592653589793_f32
    # Mathematical constant Tau (\(\tau = 2\pi \approx 6.2831853\)).
    TAU = 6.283185307179586_f32
    # Euler's number (\(e \approx 2.7182818\)).
    E = 2.718281828459045_f32
    # Multiplier to convert degrees to radians (\(\pi / 180\)).
    DEG2RAD = 0.017453292519943295_f32
    # Multiplier to convert radians to degrees (\(180 / \pi\)).
    RAD2DEG = 57.29577951308232_f32

    # Computes sine of `x` (in radians) using an accurate Taylor series polynomial.
    def self.sin(x : Float32) : Float32
      # Taylor series approximation for PS2 float registers
      # sin(x) = x - x^3/6 + x^5/120 - x^7/5040
      x = normalize_angle(x)
      x2 = x * x
      x * (1.0_f32 - x2 * (0.16666667_f32 - x2 * (0.00833333_f32 - x2 * 0.00019841_f32)))
    end

    # Computes cosine of `x` (in radians) via phase-shifted sine.
    def self.cos(x : Float32) : Float32
      sin(x + PI * 0.5_f32)
    end

    # Computes tangent of `x` (in radians).
    def self.tan(x : Float32) : Float32
      c = cos(x)
      return 0.0_f32 if c.abs < 0.00001_f32
      sin(x) / c
    end

    # Computes the four-quadrant inverse tangent `atan2(y, x)` in radians.
    def self.atan2(y : Float32, x : Float32) : Float32
      # Fast atan2 approximation
      if x == 0.0_f32
        return y > 0.0_f32 ? (PI * 0.5_f32) : (-PI * 0.5_f32)
      end
      ratio = y / x
      angle = ratio / (1.0_f32 + 0.28_f32 * ratio * ratio)
      if x < 0.0_f32
        angle += y < 0.0_f32 ? -PI : PI
      end
      angle
    end

    # Computes square root using Babylonian iterative refinement.
    def self.sqrt(x : Float32) : Float32
      return 0.0_f32 if x <= 0.0_f32
      # Babylonian method / Newton-Raphson
      guess = x * 0.5_f32 + 0.5_f32
      guess = (guess + x / guess) * 0.5_f32
      guess = (guess + x / guess) * 0.5_f32
      guess = (guess + x / guess) * 0.5_f32
      (guess + x / guess) * 0.5_f32
    end

    # Computes Euclidean hypotenuse `sqrt(x^2 + y^2)`.
    def self.hypot(x : Float32, y : Float32) : Float32
      sqrt(x * x + y * y)
    end

    # Computes Euclidean distance between 2D points `(x1, y1)` and `(x2, y2)`.
    def self.dist(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32) : Float32
      hypot(x2 - x1, y2 - y1)
    end

    # Returns absolute value of Float32 `x`.
    def self.abs(x : Float32) : Float32
      x < 0.0_f32 ? -x : x
    end

    # Returns absolute value of Int32 `x`.
    def self.abs(x : Int32) : Int32
      x < 0 ? -x : x
    end

    # Returns minimum of two Float32 values.
    def self.min(a : Float32, b : Float32) : Float32
      a < b ? a : b
    end

    # Returns minimum of two Int32 values.
    def self.min(a : Int32, b : Int32) : Int32
      a < b ? a : b
    end

    # Returns maximum of two Float32 values.
    def self.max(a : Float32, b : Float32) : Float32
      a > b ? a : b
    end

    # Returns maximum of two Int32 values.
    def self.max(a : Int32, b : Int32) : Int32
      a > b ? a : b
    end

    # Clamps Float32 value between `min_v` and `max_v`.
    def self.clamp(val : Float32, min_v : Float32, max_v : Float32) : Float32
      return min_v if val < min_v
      return max_v if val > max_v
      val
    end

    # Clamps Int32 value between `min_v` and `max_v`.
    def self.clamp(val : Int32, min_v : Int32, max_v : Int32) : Int32
      return min_v if val < min_v
      return max_v if val > max_v
      val
    end

    # Linearly interpolates between `a` and `b` by factor `t` (0.0 to 1.0).
    def self.lerp(a : Float32, b : Float32, t : Float32) : Float32
      a + (b - a) * t
    end

    # Returns largest integer less than or equal to `x` as Float32.
    def self.floor(x : Float32) : Float32
      i = x.to_i32
      (x < 0.0_f32 && x != i.to_f32) ? (i - 1).to_f32 : i.to_f32
    end

    # Returns smallest integer greater than or equal to `x` as Float32.
    def self.ceil(x : Float32) : Float32
      i = x.to_i32
      (x > 0.0_f32 && x != i.to_f32) ? (i + 1).to_f32 : i.to_f32
    end

    # Rounds `x` to nearest integer as Float32.
    def self.round(x : Float32) : Float32
      floor(x + 0.5_f32)
    end

    # Returns sign of `x` (-1.0, 0.0, or 1.0).
    def self.sign(x : Float32) : Float32
      x > 0.0_f32 ? 1.0_f32 : (x < 0.0_f32 ? -1.0_f32 : 0.0_f32)
    end

    # Converts angle from degrees to radians.
    def self.deg2rad(deg : Float32) : Float32
      deg * DEG2RAD
    end

    # Converts angle from radians to degrees.
    def self.rad2deg(rad : Float32) : Float32
      rad * RAD2DEG
    end

    # Normalizes angle in radians into the range \([-\pi, \pi]\).
    def self.normalize_angle(angle : Float32) : Float32
      while angle > PI
        angle -= TAU
      end
      while angle < -PI
        angle += TAU
      end
      angle
    end
  end
end
