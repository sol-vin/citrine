# Citrine Declarative DMA & GIF Packet Builder Subsystem
# Modular hardware abstraction - require "citrine/hardware/dma"

require "./dmac"
require "./gif"
require "./gs"
require "../../../citrine/core/dma"
require "../../../citrine/dsl/dma"

module Citrine
  module Hardware
    # Exposes the Two-Tier Declarative DMA & GIF Packet Builder (`Citrine::DMA` / `Citrine::Hardware::DMA`).
    alias DMA = Citrine::DSL::DMA
  end
end
