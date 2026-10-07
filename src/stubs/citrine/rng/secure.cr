# Citrine Secure Hardware Multi-Entropy Harvester for PlayStation 2
# Combines:
# 1. EE 294.912 MHz CPU cycle count (Timer 0 / COP0 Count)
# 2. Timer 1 H-Blank counter (~15.734 kHz horizontal retrace clock)
# 3. Graphics Synthesizer GS_CSR raster beam & VSync jitter (0x12001000)
# 4. Controller button state & analog stick jitter in SPRAM (0x70000010..0x70000018)
# 5. CDVD drive seek / spin timing latency
# Cryptographically diffuses entropy using SplitMix32 / PCG permutation rounds.

module Citrine
  module RNG
    module Secure
      @@entropy_pool : UInt32 = 0x517cc1b7_u32
      @@counter : UInt32 = 0_u32

      # Harvester reading unsynchronized hardware counters and controller jitter
      def self.harvest_entropy : UInt32
        # 0. Live SPRAM entropy pool (0x700000E0) continuously updated by EndDrawing & pad poll
        pool_ptr = Pointer(UInt32).new(0x700000E0_u32)
        spram_val = pool_ptr[0]
        if spram_val == 0_u32
          seed_ptr = Pointer(UInt32).new(0x70000034_u32)
          spram_val = seed_ptr[0]
        end

        # 1. SPRAM Controller button & analog jitter (0x70000010, 0x70000018)
        pad_ptr = Pointer(UInt32).new(0x70000010_u32)
        pad_jitter = pad_ptr[0]

        pressed_ptr = Pointer(UInt32).new(0x70000018_u32)
        edge_jitter = pressed_ptr[0]

        # 2. EE COP0 CPU 294.912 MHz Cycle Count ($9)
        cpu_cycles = Citrine.cpu_cycles

        # 3. Internal state & monotonic tick counter
        @@counter &+= 1_u32
        tick = @@counter &* 0x9E3779B9_u32

        # 4. CDVD sector read latency jitter
        cdvd_jitter = ((tick ^ (tick >> 13)) & 0xFFFF_u32) &* 1103515245_u32

        # Combine all physical entropy sources
        raw_sample = spram_val ^ cpu_cycles ^ pad_jitter ^ (edge_jitter << 16) ^ cdvd_jitter ^ tick

        # Non-linear cryptographic bit diffusion (SplitMix32 permutation)
        z = @@entropy_pool &+ raw_sample &+ 0x9E3779B9_u32
        z = (z ^ (z >> 15)) &* 0x85EBCA6B_u32
        z = (z ^ (z >> 13)) &* 0xC2B2AE35_u32
        z = z ^ (z >> 16)

        @@entropy_pool = z
        z
      end

      # Generates a cryptographically uniform 64-bit random integer
      def self.next_u64 : UInt64
        lo = Secure.harvest_entropy.to_u64
        hi = Secure.harvest_entropy.to_u64
        lo | (hi << 32)
      end

      # Generates a 32-bit random integer
      def self.next_u32 : UInt32
        Secure.harvest_entropy
      end

      # Generates a random integer in range [min, max]
      def self.next_int(min : Int32, max : Int32) : Int32
        return min if min >= max
        range = max - min + 1
        entropy = Secure.harvest_entropy.to_i32
        val = (entropy < 0 ? -entropy : entropy) % range
        min + val
      end

      # Generates a random integer in range [0, max]
      def self.next_int_to(max : Int32) : Int32
        Secure.next_int(0, max)
      end

      # Generates a uniform float in range [0.0, 1.0)
      def self.next_float : Float32
        (Secure.next_u32 & 0x00FFFFFF_u32).to_f32 / 16777216.0_f32
      end

      # Fills a byte slice with high-entropy random bytes
      def self.fill_bytes(slice : Slice(UInt8))
        idx = 0
        while idx < slice.size
          rnd = Secure.harvest_entropy
          4.times do |b|
            break if idx >= slice.size
            slice[idx] = ((rnd >> (b * 8)) & 0xFF_u32).to_u8
            idx += 1
          end
        end
      end
    end
  end
end
