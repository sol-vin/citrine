# Citrine Standard Math Library
# Modular engine abstraction - require "citrine/math"

module Citrine
  module Math
    PI = 3.141592653589793_f32
    TAU = 6.283185307179586_f32
    E = 2.718281828459045_f32
    DEG2RAD = 0.017453292519943295_f32
    RAD2DEG = 57.29577951308232_f32

    def self.sin(x : Float32) : Float32
      # Taylor series approximation for PS2 float registers
      # sin(x) = x - x^3/6 + x^5/120 - x^7/5040
      x = normalize_angle(x)
      x2 = x * x
      x * (1.0_f32 - x2 * (0.16666667_f32 - x2 * (0.00833333_f32 - x2 * 0.00019841_f32)))
    end

    def self.cos(x : Float32) : Float32
      sin(x + PI * 0.5_f32)
    end

    def self.tan(x : Float32) : Float32
      c = cos(x)
      return 0.0_f32 if c.abs < 0.00001_f32
      sin(x) / c
    end

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

    def self.sqrt(x : Float32) : Float32
      return 0.0_f32 if x <= 0.0_f32
      # Babylonian method / Newton-Raphson
      guess = x * 0.5_f32 + 0.5_f32
      guess = (guess + x / guess) * 0.5_f32
      guess = (guess + x / guess) * 0.5_f32
      guess = (guess + x / guess) * 0.5_f32
      (guess + x / guess) * 0.5_f32
    end

    def self.hypot(x : Float32, y : Float32) : Float32
      sqrt(x * x + y * y)
    end

    def self.dist(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32) : Float32
      hypot(x2 - x1, y2 - y1)
    end

    def self.abs(x : Float32) : Float32
      x < 0.0_f32 ? -x : x
    end

    def self.abs(x : Int32) : Int32
      x < 0 ? -x : x
    end

    def self.min(a : Float32, b : Float32) : Float32
      a < b ? a : b
    end

    def self.min(a : Int32, b : Int32) : Int32
      a < b ? a : b
    end

    def self.max(a : Float32, b : Float32) : Float32
      a > b ? a : b
    end

    def self.max(a : Int32, b : Int32) : Int32
      a > b ? a : b
    end

    def self.clamp(val : Float32, min_v : Float32, max_v : Float32) : Float32
      return min_v if val < min_v
      return max_v if val > max_v
      val
    end

    def self.clamp(val : Int32, min_v : Int32, max_v : Int32) : Int32
      return min_v if val < min_v
      return max_v if val > max_v
      val
    end

    def self.lerp(a : Float32, b : Float32, t : Float32) : Float32
      a + (b - a) * t
    end

    def self.floor(x : Float32) : Float32
      i = x.to_i32
      (x < 0.0_f32 && x != i.to_f32) ? (i - 1).to_f32 : i.to_f32
    end

    def self.ceil(x : Float32) : Float32
      i = x.to_i32
      (x > 0.0_f32 && x != i.to_f32) ? (i + 1).to_f32 : i.to_f32
    end

    def self.round(x : Float32) : Float32
      floor(x + 0.5_f32)
    end

    def self.sign(x : Float32) : Float32
      x > 0.0_f32 ? 1.0_f32 : (x < 0.0_f32 ? -1.0_f32 : 0.0_f32)
    end

    def self.deg2rad(deg : Float32) : Float32
      deg * DEG2RAD
    end

    def self.rad2deg(rad : Float32) : Float32
      rad * RAD2DEG
    end

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
