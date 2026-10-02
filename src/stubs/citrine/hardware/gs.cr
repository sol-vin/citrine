# Citrine Graphics Synthesizer (GS) Low-Level Register Subsystem
# Modular hardware abstraction - require "citrine/hardware/gs"

module Citrine
  module Hardware
    module GS
      GS_PMODE   = 0x12000000_u64
      GS_DISPFB1 = 0x12000070_u64
      GS_DISPLAY1= 0x12000080_u64
      GS_DISPFB2 = 0x12000090_u64
      GS_DISPLAY2= 0x120000a0_u64
      GS_CSR     = 0x12001000_u64

      def self.calc_vram_addr(x : Int32, y : Int32, psm : Int32 = 0) : UInt32
        # PS2 GS Framebuffer Base address calculation (pages of 2048 words)
        page_x = x // 64
        page_y = y // 32
        (page_x + page_y * 10).to_u32 * 2048_u32
      end
    end
  end
end
