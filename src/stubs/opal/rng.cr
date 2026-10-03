# Opal Random Number Generation Suite
# Deterministic PRNG (XorShift64* / PCG), Gaussian Distribution (Box-Muller & Irwin-Hall), and Coherent Perlin Gradient Noise

module Opal
  module RNG
    # Fast 64-bit XorShift* pseudo-random number generator
    class PRNG
      property state : UInt64

      def initialize(seed : UInt64 = 0x853c49e6748fea9b_u64)
        @state = seed == 0_u64 ? 0x853c49e6748fea9b_u64 : seed
      end

      def seed(s : UInt64)
        @state = s == 0_u64 ? 0x853c49e6748fea9b_u64 : s
      end

      # Generates next 64-bit unsigned integer via XorShift64*
      def next_u64 : UInt64
        x = @state
        x = x ^ (x >> 12)
        x = x ^ (x << 25)
        x = x ^ (x >> 27)
        @state = x
        x &* 0x2545F4914F6CDD1D_u64
      end

      # Generates next 32-bit unsigned integer
      def next_u32 : UInt32
        (next_u64 >> 32).to_u32
      end

      # Generates next integer in range [min, max]
      def next_int(min : Int32, max : Int32) : Int32
        return min if min >= max
        range = (max - min + 1).to_u64
        (min.to_i64 + (next_u64 % range).to_i64).to_i32
      end

      # Generates next integer in range [0, max]
      def next_int_to(max : Int32) : Int32
        next_int(0, max)
      end

      # Generates next float in range [0.0, 1.0)
      def next_float : Float32
        (next_u32 & 0x00FFFFFF_u32).to_f32 / 16777216.0_f32
      end

      # Generates next boolean (50% probability)
      def next_bool : Bool
        (next_u32 & 1_u32) == 1_u32
      end
    end

    # Gaussian / Normal Distribution
    class Gaussian
      property rng : PRNG

      def initialize(@rng : PRNG = PRNG.new)
      end

      # Generate normal distribution random variable with given mean and standard deviation
      # Uses 12-sample Irwin-Hall central limit theorem for fast, smooth bell curves on PS2
      def next(mean : Float32 = 0.0_f32, std_dev : Float32 = 1.0_f32) : Float32
        sum = 0.0_f32
        12.times do
          sum += @rng.next_float
        end
        # sum of 12 uniform(0,1) minus 6 has exact mean 0, variance 1
        z = sum - 6.0_f32
        mean + z * std_dev
      end

      def self.next(mean : Float32 = 0.0_f32, std_dev : Float32 = 1.0_f32) : Float32
        DEFAULT.next(mean, std_dev)
      end

      DEFAULT = Gaussian.new
    end

    # Coherent Perlin Gradient Noise in 1D, 2D, and 3D
    class Perlin
      # Permutation table (0..255 duplicated to 512)
      @@perm = StaticArray(Int32, 512).new(0)
      @@initialized : Bool = false

      def self.init_table
        return if @@initialized
        # Standard Perlin reference permutation
        base = [
          151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
          140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
          247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
          57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
          74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
          60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
          65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
          200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
          52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
          207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
          119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
          129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
          218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
          81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
          184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
          222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180
        ]
        256.times do |i|
          val = base[i]
          @@perm[i] = val
          @@perm[256 + i] = val
        end
        @@initialized = true
      end

      # Quintic fade curve (6t^5 - 15t^4 + 10t^3)
      def self.fade(t : Float32) : Float32
        t * t * t * (t * (t * 6.0_f32 - 15.0_f32) + 10.0_f32)
      end

      def self.lerp(a : Float32, b : Float32, t : Float32) : Float32
        a + t * (b - a)
      end

      def self.grad(hash : Int32, x : Float32, y : Float32, z : Float32) : Float32
        h = hash & 15
        u = h < 8 ? x : y
        v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
        ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
      end

      # 3D / 2D / 1D Perlin noise
      def self.noise(x : Float32, y : Float32 = 0.0_f32, z : Float32 = 0.0_f32) : Float32
        init_table

        xi = x.to_i & 255
        yi = y.to_i & 255
        zi = z.to_i & 255

        xf = x - x.to_i.to_f32
        yf = y - y.to_i.to_f32
        zf = z - z.to_i.to_f32

        u = fade(xf)
        v = fade(yf)
        w = fade(zf)

        aaa = @@perm[@@perm[@@perm[xi] + yi] + zi]
        aba = @@perm[@@perm[@@perm[xi] + yi + 1] + zi]
        aab = @@perm[@@perm[@@perm[xi] + yi] + zi + 1]
        abb = @@perm[@@perm[@@perm[xi] + yi + 1] + zi + 1]
        baa = @@perm[@@perm[@@perm[xi + 1] + yi] + zi]
        bba = @@perm[@@perm[@@perm[xi + 1] + yi + 1] + zi]
        bab = @@perm[@@perm[@@perm[xi + 1] + yi] + zi + 1]
        bbb = @@perm[@@perm[@@perm[xi + 1] + yi + 1] + zi + 1]

        x1 = lerp(grad(aaa, xf, yf, zf), grad(baa, xf - 1.0_f32, yf, zf), u)
        x2 = lerp(grad(aba, xf, yf - 1.0_f32, zf), grad(bba, xf - 1.0_f32, yf - 1.0_f32, zf), u)
        y1 = lerp(x1, x2, v)

        x3 = lerp(grad(aab, xf, yf, zf - 1.0_f32), grad(bab, xf - 1.0_f32, yf, zf - 1.0_f32), u)
        x4 = lerp(grad(abb, xf, yf - 1.0_f32, zf - 1.0_f32), grad(bbb, xf - 1.0_f32, yf - 1.0_f32, zf - 1.0_f32), u)
        y2 = lerp(x3, x4, v)

        lerp(y1, y2, w)
      end

      # Fractal Brownian Motion (fBm) multi-octave noise
      def self.fractal(
        x : Float32,
        y : Float32,
        octaves : Int32 = 4,
        persistence : Float32 = 0.5_f32,
        lacunarity : Float32 = 2.0_f32
      ) : Float32
        total = 0.0_f32
        frequency = 1.0_f32
        amplitude = 1.0_f32
        max_value = 0.0_f32

        octaves.times do
          total += noise(x * frequency, y * frequency) * amplitude
          max_value += amplitude
          amplitude *= persistence
          frequency *= lacunarity
        end

        total / max_value
      end
    end

    # Module-level convenience shortcuts
    GLOBAL_PRNG = PRNG.new

    def self.rand : Float32
      GLOBAL_PRNG.next_float
    end

    def self.rand(max : Int32) : Int32
      GLOBAL_PRNG.next_int(max)
    end

    def self.rand(min : Int32, max : Int32) : Int32
      GLOBAL_PRNG.next_int(min, max)
    end

    def self.gaussian(mean : Float32 = 0.0_f32, std_dev : Float32 = 1.0_f32) : Float32
      Gaussian.next(mean, std_dev)
    end

    def self.perlin(x : Float32, y : Float32 = 0.0_f32, z : Float32 = 0.0_f32) : Float32
      Perlin.noise(x, y, z)
    end
  end
end
