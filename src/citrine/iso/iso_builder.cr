require "file_utils"
require "./elf_builder"

module Citrine
  # Constructs standard ISO9660 filesystem images (.iso) bootable on PlayStation 2 (PCSX2 or real hardware).
  # Complies with ECMA-119 specification and PS2 CD/DVD-ROM volume layouts.
  class IsoBuilder
    SECTOR_SIZE = 2048

    record IsoFile, name : String, data : Bytes, sector : UInt32, size : UInt32

    def self.build(output_path : String, cbc_bytes : Bytes, elf_bytes : Bytes? = nil, extra_files : Hash(String, Bytes) = {} of String => Bytes, input_schedule : Array(VirtualInput) = [] of VirtualInput)
      builder = new
      builder.build(output_path, cbc_bytes, elf_bytes, extra_files, input_schedule)
    end

    def build(output_path : String, cbc_bytes : Bytes, elf_bytes : Bytes? = nil, extra_files : Hash(String, Bytes) = {} of String => Bytes, input_schedule : Array(VirtualInput) = [] of VirtualInput)
      elf_data = elf_bytes || ElfBuilder.build_default_runner_elf(cbc_bytes, input_schedule)

      # Standard PS2 boot configuration
      system_cnf = "BOOT2 = cdrom0:\\CITRINE.ELF;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n".to_slice

      files = [] of IsoFile

      # Sectors:
      # 0..15  : System Area (32KB)
      # 16     : Primary Volume Descriptor (PVD)
      # 17     : Volume Descriptor Set Terminator
      # 18     : Type L Path Table
      # 19     : Type M Path Table
      # 20     : Root Directory Sector
      # 21+    : File contents

      current_sector = 21_u32

      # 1. SYSTEM.CNF
      files << IsoFile.new("SYSTEM.CNF;1", system_cnf, current_sector, system_cnf.size.to_u32)
      current_sector += ((system_cnf.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

      # 2. CITRINE.ELF
      files << IsoFile.new("CITRINE.ELF;1", elf_data, current_sector, elf_data.size.to_u32)
      current_sector += ((elf_data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

      # 3. GAME.CBC
      files << IsoFile.new("GAME.CBC;1", cbc_bytes, current_sector, cbc_bytes.size.to_u32)
      current_sector += ((cbc_bytes.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

      # 4. Extra assets
      extra_files.each do |fname, data|
        iso_name = fname.upcase.gsub(/[^A-Z0-9_\.]/, "_")
        iso_name = "#{iso_name};1" unless iso_name.includes?(";")
        files << IsoFile.new(iso_name, data, current_sector, data.size.to_u32)
        current_sector += ((data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32
      end

      total_sectors = current_sector

      # Open target ISO for writing
      File.open(output_path, "wb") do |io|
        # Sectors 0..15: System area (32768 bytes zeroes)
        (16 * SECTOR_SIZE).times { io.write_byte(0_u8) }

        # Sector 16: Primary Volume Descriptor (PVD)
        write_pvd(io, total_sectors)

        # Sector 17: Terminator
        write_terminator(io)

        # Sector 18: L-Path Table
        write_path_table_l(io)

        # Sector 19: M-Path Table
        write_path_table_m(io)

        # Sector 20: Root Directory Sector
        write_root_directory(io, files)

        # Sectors 21+: File Contents
        files.each do |f|
          io.write(f.data)
          # Pad each file to 2048-byte sector boundary
          pad = (SECTOR_SIZE - (f.data.size % SECTOR_SIZE)) % SECTOR_SIZE
          pad.times { io.write_byte(0_u8) }
        end
      end
    end

    private def write_both_endian_u32(io : IO, val : UInt32)
      io.write_bytes(val, IO::ByteFormat::LittleEndian)
      io.write_bytes(val, IO::ByteFormat::BigEndian)
    end

    private def write_both_endian_u16(io : IO, val : UInt16)
      io.write_bytes(val, IO::ByteFormat::LittleEndian)
      io.write_bytes(val, IO::ByteFormat::BigEndian)
    end

    private def write_pvd(io : IO, total_sectors : UInt32)
      pvd = IO::Memory.new(SECTOR_SIZE)
      pvd.write_byte(1_u8)               # Type 1 = PVD
      pvd.write("CD001".to_slice)        # Identifier
      pvd.write_byte(1_u8)               # Version 1
      pvd.write_byte(0_u8)               # Unused

      # System Identifier (32 bytes space-padded)
      pvd.write("PLAYSTATION".ljust(32, ' ').to_slice)

      # Volume Identifier (32 bytes space-padded)
      pvd.write("CITRINE_PS2".ljust(32, ' ').to_slice)

      8.times { pvd.write_byte(0_u8) }   # Unused

      # Volume Space Size (total sectors)
      write_both_endian_u32(pvd, total_sectors)

      32.times { pvd.write_byte(0_u8) }  # Unused

      # Volume Set Size = 1
      write_both_endian_u16(pvd, 1_u16)
      # Volume Sequence Number = 1
      write_both_endian_u16(pvd, 1_u16)
      # Logical Block Size = 2048
      write_both_endian_u16(pvd, 2048_u16)

      # Path Table Size = 10 bytes
      write_both_endian_u32(pvd, 10_u32)

      # Type L Path Table location (Sector 18)
      pvd.write_bytes(18_u32, IO::ByteFormat::LittleEndian)
      pvd.write_bytes(0_u32, IO::ByteFormat::LittleEndian) # Optional L

      # Type M Path Table location (Sector 19)
      pvd.write_bytes(19_u32, IO::ByteFormat::BigEndian)
      pvd.write_bytes(0_u32, IO::ByteFormat::BigEndian)    # Optional M

      # Root Directory Record (34 bytes)
      write_directory_record(pvd, "\0", 20_u32, 2048_u32, is_dir: true)

      # Volume Set Identifier (128 spaces)
      pvd.write("CITRINE_VOLUME_SET".ljust(128, ' ').to_slice)
      # Publisher Identifier (128 spaces)
      pvd.write("SOL-VIN CITRINE".ljust(128, ' ').to_slice)
      # Data Preparer Identifier (128 spaces)
      pvd.write("CITRINE ISO BUILDER".ljust(128, ' ').to_slice)
      # Application Identifier (128 spaces)
      pvd.write("CITRINE PLAYSTATION 2 RUNNER".ljust(128, ' ').to_slice)
      # Copyright File Identifier (37 spaces)
      pvd.write("".ljust(37, ' ').to_slice)
      # Abstract File Identifier (37 spaces)
      pvd.write("".ljust(37, ' ').to_slice)
      # Bibliographic File Identifier (37 spaces)
      pvd.write("".ljust(37, ' ').to_slice)

      # Timestamps (17 bytes: YYYYMMDDHHMMSS00 + 0)
      ts = "2026100112000000\0".to_slice
      pvd.write(ts) # Creation
      pvd.write(ts) # Modification
      pvd.write("0000000000000000\0".to_slice) # Expiration
      pvd.write(ts) # Effective

      pvd.write_byte(1_u8) # File Structure Version
      pvd.write_byte(0_u8) # Reserved

      # Pad remainder of Sector 16
      while pvd.pos < SECTOR_SIZE
        pvd.write_byte(0_u8)
      end

      io.write(pvd.to_slice)
    end

    private def write_terminator(io : IO)
      term = IO::Memory.new(SECTOR_SIZE)
      term.write_byte(255_u8)            # 255 = Terminator
      term.write("CD001".to_slice)
      term.write_byte(1_u8)
      while term.pos < SECTOR_SIZE
        term.write_byte(0_u8)
      end
      io.write(term.to_slice)
    end

    private def write_path_table_l(io : IO)
      pt = IO::Memory.new(SECTOR_SIZE)
      # Root directory entry in L-table:
      # len_di: 1
      # ext_attr_len: 0
      # loc: sector 20 (little-endian)
      # parent_dir_num: 1 (little-endian)
      # name: \0
      # padding: \0
      pt.write_byte(1_u8)
      pt.write_byte(0_u8)
      pt.write_bytes(20_u32, IO::ByteFormat::LittleEndian)
      pt.write_bytes(1_u16, IO::ByteFormat::LittleEndian)
      pt.write_byte(0_u8)
      pt.write_byte(0_u8) # 2-byte alignment padding

      while pt.pos < SECTOR_SIZE
        pt.write_byte(0_u8)
      end
      io.write(pt.to_slice)
    end

    private def write_path_table_m(io : IO)
      pt = IO::Memory.new(SECTOR_SIZE)
      # Root directory entry in M-table (big-endian):
      pt.write_byte(1_u8)
      pt.write_byte(0_u8)
      pt.write_bytes(20_u32, IO::ByteFormat::BigEndian)
      pt.write_bytes(1_u16, IO::ByteFormat::BigEndian)
      pt.write_byte(0_u8)
      pt.write_byte(0_u8) # 2-byte alignment padding

      while pt.pos < SECTOR_SIZE
        pt.write_byte(0_u8)
      end
      io.write(pt.to_slice)
    end

    private def write_root_directory(io : IO, files : Array(IsoFile))
      root = IO::Memory.new(SECTOR_SIZE)

      # 1. Current directory entry "."
      write_directory_record(root, "\0", 20_u32, 2048_u32, is_dir: true)

      # 2. Parent directory entry ".."
      write_directory_record(root, "\x01", 20_u32, 2048_u32, is_dir: true)

      # 3. File records
      files.each do |f|
        write_directory_record(root, f.name, f.sector, f.size, is_dir: false)
      end

      # Pad remainder of root directory sector
      while root.pos < SECTOR_SIZE
        root.write_byte(0_u8)
      end

      io.write(root.to_slice)
    end

    private def write_directory_record(io : IO, name : String, sector : UInt32, size : UInt32, is_dir : Bool)
      name_bytes = name.to_slice
      # Record length = 33 + name length + (1 if name length is even)
      rec_len = (33 + name_bytes.size + (name_bytes.size % 2 == 0 ? 1 : 0)).to_u8

      io.write_byte(rec_len)             # Length of Directory Record
      io.write_byte(0_u8)                # Extended Attribute Record Length
      write_both_endian_u32(io, sector)  # Location of Extent (sector)
      write_both_endian_u32(io, size)    # Data Length
      
      # Recording Date and Time: 7 bytes (Years since 1900, Month, Day, Hour, Min, Sec, GMT offset)
      io.write(Bytes[126_u8, 10_u8, 1_u8, 12_u8, 0_u8, 0_u8, 0_u8])

      # File Flags: 0x02 = Directory, 0x00 = Regular File
      io.write_byte(is_dir ? 2_u8 : 0_u8)

      io.write_byte(0_u8)                # File Unit Size
      io.write_byte(0_u8)                # Interleave Gap Size
      write_both_endian_u16(io, 1_u16)   # Volume Sequence Number

      io.write_byte(name_bytes.size.to_u8) # Length of File Identifier
      io.write(name_bytes)               # File Identifier

      # Padding byte if name length is even
      if name_bytes.size % 2 == 0
        io.write_byte(0_u8)
      end
    end
  end
end
