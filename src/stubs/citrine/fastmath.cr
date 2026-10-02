# Citrine FastMath: Look-Up Tables & Bitwise Optimizations for PS2
# Modular engine abstraction - require "citrine/fastmath"

module Citrine
  module FastMath
    LUT_SIZE = 1024
    LUT_MASK = 1023

    # Fast Inverse Square Root (Quake 1/sqrt(x) on 32-bit registers)
    def self.fast_inv_sqrt(number : Float32) : Float32
      return 0.0_f32 if number <= 0.0_f32

      x2 = number * 0.5_f32
      y = number
      # Bitwise cast to Int32
      i = y.unsafe_as(Int32)
      # Magic constant for 32-bit float
      i = 0x5f3759df - (i >> 1)
      y = i.unsafe_as(Float32)
      # 1st Newton-Raphson iteration
      y = y * (1.5_f32 - (x2 * y * y))
      y
    end

    def self.fast_sqrt(number : Float32) : Float32
      inv = fast_inv_sqrt(number)
      inv > 0.0_f32 ? (1.0_f32 / inv) : 0.0_f32
    end

    def self.is_power_of_two?(n : Int32) : Bool
      n > 0 && ((n & (n - 1)) == 0)
    end

    def self.next_power_of_two(n : Int32) : Int32
      return 1 if n <= 0
      v = n - 1
      v |= v >> 1
      v |= v >> 2
      v |= v >> 4
      v |= v >> 8
      v |= v >> 16
      v + 1
    end

    def self.fast_log2(n : Int32) : Int32
      return 0 if n <= 0
      bits = 0
      v = n
      while v > 1
        v >>= 1
        bits += 1
      end
      bits
    end

    # Fast Integer Square Root (Binary Restoring Algorithm)
    def self.isqrt(val : Int32) : Int32
      return 0 if val <= 0
      res = 0
      bit = 1 << 30
      while bit > val
        bit >>= 2
      end
      while bit != 0
        if val >= res + bit
          val -= res + bit
          res = (res >> 1) + bit
        else
          res >>= 1
        end
        bit >>= 2
      end
      res
    end
  end
end
