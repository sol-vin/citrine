require "file_utils"
require "./elf_builder"
require "./sound_irx_builder"

module Citrine
  # Constructs standard ISO9660 filesystem images (.iso) bootable on PlayStation 2 (PCSX2 or real hardware).
  # Complies with ECMA-119 specification and PS2 CD/DVD-ROM volume layouts.
  class IsoBuilder
    alias SoundIrxBuilder = Citrine::ISO::SoundIrxBuilder

    SECTOR_SIZE = 2048

    record IsoFile, name : String, data : Bytes, sector : UInt32, size : UInt32

    def self.build(output_path : String, cbc_bytes : Bytes, elf_bytes : Bytes? = nil, extra_files : Hash(String, Bytes) = {} of String => Bytes, input_schedule : Array(VirtualInput) = [] of VirtualInput, audio_tracks : Array(String) = [] of String, vag_bytes : Bytes? = nil, vag_tracks : Array(Bytes) = [] of Bytes)
      builder = new
      builder.build(output_path, cbc_bytes, elf_bytes, extra_files, input_schedule, audio_tracks, vag_bytes, vag_tracks)
    end

    def build(output_path : String, cbc_bytes : Bytes, elf_bytes : Bytes? = nil, extra_files : Hash(String, Bytes) = {} of String => Bytes, input_schedule : Array(VirtualInput) = [] of VirtualInput, audio_tracks : Array(String) = [] of String, vag_bytes : Bytes? = nil, vag_tracks : Array(Bytes) = [] of Bytes)
      all_vag_tracks = if !vag_tracks.empty?
                         vag_tracks
                       else
                         vag_entries = extra_files.select { |k, _| k.downcase.ends_with?(".vag") }.to_a.sort_by do |k, _|
                           if md = k.match(/(\d+)/)
                             md[1].to_i
                           else
                             999
                           end
                         end
                         vag_entries.map(&.[1])
                       end

      cas_files = extra_files.select { |k, _| k.downcase.ends_with?(".cas") }.to_a.sort_by do |k, _|
        if md = k.match(/(\d+)/)
          md[1].to_i
        else
          999
        end
      end

      vag_files = extra_files.select { |k, _| k.downcase.ends_with?(".vag") }.to_a.sort_by do |k, _|
        if md = k.match(/(\d+)/)
          md[1].to_i
        else
          999
        end
      end

      if vag_files.empty? && cas_files.empty? && !all_vag_tracks.empty?
        all_vag_tracks.each_with_index do |tdata, idx|
          tnum = sprintf("%02d", idx + 1)
          vag_files << {"TRACK#{tnum}.VAG", tdata}
        end
      end

      non_stream_files = extra_files.reject { |k, _| k == "S.IRX" || k == "S.IRX;1" || k.downcase.ends_with?(".vag") || k.downcase.ends_with?(".cas") }.to_a

      has_custom_sirx = extra_files.has_key?("S.IRX") || extra_files.has_key?("S.IRX;1")
      use_streaming = !has_custom_sirx && (!cas_files.empty? || vag_files.size > 1 || all_vag_tracks.size > 1 || vag_files.any? { |_, d| d.size > 131072 } || all_vag_tracks.any? { |d| d.size > 131072 })

      vag_extra = vag_bytes || all_vag_tracks.first?
      elf_data = elf_bytes || ElfBuilder.build_default_runner_elf(
        cbc_bytes,
        input_schedule,
        vag_bytes: (use_streaming ? nil : vag_extra),
        vag_tracks: (use_streaming ? [] of Bytes : all_vag_tracks)
      )

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

      if use_streaming
        sec_cursor = 21_u32
        sec_system_cnf = sec_cursor
        sec_cursor += ((system_cnf.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

        sec_elf = sec_cursor
        sec_cursor += ((elf_data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

        sec_cbc = sec_cursor
        sec_cursor += ((cbc_bytes.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

        dummy_sirx = SoundIrxBuilder.build_streaming([] of SoundIrxBuilder::TrackInfo)
        s_irx_sec = ((dummy_sirx.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32
        sec_sirx = sec_cursor
        sec_cursor += s_irx_sec

        non_stream_entries = non_stream_files.map do |fname, data|
          sec = sec_cursor
          sec_cursor += ((data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32
          {fname, data, sec}
        end

        track_table = [] of SoundIrxBuilder::TrackInfo
        stream_entries = [] of Tuple(String, Bytes, UInt32)

        if !cas_files.empty?
          cas_files.each do |fname, data|
            pitch_reg = 0x075A_u16
            if data.size >= 32 && data[0, 4] == Bytes[0x43, 0x41, 0x53, 0x01] # "CAS\1"
              pitch_reg = IO::ByteFormat::LittleEndian.decode(UInt16, data[12, 2])
            end
            track_lba = sec_cursor + 1_u32 # Audio data begins at sector 1 (skipping 2048-byte header sector)
            bank_count = ((data.size - 2048) // 16384).to_u32
            track_table << SoundIrxBuilder::TrackInfo.new(track_lba, bank_count, pitch_reg)
            file_lba = sec_cursor
            sec_cursor += ((data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32
            stream_entries << {fname, data, file_lba}
          end
        else
          vag_files.each do |fname, data|
            track_lba = sec_cursor
            bank_count = (data.size // 16384).to_u32
            track_table << SoundIrxBuilder::TrackInfo.new(track_lba, bank_count, 0x0000_u16)
            sec_cursor += ((data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32
            stream_entries << {fname, data, track_lba}
          end
        end

        s_irx_bytes = SoundIrxBuilder.build_streaming(track_table)

        files << IsoFile.new("SYSTEM.CNF;1", system_cnf, sec_system_cnf, system_cnf.size.to_u32)
        files << IsoFile.new("CITRINE.ELF;1", elf_data, sec_elf, elf_data.size.to_u32)
        files << IsoFile.new("GAME.CBC;1", cbc_bytes, sec_cbc, cbc_bytes.size.to_u32)
        files << IsoFile.new("S.IRX;1", s_irx_bytes, sec_sirx, s_irx_bytes.size.to_u32)

        non_stream_entries.each do |fname, data, sec|
          iso_name = fname.upcase.gsub(/[^A-Z0-9_\.]/, "_")
          iso_name = "#{iso_name};1" unless iso_name.includes?(";")
          files << IsoFile.new(iso_name, data, sec, data.size.to_u32)
        end

        stream_entries.each do |fname, data, sec|
          iso_name = fname.upcase.gsub(/[^A-Z0-9_\.]/, "_")
          iso_name = "#{iso_name};1" unless iso_name.includes?(";")
          files << IsoFile.new(iso_name, data, sec, data.size.to_u32)
        end

        current_sector = sec_cursor
      else
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

        # 4. S.IRX (Hardware SPU2 Audio Driver)
        s_irx_bytes = extra_files["S.IRX"]? || extra_files["S.IRX;1"]? || SoundIrxBuilder.build(all_vag_tracks.empty? ? (vag_extra ? [vag_extra] : [] of Bytes) : all_vag_tracks)
        files << IsoFile.new("S.IRX;1", s_irx_bytes, current_sector, s_irx_bytes.size.to_u32)
        current_sector += ((s_irx_bytes.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32

        # 5. Extra assets
        extra_files.each do |fname, data|
          next if fname == "S.IRX" || fname == "S.IRX;1"
          iso_name = fname.upcase.gsub(/[^A-Z0-9_\.]/, "_")
          iso_name = "#{iso_name};1" unless iso_name.includes?(";")
          files << IsoFile.new(iso_name, data, current_sector, data.size.to_u32)
          current_sector += ((data.size + SECTOR_SIZE - 1) // SECTOR_SIZE).to_u32
        end
      end

      total_sectors = current_sector

      # Open target ISO for writing
      FileUtils.mkdir_p(File.dirname(output_path))
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

      # Write Mixed-Mode CUE sheet if CD-DA audio tracks are present
      if !audio_tracks.empty?
        cue_path = output_path.sub(/\.(iso|bin)$/i, ".cue")
        cue_dir = File.dirname(output_path)
        iso_base = File.basename(output_path)

        File.open(cue_path, "w") do |cue|
          cue.puts %(FILE "#{iso_base}" BINARY)
          cue.puts %(  TRACK 01 MODE1/2048)
          cue.puts %(    INDEX 01 00:00:00)

          audio_tracks.each_with_index do |track_path, idx|
            track_num = idx + 2
            track_base = File.basename(track_path)
            target_track_path = File.join(cue_dir, track_base)
            if File.expand_path(track_path) != File.expand_path(target_track_path) && File.exists?(track_path)
              FileUtils.cp(track_path, target_track_path)
            end

            cue.puts %(FILE "#{track_base}" BINARY)
            cue.puts sprintf("  TRACK %02d AUDIO", track_num)
            cue.puts %(    PREGAP 00:02:00)
            cue.puts %(    INDEX 01 00:00:00)
          end
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
