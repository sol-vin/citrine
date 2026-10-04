# Citrine CDVD Subsystem & Disc Sector Streaming
# Modular hardware abstraction - require "citrine/hardware/cdvd"

module Citrine
  module Hardware
    # PlayStation 2 CDVD optical drive controller, sector alignment, and disc streaming helpers.
    module CDVD
      # Standard ISO-9660 / UDF data sector size in bytes (Mode 1 / 2 Form 1).
      SECTOR_SIZE_STANDARD = 2048
      # Raw optical sector size including subchannel and sync headers in bytes (Mode 2 Form 2 / CD-DA).
      SECTOR_SIZE_RAW      = 2352

      # Converts Logical Block Address (LBA) sector index to absolute byte offset on disc.
      def self.lba_to_bytes(lba_sector : UInt32) : UInt64
        lba_sector.to_u64 * SECTOR_SIZE_STANDARD.to_u64
      end

      # Computes the number of standard sectors required to contain `byte_count` bytes (rounded up).
      def self.bytes_to_sectors(byte_count : UInt64) : UInt32
        ((byte_count + SECTOR_SIZE_STANDARD.to_u64 - 1_u64) // SECTOR_SIZE_STANDARD.to_u64).to_u32
      end
    end
  end
end
