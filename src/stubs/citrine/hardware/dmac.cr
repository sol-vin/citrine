# Citrine Direct Memory Access Controller (DMAC) Subsystem
# Modular hardware abstraction - require "citrine/hardware/dmac"

module Citrine
  module Hardware
    # PlayStation 2 10-channel high-speed Direct Memory Access Controller (DMAC) subsystem.
    module DMAC
      # DMAC Channel 0: Vector Interface 0 (VIF0 -> VU0).
      CHANNEL_VIF0 = 0
      # DMAC Channel 1: Vector Interface 1 (VIF1 -> VU1).
      CHANNEL_VIF1 = 1
      # DMAC Channel 2: Graphics Interface (GIF -> GS VRAM).
      CHANNEL_GIF  = 2
      # DMAC Channel 3: Image Processing Unit input (IPU decode).
      CHANNEL_IPU_FROM = 3
      # DMAC Channel 4: Image Processing Unit output (IPU encoded bitstream).
      CHANNEL_IPU_TO   = 4
      # DMAC Channel 5: Sub-System Interface 0 (IOP -> EE).
      CHANNEL_SIF0 = 5
      # DMAC Channel 6: Sub-System Interface 1 (EE -> IOP).
      CHANNEL_SIF1 = 6
      # DMAC Channel 7: Sub-System Interface 2 (SIF control registers).
      CHANNEL_SIF2 = 7
      # DMAC Channel 8: Scratchpad RAM read (Main RAM -> SPRAM).
      CHANNEL_SPR_FROM = 8
      # DMAC Channel 9: Scratchpad RAM write (SPRAM -> Main RAM).
      CHANNEL_SPR_TO   = 9

      # Returns the human-readable diagnostic name of the specified DMAC channel ID.
      def self.channel_name(channel_id : Int32) : String
        case channel_id
        when CHANNEL_GIF then "GIF (Channel 2)"
        when CHANNEL_VIF0 then "VIF0 (Channel 0)"
        when CHANNEL_VIF1 then "VIF1 (Channel 1)"
        when CHANNEL_SIF0 then "SIF0 (Channel 5)"
        when CHANNEL_SPR_FROM then "SPR_FROM (Channel 8)"
        when CHANNEL_SPR_TO then "SPR_TO (Channel 9)"
        else "Unknown DMAC Channel"
        end
      end
    end
  end
end
