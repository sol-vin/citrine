# Citrine Graphics Synthesizer (GS) Low-Level Register Subsystem
# Modular hardware abstraction - require "citrine/hardware/gs"

module Citrine
  module Hardware
    # Low-level register memory map and VRAM address utilities for the PlayStation 2 Graphics Synthesizer (GS).
    module GS
      # GS PMODE register: Pixel Mode / CRT output enable control (0x12000000).
      GS_PMODE   = 0x12000000_u64
      # GS DISPFB1 register: Display 1 Framebuffer base pointer and pixel format (0x12000070).
      GS_DISPFB1 = 0x12000070_u64
      # GS DISPLAY1 register: Display 1 CRT raster timing and screen position (0x12000080).
      GS_DISPLAY1= 0x12000080_u64
      # GS DISPFB2 register: Display 2 Framebuffer base pointer and pixel format (0x12000090).
      GS_DISPFB2 = 0x12000090_u64
      # GS DISPLAY2 register: Display 2 CRT raster timing and screen position (0x120000a0).
      GS_DISPLAY2= 0x120000a0_u64
      # GS CSR register: System status and interrupt control register (0x12001000).
      GS_CSR     = 0x12001000_u64

      # Calculates the GS VRAM byte address corresponding to pixel coordinate `(x, y)` in 4MB VRAM.
      #
      # Parameters:
      # - `x`: Pixel X coordinate.
      # - `y`: Pixel Y coordinate.
      # - `psm`: Pixel Storage Mode (default: 0 = PSMCT32 32-bit RGBA).
      def self.calc_vram_addr(x : Int32, y : Int32, psm : Int32 = 0) : UInt32
        # PS2 GS Framebuffer Base address calculation (pages of 2048 words)
        page_x = x // 64
        page_y = y // 32
        (page_x + page_y * 10).to_u32 * 2048_u32
      end
    end
  end
end
