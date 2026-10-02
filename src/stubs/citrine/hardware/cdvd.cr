# Citrine CDVD Subsystem & Disc Sector Streaming
# Modular hardware abstraction - require "citrine/hardware/cdvd"

module Citrine
  module Hardware
    module CDVD
      SECTOR_SIZE_STANDARD = 2048
      SECTOR_SIZE_RAW      = 2352

      def self.lba_to_bytes(lba_sector : UInt32) : UInt64
        lba_sector.to_u64 * SECTOR_SIZE_STANDARD.to_u64
      end

      def self.bytes_to_sectors(byte_count : UInt64) : UInt32
        ((byte_count + SECTOR_SIZE_STANDARD.to_u64 - 1_u64) // SECTOR_SIZE_STANDARD.to_u64).to_u32
      end
    end
  end
end
