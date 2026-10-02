# Citrine Direct Memory Access Controller (DMAC) Subsystem
# Modular hardware abstraction - require "citrine/hardware/dmac"

module Citrine
  module Hardware
    module DMAC
      CHANNEL_VIF0 = 0
      CHANNEL_VIF1 = 1
      CHANNEL_GIF  = 2
      CHANNEL_IPU_FROM = 3
      CHANNEL_IPU_TO   = 4
      CHANNEL_SIF0 = 5
      CHANNEL_SIF1 = 6
      CHANNEL_SIF2 = 7
      CHANNEL_SPR_FROM = 8
      CHANNEL_SPR_TO   = 9

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
