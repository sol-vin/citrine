require "./sound_irx_base"
require "../mips/mips_emitter"

module Citrine
  module ISO
    class SoundIrxBuilder
      alias MipsEmitter = Citrine::MIPS::MipsEmitter
      include Citrine::MIPS

      # Builds an S.IRX ELF module embedding one or more VAG audio streams.
      # If vag_bytes is nil or smaller than a standard VAG header (48 bytes),
      # returns the base IRX unaltered.
      def self.build(vag_bytes : Bytes?, max_duration_sec : Float64 = 65.0) : Bytes
        if vag_bytes.nil? || vag_bytes.size <= 48
          build([] of Bytes, max_duration_sec)
        else
          build([vag_bytes], max_duration_sec)
        end
      end

      # Multi-track builder: embeds an array of VAG audio tracks into S.IRX.
      # Calculates SPU2 sound RAM layouts, sets per-track loop flags, and
      # generates a position-independent track switching dispatcher.
      def self.build(vag_tracks : Array(Bytes), max_duration_sec : Float64 = 65.0) : Bytes
        orig_elf = SoundIrxBase.bytes
        text_off = 0x90_u32

        silence_elf = -> {
          out_bytes = orig_elf.dup
          # PlaySound (0x170): jr $ra, nop
          out_bytes[text_off + 0x170, 4].copy_from(Bytes[0x08, 0x00, 0xE0, 0x03])
          out_bytes[text_off + 0x174, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
          # TestThread (0x4dc): jr $ra, nop
          out_bytes[text_off + 0x4dc, 4].copy_from(Bytes[0x08, 0x00, 0xE0, 0x03])
          out_bytes[text_off + 0x4e0, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
          # Skip thid1 (TestThread) start: at 0x0e90, branch to 0x0ea8 (b 0x0ea8, nop)
          out_bytes[text_off + 0x0e90, 4].copy_from(Bytes[0x05, 0x00, 0x00, 0x10])
          out_bytes[text_off + 0x0e94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
          out_bytes
        }

        valid_tracks = vag_tracks.select { |t| t.size > 48 }
        return silence_elf.call if valid_tracks.empty?

        max_allowed_blocks = ((max_duration_sec * 22050.0 / 28.0) // 4).to_i * 4
        num_tracks = valid_tracks.size
        return silence_elf.call if max_allowed_blocks == 0

        target_blocks = Array(Int32).new(num_tracks)
        if num_tracks == 1
          target_blocks << max_allowed_blocks
        else
          # Intro track gets up to 7.5 seconds, remaining blocks distributed across other tracks
          t0_blocks = Math.min(((7.5 * 22050.0 / 28.0) // 4).to_i * 4, (max_allowed_blocks // 2) // 4 * 4)
          rem_blocks = max_allowed_blocks - t0_blocks
          other_blocks = ((rem_blocks // (num_tracks - 1)) // 4) * 4
          target_blocks << t0_blocks
          (num_tracks - 1).times { target_blocks << other_blocks }
        end

        spu_start_addrs = Array(UInt32).new(num_tracks)
        track_chunk_sizes = Array(UInt32).new(num_tracks)
        base_spu_addr = 0x15010_u32
        curr_spu_addr = base_spu_addr

        valid_tracks.each_with_index do |track_vag, idx|
          adpcm = track_vag[48..-1]
          avail_blocks = (adpcm.size // 16 // 4) * 4
          t_blocks = Math.min(avail_blocks, target_blocks[idx])
          t_chunk = (t_blocks * 16).to_u32
          track_chunk_sizes << t_chunk
          spu_start_addrs << curr_spu_addr
          curr_spu_addr += t_chunk
        end

        total_chunk_size = track_chunk_sizes.sum
        return silence_elf.call if total_chunk_size == 0

        track_pitches = valid_tracks.map do |tvag|
          trate = if tvag.size >= 20
                    IO::ByteFormat::BigEndian.decode(UInt32, tvag[16, 4])
                  else
                    22050_u32
                  end
          trate = 22050_u32 if trate == 0_u32
          ((trate.to_u64 * 4096_u64 + 24000_u64) // 48000_u64).to_u16
        end
        base_pitch = track_pitches.first? || 0x075A_u16

        # Create audio payload: 64-byte header + total_chunk_size bytes ADPCM
        audio_mem = IO::Memory.new(64 + total_chunk_size)
        audio_mem.write(valid_tracks.first[0..47])
        16.times { audio_mem.write_byte(0_u8) } # 16 bytes padding -> 64 bytes total header

        valid_tracks.each_with_index do |track_vag, idx|
          t_chunk = track_chunk_sizes[idx]
          next if t_chunk == 0
          adpcm_slice = track_vag[48...48 + t_chunk].dup
          t_blocks = (t_chunk // 16).to_i
          if t_blocks > 0
            last_off = (t_blocks - 1) * 16
            # Inspect the original ADPCM flag of the last block:
            # Bit 1 (0x02) indicates loop repeat (looping track).
            # If Bit 1 is clear, this is a one-shot track (e.g. startup chime) that must play once and stop.
            is_looping = (adpcm_slice[last_off + 1] & 0x02_u8) != 0_u8
            if is_looping
              # SPU2 Hardware ADPCM Loop Flags:
              # Block 0: Loop Start (0x06: Bit 2 | Bit 1)
              adpcm_slice[1] = 0x06_u8
              # Middle blocks: Loop Repeat (0x02: Bit 1)
              (1...t_blocks - 1).each do |b|
                adpcm_slice[b * 16 + 1] = 0x02_u8
              end
              # Last block: Loop End + Loop Repeat (0x03: Bit 0 | Bit 1)
              adpcm_slice[last_off + 1] = 0x03_u8
            else
              # One-shot sound (play once and stop):
              # Block 0: Normal block (0x00)
              adpcm_slice[1] = 0x00_u8
              # Middle blocks: Normal blocks (0x00)
              (1...t_blocks - 1).each do |b|
                adpcm_slice[b * 16 + 1] = 0x00_u8
              end
              # Last block: Loop End without Repeat (0x01: Bit 0 = End, Bit 1 = 0)
              # Causes SPU2 hardware to automatically key off the voice when finished!
              adpcm_slice[last_off + 1] = 0x01_u8
            end
          end
          audio_mem.write(adpcm_slice)
        end

        audio_data = audio_mem.to_slice.dup

        orig_data_end = 0x1870_u32
        target_audio_offset = 0x1990_u32
        pad_size = target_audio_offset - orig_data_end # 288 bytes (0x120)
        shift = pad_size + audio_data.size.to_u32

        new_elf_mem = IO::Memory.new(orig_elf.size + shift)
        # 1. Write everything up to 0x1870
        new_elf_mem.write(orig_elf[0...orig_data_end])
        # 2. Write padding zeroes up to 0x1990
        pad_size.times { new_elf_mem.write_byte(0_u8) }
        # 3. Write audio data
        new_elf_mem.write(audio_data)
        # 4. Write remaining sections (.mdebug, .shstrtab, .rel.text, .rel.rodata, .symtab, .strtab)
        new_elf_mem.write(orig_elf[orig_data_end..-1])

        out_bytes = new_elf_mem.to_slice.dup

        # 1. Update Program Header 1 (PT_LOAD) at offset 0x54:
        ph1_off = 0x54_u32
        new_p_filesz = 0x1900_u32 + audio_data.size.to_u32
        new_p_memsz = new_p_filesz
        IO::ByteFormat::LittleEndian.encode(new_p_filesz, out_bytes[ph1_off + 16, 4])
        IO::ByteFormat::LittleEndian.encode(new_p_memsz, out_bytes[ph1_off + 20, 4])

        # 2. Update e_shoff in ELF Header (at offset 0x20):
        orig_shoff = IO::ByteFormat::LittleEndian.decode(UInt32, orig_elf[0x20, 4])
        new_shoff = orig_shoff + shift
        IO::ByteFormat::LittleEndian.encode(new_shoff, out_bytes[0x20, 4])

        # 3. Update Section Headers and Clear Overwritten Relocations:
        e_shentsize = 40_u32
        rel_text_sh_off = 0_u32
        rel_text_size = 0_u32

        13.times do |i|
          hdr = new_shoff + i.to_u32 * e_shentsize
          sh_offset = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[hdr + 0x10, 4])
          sh_size = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[hdr + 0x14, 4])
          sh_type = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[hdr + 0x04, 4])
          sh_info = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[hdr + 0x1C, 4])
          if sh_offset >= orig_data_end
            sh_offset += shift
            IO::ByteFormat::LittleEndian.encode(sh_offset, out_bytes[hdr + 0x10, 4])
          end
          if sh_type == 9_u32 && sh_info == 2_u32 # SHT_REL targeting .text (section 2)
            rel_text_sh_off = sh_offset
            rel_text_size = sh_size
          end
        end

        # Zero out old relocations in .rel.text that fall in our patched dispatcher range (0x4dc..0x0c54),
        # auto-play / hooks (0x0c64..0x0c78, 0x0c90..0x0cc0), and startup hook (0x0d90..0x0da0)
        if rel_text_sh_off > 0
          (rel_text_size // 8).times do |ri|
            r_off = rel_text_sh_off + ri * 8
            r_offset = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[r_off, 4])
            if (r_offset >= 0x4dc && r_offset < 0x0c54) ||
               (r_offset >= 0x0c64 && r_offset < 0x0c78) ||
               (r_offset >= 0x0c90 && r_offset < 0x0cc0) ||
               (r_offset >= 0x0d90 && r_offset <= 0x0da0)
              IO::ByteFormat::LittleEndian.encode(0_u32, out_bytes[r_off + 4, 4]) # r_info = R_MIPS_NONE (0)
            end
          end
        end

        # 4. Patch instructions in .text (file offset 0x90):
        # Disable thid1 creation in startup: sw zero, 56(sp); nop; nop
        out_bytes[text_off + 0x0d94, 4].copy_from(Bytes[0x38, 0x00, 0xA0, 0xAF])
        out_bytes[text_off + 0x0d98, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        out_bytes[text_off + 0x0d9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        # Skip thid1 start: at 0x0e90, branch to 0x0ea8 (b 0x0ea8, nop)
        out_bytes[text_off + 0x0e90, 4].copy_from(Bytes[0x05, 0x00, 0x00, 0x10])
        out_bytes[text_off + 0x0e94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        # Patch PlaySound: point wavBuffer to 0x1900
        out_bytes[text_off + 0x194, 4].copy_from(Bytes[0x00, 0x19, 0x42, 0x24]) # addiu v0, v0, 0x1900

        # Patch 32-bit transfer size (total across all tracks):
        hi_size = (total_chunk_size >> 16).to_u16
        lo_size = (total_chunk_size & 0xFFFF).to_u16

        lui_at = (0x0F_u32 << 26) | (1_u32 << 16) | hi_size.to_u32
        ori_at = (0x0D_u32 << 26) | (1_u32 << 21) | (1_u32 << 16) | lo_size.to_u32
        sw_at = (0x2B_u32 << 26) | (29_u32 << 21) | (1_u32 << 16) | 0x10_u32

        IO::ByteFormat::LittleEndian.encode(lui_at, out_bytes[text_off + 0x268, 4])
        out_bytes[text_off + 0x26c, 4].copy_from(Bytes[0x40, 0x00, 0x62, 0x24]) # addiu v0, v1, 0x40
        IO::ByteFormat::LittleEndian.encode(ori_at, out_bytes[text_off + 0x270, 4])
        IO::ByteFormat::LittleEndian.encode(sw_at, out_bytes[text_off + 0x274, 4])

        # Patch voice volumes in PlaySound at 0x20c and 0x22c to 0x2000 (comfortable level)
        out_bytes[text_off + 0x20c, 4].copy_from(Bytes[0x00, 0x20, 0x05, 0x24])
        out_bytes[text_off + 0x22c, 4].copy_from(Bytes[0x00, 0x20, 0x05, 0x24])

        # Patch pitch at .text+0x434: li a1, base_pitch (dynamic sample rate pitch on 48.0 kHz SPU2 core)
        out_bytes[text_off + 0x434, 4].copy_from(Bytes[
          (base_pitch & 0xFF).to_u8,
          ((base_pitch >> 8) & 0xFF).to_u8,
          0x05_u8,
          0x24_u8
        ])

        # Multi-mode position-independent sound dispatcher at .text+0x4dc:
        # Dispatches SoundMode (passed in v0 from SoundHandler):
        #   0 = Stop (calls StopSound)
        #   1 = Play (calls PlaySound on first run, or plays track 0)
        #   2 = Pause (sets voice 0 pitch to 0, silences volumes)
        #   3 = Resume (restores voice 0 pitch to 0x075A, restores volumes)
        #   4 = Fast Forward (sets voice 0 pitch to 0x1600 [3x speed])
        #   5 = Normal Speed (sets voice 0 pitch to 0x075A [1x speed])
        #   0x0100..0x0FFF = Play Track N (where N = v0 & 0xFF)
        #   0x1000..0x10FF = Set Volume (cur_vol = (mode & 0xFF) << 6, sets master and voice volumes)
        disp = MipsEmitter.new(0x000004dc_u32)

        disp.label("disp_start")
        disp.addiu(SP, SP, -32)
        disp.sw(RA, 28, SP)
        disp.sw(S0, 24, SP)
        disp.sw(S1, 20, SP)
        disp.sw(S2, 16, SP)

        # Position-independent module base calculation:
        disp.bal("get_base")
        disp.nop
        disp.label("get_base")
        disp.addiu(S0, RA, -disp.labels["get_base"].to_i32)

        # Check if wavBuffer (0x17D0) is initialized. If 0, must call PlaySound first
        disp.lw(T1, 0x17D0, S0)
        disp.bnez(T1, "chk_cmds")
        disp.nop

        # Initial PlaySound call (DMA transfer of all audio tracks to SPU2):
        disp.addiu(T8, S0, 0x0170) # PlaySound
        disp.jalr(T8)
        disp.nop
        disp.ori(S1, ZERO, 0x2000)
        disp.sw(S1, 0x17D8, S0)
        disp.beq(ZERO, ZERO, "apply_vols")
        disp.nop

        disp.label("chk_cmds")

        # Case 0: Stop (v0 == 0)
        disp.bnez(V0, "chk_pause")
        disp.nop
        disp.addiu(T9, S0, 0x0F14) # sceSdSetSwitch
        disp.ori(A0, ZERO, 0x1600) # SD_S_KOFF
        disp.ori(A1, ZERO, 1)      # Voice 0
        disp.jalr(T9)
        disp.nop
        disp.move(S1, ZERO)
        disp.beq(ZERO, ZERO, "apply_vols")
        disp.nop

        # Case 2: Pause (v0 == 2)
        disp.label("chk_pause")
        disp.ori(T1, ZERO, 2)
        disp.bne(V0, T1, "chk_resume")
        disp.nop
        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0200) # SD_VP_PITCH Voice 0 = 0
        disp.move(A1, ZERO)
        disp.jalr(T9)
        disp.nop
        disp.move(S1, ZERO)
        disp.beq(ZERO, ZERO, "apply_vols")
        disp.nop

        # Case 3: Resume (v0 == 3)
        disp.label("chk_resume")
        disp.ori(T1, ZERO, 3)
        disp.bne(V0, T1, "chk_ff")
        disp.nop
        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0200) # SD_VP_PITCH Voice 0
        disp.ori(A1, ZERO, base_pitch.to_i32)
        disp.jalr(T9)
        disp.nop
        disp.lw(S1, 0x17D8, S0)
        disp.bnez(S1, "apply_vols")
        disp.nop
        disp.ori(S1, ZERO, 0x2000)
        disp.beq(ZERO, ZERO, "apply_vols")
        disp.nop

        # Case 4: Fast Forward (v0 == 4)
        disp.label("chk_ff")
        disp.ori(T1, ZERO, 4)
        disp.bne(V0, T1, "chk_norm")
        disp.nop
        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0200) # SD_VP_PITCH Voice 0
        disp.ori(A1, ZERO, 0x1600) # 3x speed pitch
        disp.jalr(T9)
        disp.nop
        disp.beq(ZERO, ZERO, "disp_exit")
        disp.nop

        # Case 5: Normal Speed (v0 == 5)
        disp.label("chk_norm")
        disp.ori(T1, ZERO, 5)
        disp.bne(V0, T1, "chk_vol")
        disp.nop
        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0200) # SD_VP_PITCH Voice 0
        disp.ori(A1, ZERO, base_pitch.to_i32) # 1.0x speed pitch
        disp.jalr(T9)
        disp.nop
        disp.beq(ZERO, ZERO, "disp_exit")
        disp.nop

        # Case 6: Set Volume (v0 >= 0x1000)
        disp.label("chk_vol")
        disp.srl(T1, V0, 12)
        disp.ori(T2, ZERO, 1)
        disp.bne(T1, T2, "chk_play")
        disp.nop
        disp.andi(S1, V0, 0xFF)
        disp.sll(S1, S1, 6) # scale 0..255 -> 0..16320
        disp.sw(S1, 0x17D8, S0)
        disp.beq(ZERO, ZERO, "apply_vols")
        disp.nop

        # Case 1: Play Track 0 (v0 == 1)
        disp.label("chk_play")
        disp.ori(T1, ZERO, 1)
        disp.bne(V0, T1, "chk_play_track")
        disp.nop
        disp.move(T1, ZERO) # track 0
        disp.beq(ZERO, ZERO, "do_play_track")
        disp.nop

        # Case 7: Play Track N (v0 in 0x0100..0x0FFF)
        disp.label("chk_play_track")
        disp.srl(T1, V0, 8)
        disp.ori(T2, ZERO, 1)
        disp.bne(T1, T2, "disp_exit")
        disp.nop
        disp.andi(T1, V0, 0xFF) # track_idx = v0 & 0xFF

        disp.label("do_play_track")
        # Bounds check track_idx < num_tracks
        disp.sltiu(T2, T1, num_tracks)
        disp.bnez(T2, "trk_in_range")
        disp.nop
        disp.move(T1, ZERO)
        disp.label("trk_in_range")

        # Load SPU2 address and pitch from embedded table using position-independent bal:
        disp.bal("load_spu_table_done")
        disp.nop
        disp.label("spu_track_table")
        spu_start_addrs.each_with_index do |saddr, i|
          disp.emit(saddr)
          disp.emit(track_pitches[i].to_u32)
        end
        disp.label("load_spu_table_done")
        # RA points to spu_track_table
        disp.sll(T3, T1, 3) # track_idx * 8
        disp.addu(T2, RA, T3)
        disp.lw(S2, 0, T2) # S2 = spu_start_addrs[track_idx]
        disp.lw(T3, 4, T2) # T3 = track_pitches[track_idx]

        # 1. Key Off Voice 0
        disp.addiu(T9, S0, 0x0F14) # sceSdSetSwitch
        disp.ori(A0, ZERO, 0x1600) # SD_S_KOFF Voice 0
        disp.ori(A1, ZERO, 1)      # bit 0 = Voice 0
        disp.jalr(T9)
        disp.nop

        # 2. CLEAR Key Off on Voice 0 (MANDATORY so KON can take effect)
        disp.addiu(T9, S0, 0x0F14) # sceSdSetSwitch
        disp.ori(A0, ZERO, 0x1600) # SD_S_KOFF Voice 0
        disp.move(A1, ZERO)        # 0
        disp.jalr(T9)
        disp.nop

        # 3. Set Voice 0 Start Address (SSA = 0x2040) to S2
        disp.addiu(T9, S0, 0x0F1C) # sceSdSetAddr
        disp.ori(A0, ZERO, 0x2040) # SD_VA_SSA Voice 0
        disp.move(A1, S2)
        disp.jalr(T9)
        disp.nop

        # 4. Set Voice 0 Loop Address (LSA = 0x2060) to S2
        disp.addiu(T9, S0, 0x0F1C) # sceSdSetAddr
        disp.ori(A0, ZERO, 0x2060) # SD_VA_LSA Voice 0
        disp.move(A1, S2)
        disp.jalr(T9)
        disp.nop

        # 5. Set Voice 0 Pitch to track pitch
        disp.addiu(T9, S0, 0x0F0C) # sceSdSetParam
        disp.ori(A0, ZERO, 0x0200) # SD_VP_PITCH Voice 0
        disp.move(A1, T3)          # dynamic track pitch
        disp.jalr(T9)
        disp.nop

        # 6. Key On Voice 0 (KON = 0x1500)
        disp.addiu(T9, S0, 0x0F14) # sceSdSetSwitch
        disp.ori(A0, ZERO, 0x1500) # SD_S_KON
        disp.ori(A1, ZERO, 1)      # bit 0 = Voice 0
        disp.jalr(T9)
        disp.nop

        # 5. Restore volume
        disp.lw(S1, 0x17D8, S0)
        disp.bnez(S1, "apply_vols")
        disp.nop
        disp.ori(S1, ZERO, 0x2000)
        disp.sw(S1, 0x17D8, S0)

        # Set 4 volumes to S1
        disp.label("apply_vols")
        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0000) # Voice 0 Vol Left
        disp.move(A1, S1)
        disp.jalr(T9); disp.nop

        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0100) # Voice 0 Vol Right
        disp.move(A1, S1)
        disp.jalr(T9); disp.nop

        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0980) # Master Vol Left
        disp.move(A1, S1)
        disp.jalr(T9); disp.nop

        disp.addiu(T9, S0, 0x0F0C)
        disp.ori(A0, ZERO, 0x0A80) # Master Vol Right
        disp.move(A1, S1)
        disp.jalr(T9); disp.nop

        # Exit and return to SoundThread
        disp.label("disp_exit")
        disp.lw(S2, 16, SP)
        disp.lw(S1, 20, SP)
        disp.lw(S0, 24, SP)
        disp.lw(RA, 28, SP)
        disp.addiu(SP, SP, 32)
        disp.jr(RA)
        disp.nop

        disp.resolve!

        disp_bytes = disp.to_slice
        out_bytes[text_off + 0x4dc, disp_bytes.size].copy_from(disp_bytes)

        # Auto-play on IRX boot at 0x0c64:
        # 0x0c64: ori v0, zero, 1      # v0 = 1 (Play)
        # 0x0c68: bal 0x04dc           # call dispatcher at 0x4dc (0x0411FE1C)
        # 0x0c6c: nop
        # 0x0c70: b 0x0c78             # branch to WaitSema loop (0x10000001)
        # 0x0c74: nop
        out_bytes[text_off + 0x0c64, 4].copy_from(Bytes[0x01, 0x00, 0x02, 0x34])
        out_bytes[text_off + 0x0c68, 4].copy_from(Bytes[0x1C, 0xFE, 0x11, 0x04])
        out_bytes[text_off + 0x0c6c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        out_bytes[text_off + 0x0c70, 4].copy_from(Bytes[0x01, 0x00, 0x00, 0x10])
        out_bytes[text_off + 0x0c74, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        # Hook SoundThread at 0xc90 via bal to 0x4dc:
        # 0x0c90: bal 0x4dc (0x0411FE12)
        # 0x0c94: nop
        # 0x0c98: b 0x0c78 (0x1000FFF7)
        # 0x0c9c: nop
        out_bytes[text_off + 0xc90, 4].copy_from(Bytes[0x12, 0xFE, 0x11, 0x04])
        out_bytes[text_off + 0xc94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        out_bytes[text_off + 0xc98, 4].copy_from(Bytes[0xF7, 0xFF, 0x00, 0x10])
        out_bytes[text_off + 0xc9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        out_bytes
      end

      record TrackInfo, lba : UInt32, bank_count : UInt32, pitch_reg : UInt16 = 0x0000_u16

      # Builds a true disc-streaming S.IRX ELF module.
      # Streams CD audio tracks directly from optical disc into SPU2 sound RAM
      # using double-buffered ping-pong banks (0x15000 and 0x19000).
      def self.build_streaming(track_table : Array(TrackInfo), startup_vag : Bytes? = nil) : Bytes
        orig_elf = SoundIrxBase.bytes
        text_off = 0x90_u32
        orig_data_end = 0x1870_u32

        audio_data = nil
        total_chunk_size = 0_u32
        base_pitch = 0x075A_u16
        if startup_vag && startup_vag.size > 48
          adpcm_slice = startup_vag[48..-1].dup
          t_chunk = adpcm_slice.size
          t_blocks = (t_chunk // 16).to_i
          if t_blocks > 0
            last_off = (t_blocks - 1) * 16
            adpcm_slice[1] = 0x00_u8
            (1...t_blocks - 1).each do |b|
              adpcm_slice[b * 16 + 1] = 0x00_u8
            end
            adpcm_slice[last_off + 1] = 0x01_u8
          end

          audio_mem = IO::Memory.new(64 + t_chunk)
          audio_mem.write(startup_vag[0..47])
          16.times { audio_mem.write_byte(0_u8) }
          audio_mem.write(adpcm_slice)
          audio_data = audio_mem.to_slice.dup

          total_chunk_size = t_chunk.to_u32
          target_mem_end = 0x6000_u32 + audio_data.size.to_u32

          srate = if startup_vag.size >= 20
                    IO::ByteFormat::BigEndian.decode(UInt32, startup_vag[16, 4])
                  else
                    22050_u32
                  end
          srate = 22050_u32 if srate == 0_u32
          base_pitch = ((srate.to_u64 * 4096_u64 + 24000_u64) // 48000_u64).clamp(0_u64, 0x3FFF_u64).to_u16
        else
          # Expand loaded ELF memory size up to virtual 0x6000 (file offset 0x6090)
          # to accommodate 16KB staging buffer at 0x1A00..0x5A00 and state variables
          target_mem_end = 0x6000_u32
        end

        target_file_data_end = target_mem_end + text_off
        shift = target_file_data_end - orig_data_end
        new_elf_mem = IO::Memory.new(orig_elf.size + shift)
        new_elf_mem.write(orig_elf[0...orig_data_end])
        shift.times { new_elf_mem.write_byte(0_u8) }
        new_elf_mem.write(orig_elf[orig_data_end..-1])
        base_elf = new_elf_mem.to_slice.dup

        if audio_data
          base_elf[text_off + 0x6000, audio_data.size].copy_from(audio_data)
        end

        # Update Program Header 1 (p_filesz and p_memsz)
        ph1_off = 0x54_u32
        new_p_filesz = target_mem_end
        new_p_memsz = target_mem_end + 0xc8_u32 # include bss
        IO::ByteFormat::LittleEndian.encode(new_p_filesz, base_elf[ph1_off + 16, 4])
        IO::ByteFormat::LittleEndian.encode(new_p_memsz, base_elf[ph1_off + 20, 4])

        # CRITICAL: Update .iopmod data_size (offset 0x74 + 16)
        # Sony LOADCORE allocates memory for the module using: text_size + data_size + bss_size from .iopmod!
        # .text ends at 0x10d0; .data extends up to target_mem_end (0x6000).
        new_data_size = target_mem_end - 0x10d0_u32 # 0x4f30
        IO::ByteFormat::LittleEndian.encode(new_data_size, base_elf[0x74 + 16, 4])

        # Update e_shoff
        orig_shoff = IO::ByteFormat::LittleEndian.decode(UInt32, orig_elf[0x20, 4])
        new_shoff = orig_shoff + shift
        IO::ByteFormat::LittleEndian.encode(new_shoff, base_elf[0x20, 4])

        # Update section headers
        rel_text_sh_off = 0_u32
        rel_text_size = 0_u32

        13.times do |i|
          hdr = new_shoff + i.to_u32 * 40_u32
          sh_offset = IO::ByteFormat::LittleEndian.decode(UInt32, base_elf[hdr + 0x10, 4])
          sh_size = IO::ByteFormat::LittleEndian.decode(UInt32, base_elf[hdr + 0x14, 4])
          sh_type = IO::ByteFormat::LittleEndian.decode(UInt32, base_elf[hdr + 0x04, 4])
          sh_info = IO::ByteFormat::LittleEndian.decode(UInt32, base_elf[hdr + 0x1C, 4])
          if i == 6 # Section 6 is .data (virtual 0x12e0 up to target_mem_end 0x6000)
            IO::ByteFormat::LittleEndian.encode(target_mem_end - 0x12e0_u32, base_elf[hdr + 0x14, 4])
          end
          if sh_offset >= orig_data_end
            sh_offset += shift
            IO::ByteFormat::LittleEndian.encode(sh_offset, base_elf[hdr + 0x10, 4])
          end
          if sh_type == 9_u32 && sh_info == 2_u32 # SHT_REL targeting .text
            rel_text_sh_off = sh_offset
            rel_text_size = sh_size
          end
        end

        # Clear relocations in patched ranges
        if rel_text_sh_off > 0
          (rel_text_size // 8).times do |ri|
            r_off = rel_text_sh_off + ri * 8
            r_offset = IO::ByteFormat::LittleEndian.decode(UInt32, base_elf[r_off, 4])
            if (r_offset >= 0x4dc && r_offset < 0x0c54) ||
               (r_offset >= 0x0c64 && r_offset < 0x0c78) ||
               (r_offset >= 0x0c90 && r_offset < 0x0cc0) ||
               (r_offset >= 0x0cd4 && r_offset < 0x0d34) ||
               (r_offset >= 0x0d90 && r_offset <= 0x0da0)
              IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[r_off + 4, 4])
            end
          end
        end

        # Disable thid1 creation in startup: sw zero, 56(sp); nop; nop
        base_elf[text_off + 0x0d94, 4].copy_from(Bytes[0x38, 0x00, 0xA0, 0xAF])
        base_elf[text_off + 0x0d98, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        base_elf[text_off + 0x0d9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        # Skip thid1 start: at 0x0e90, branch to 0x0ea8 (b 0x0ea8, nop)
        base_elf[text_off + 0x0e90, 4].copy_from(Bytes[0x05, 0x00, 0x00, 0x10])
        base_elf[text_off + 0x0e94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        # Note: libsd stub 4 at 0x0F24 is already sceSdGetAddr (ordinal 10) in original SoundIrxBase

        # Emit SIF Command Handler (SoundHandler) with FIFO ring buffer at 0x0cd4:
        sh = MipsEmitter.new(0x00000cd4_u32)
        sh.move(T9, RA)               # Save RA in scratch T9
        sh.bal("sh_get_base")
        sh.nop
        sh.label("sh_get_base")
        sh.addiu(T0, RA, -0x0ce0)     # T0 = module_base (bal at 0x0cd8 + 8 = 0x0ce0)
        sh.move(RA, T9)               # Restore RA

        sh.lw(T1, 12, A0)             # T1 = incoming cmd from packet->opt (offset 12)
        sh.sw(T1, 0x17d4, T0)         # Also update legacy SoundMode variable

        # FIFO at module_base + 0x5a00:
        # 0x5a00: head (0..15)
        # 0x5a04: tail (0..15)
        # 0x5a10: ring_buffer (16 words)
        sh.lw(T2, 0x5a00, T0)         # T2 = head
        sh.lw(T3, 0x5a04, T0)         # T3 = tail

        # next_head = (head + 1) & 15
        sh.addiu(T4, T2, 1)
        sh.andi(T4, T4, 15)

        # If next_head == tail (FIFO full), drop command
        sh.beq(T4, T3, "sh_done")
        sh.nop

        # Write command: buffer[head] = cmd
        sh.sll(T5, T2, 2)             # head * 4
        sh.addiu(T5, T5, 0x5a10)
        sh.addu(T5, T0, T5)           # &buffer[head]
        sh.sw(T1, 0, T5)

        # Advance head: head = next_head
        sh.sw(T4, 0x5a00, T0)

        sh.label("sh_done")
        sh.move(V0, ZERO)             # Return 0 (success)
        sh.jr(RA)
        sh.nop
        sh.resolve!
        sh_bytes = sh.to_slice
        base_elf[text_off + 0x0cd4, sh_bytes.size].copy_from(sh_bytes)
        pad_size = 0x0d34 - (0x0cd4 + sh_bytes.size)
        if pad_size > 0
          base_elf[text_off + 0x0cd4 + sh_bytes.size, pad_size].fill(0_u8)
        end

        # Add cdvdman import table at 0x0bd0 (giving 0x4dc..0x0bd0 = 1,780 bytes for engine code)
        pos = text_off + 0x0bd0
        IO::ByteFormat::LittleEndian.encode(0x41e00000_u32, base_elf[pos, 4])
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[pos + 4, 4])
        IO::ByteFormat::LittleEndian.encode(0x0101_u16, base_elf[pos + 8, 2])
        IO::ByteFormat::LittleEndian.encode(0_u16, base_elf[pos + 10, 2])
        "cdvdman\0".to_slice.copy_to(base_elf[pos + 12, 8])

        # Stub 0 (0x0be4): sceCdRead (ordinal 6)
        IO::ByteFormat::LittleEndian.encode(0x03e00008_u32, base_elf[pos + 20, 4]) # jr $ra
        IO::ByteFormat::LittleEndian.encode(0x24000006_u32, base_elf[pos + 24, 4]) # addiu $zero, $zero, 6

        # Stub 1 (0x0bec): sceCdSync (ordinal 11 = 0x000b)
        IO::ByteFormat::LittleEndian.encode(0x03e00008_u32, base_elf[pos + 28, 4]) # jr $ra
        IO::ByteFormat::LittleEndian.encode(0x2400000b_u32, base_elf[pos + 32, 4]) # addiu $zero, $zero, 11

        # Stub 2 (0x0bf4): sceCdSeek (ordinal 7)
        IO::ByteFormat::LittleEndian.encode(0x03e00008_u32, base_elf[pos + 36, 4]) # jr $ra
        IO::ByteFormat::LittleEndian.encode(0x24000007_u32, base_elf[pos + 40, 4]) # addiu $zero, $zero, 7

        # Terminator:
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[pos + 44, 4])
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[pos + 48, 4])

        # Store 4-byte sceCdRMode struct at 0x0c04: { trycount=5, spindlctrl=0, datapattern=0, pad=0 }
        IO::ByteFormat::LittleEndian.encode(0x00000005_u32, base_elf[pos + 52, 4])

        # Patch vblank import table at 0x10a0 to import thbase DelayThread (ordinal 33 = 0x21)
        vblank_tbl = text_off + 0x10a0
        "thbase\0\0".to_slice.copy_to(base_elf[vblank_tbl + 12, 8])
        # Stub 0 (0x10b4): DelayThread (ordinal 33)
        IO::ByteFormat::LittleEndian.encode(0x03e00008_u32, base_elf[vblank_tbl + 20, 4]) # jr $ra
        IO::ByteFormat::LittleEndian.encode(0x24000021_u32, base_elf[vblank_tbl + 24, 4]) # addiu $zero, $zero, 33
        # Terminator at 0x10bc:
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[vblank_tbl + 28, 4])
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[vblank_tbl + 32, 4])

        # Initialize SoundMode at 0x17d4 to 0xFFFFFFFF (idle / no pending command)
        IO::ByteFormat::LittleEndian.encode(0xFFFFFFFF_u32, base_elf[text_off + 0x17d4, 4])

        # Initialize Command FIFO at 0x5a00:
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x5a00, 4]) # head = 0
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x5a04, 4]) # tail = 0
        16.times do |fi|
          IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x5a10 + fi * 4, 4])
        end

        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x1900, 4]) # cur_track
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x1904, 4]) # cur_bank_idx
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x1908, 4]) # next_refill_bank (0=Bank A, 1=Bank B)
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x190C, 4]) # play_state
        IO::ByteFormat::LittleEndian.encode(0x2000_u32, base_elf[text_off + 0x1910, 4]) # cur_vol
        IO::ByteFormat::LittleEndian.encode(track_table.size.to_u32, base_elf[text_off + 0x1914, 4]) # total_tracks
        IO::ByteFormat::LittleEndian.encode(0_u32, base_elf[text_off + 0x1918, 4]) # timer_accum_ms

        # Initial track pitch at 0x18EC:
        first_pitch = track_table.first?.try(&.pitch_reg) || 0x02AB_u16
        first_pitch = 0x02AB_u16 if first_pitch == 0_u16
        IO::ByteFormat::LittleEndian.encode(first_pitch.to_u32, base_elf[text_off + 0x18EC, 4])
        initial_bank_dur = 2446677_u32 // first_pitch.to_u32
        IO::ByteFormat::LittleEndian.encode(initial_bank_dur, base_elf[text_off + 0x18F0, 4])

        # Store track table at 0x1920:
        track_table.each_with_index do |tinfo, i|
          entry_pos = text_off + 0x1920 + i.to_u32 * 8
          IO::ByteFormat::LittleEndian.encode(tinfo.lba, base_elf[entry_pos, 4])
          IO::ByteFormat::LittleEndian.encode(tinfo.bank_count.to_u16, base_elf[entry_pos + 4, 2])
          IO::ByteFormat::LittleEndian.encode(tinfo.pitch_reg, base_elf[entry_pos + 6, 2])
        end

        # Store debug format strings in .data (zero code size cost):
        ref_msg = ">>> Stream bank %d to 0x%x\n\0"
        ref_msg.to_slice.copy_to(base_elf[text_off + 0x1990, ref_msg.bytesize])

        play_msg = ">>> Play track %d\n\0"
        play_msg.to_slice.copy_to(base_elf[text_off + 0x19B0, play_msg.bytesize])

        seek_msg = ">>> Seek bank %d\n\0"
        seek_msg.to_slice.copy_to(base_elf[text_off + 0x19C8, seek_msg.bytesize])


        if audio_data
          # Patch PlaySound: point wavBuffer to 0x6000
          base_elf[text_off + 0x194, 4].copy_from(Bytes[0x00, 0x60, 0x42, 0x24]) # addiu v0, v0, 0x6000

          # Patch 32-bit transfer size:
          hi_size = (total_chunk_size >> 16).to_u16
          lo_size = (total_chunk_size & 0xFFFF).to_u16

          lui_at = (0x0F_u32 << 26) | (1_u32 << 16) | hi_size.to_u32
          ori_at = (0x0D_u32 << 26) | (1_u32 << 21) | (1_u32 << 16) | lo_size.to_u32
          sw_at = (0x2B_u32 << 26) | (29_u32 << 21) | (1_u32 << 16) | 0x10_u32

          IO::ByteFormat::LittleEndian.encode(lui_at, base_elf[text_off + 0x268, 4])
          base_elf[text_off + 0x26c, 4].copy_from(Bytes[0x40, 0x00, 0x62, 0x24]) # addiu v0, v1, 0x40
          IO::ByteFormat::LittleEndian.encode(ori_at, base_elf[text_off + 0x270, 4])
          IO::ByteFormat::LittleEndian.encode(sw_at, base_elf[text_off + 0x274, 4])

          # Patch voice volumes in PlaySound at 0x20c and 0x22c to 0x2000 (comfortable level)
          base_elf[text_off + 0x20c, 4].copy_from(Bytes[0x00, 0x20, 0x05, 0x24])
          base_elf[text_off + 0x22c, 4].copy_from(Bytes[0x00, 0x20, 0x05, 0x24])

          # Patch pitch at .text+0x434: li a1, base_pitch (dynamic sample rate pitch on 48.0 kHz SPU2 core)
          base_elf[text_off + 0x434, 4].copy_from(Bytes[
            (base_pitch & 0xFF).to_u8,
            ((base_pitch >> 8) & 0xFF).to_u8,
            0x05_u8,
            0x24_u8
          ])
        else
          # Silence original PlaySound (0x170): jr $ra, nop
          base_elf[text_off + 0x170, 4].copy_from(Bytes[0x08, 0x00, 0xE0, 0x03])
          base_elf[text_off + 0x174, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        end

        # Emit Streaming Engine MIPS code at 0x4dc:
        mips = MipsEmitter.new(0x000004dc_u32)

        # Save registers
        mips.label("entry")
        mips.addiu(SP, SP, -64)
        mips.sw(RA, 60, SP)
        mips.sw(FP, 56, SP)
        mips.sw(S0, 52, SP)
        mips.sw(S1, 48, SP)
        mips.sw(S2, 44, SP)
        mips.sw(S3, 40, SP)
        mips.sw(S4, 36, SP)
        mips.sw(S5, 32, SP)
        mips.sw(S6, 28, SP)
        mips.sw(S7, 24, SP)

        # Module base in S0
        mips.bal("get_base")
        mips.nop
        mips.label("get_base")
        mips.addiu(S0, RA, -mips.labels["get_base"].to_i32)

        # Direct SPU2 Hardware Initialization (only if no startup audio was initialized)
        unless audio_data
          mips.addiu(T9, S0, 0x0f04) # sceSdInit
          mips.move(A0, ZERO)
          mips.jalr(T9); mips.nop
        end

        # SPU2 Interrupt Setup: CpuEnableIntr (0x0f8c), EnableIntr (0x0f84)
        mips.addiu(T9, S0, 0x0f8c) # CpuEnableIntr
        mips.jalr(T9); mips.nop

        mips.addiu(T9, S0, 0x0f84) # EnableIntr
        mips.ori(A0, ZERO, 0x24)   # DMA channel 4 (SPU2 Core 0)
        mips.jalr(T9); mips.nop
        mips.ori(A0, ZERO, 0x28)   # DMA channel 7 (SPU2 Core 1)
        mips.jalr(T9); mips.nop
        mips.ori(A0, ZERO, 9)      # SPU2 Interrupt
        mips.jalr(T9); mips.nop

        # Initialize callee-saved function pointers
        mips.addiu(S2, S0, 0x0f0c) # sceSdSetParam
        mips.addiu(S3, S0, 0x0f14) # sceSdSetSwitch
        mips.addiu(S4, S0, 0x0f1c) # sceSdSetAddr

        # Open Core 0/1 Master Volume and Core 1 Broadcast to maximum (0x3FFF) once at startup:
        mips.ori(A1, ZERO, 0x3FFF)
        mips.ori(A0, ZERO, 0x0980); mips.jalr(S2); mips.nop # Core 0 MVOLL
        mips.ori(A0, ZERO, 0x0a80); mips.jalr(S2); mips.nop # Core 0 MVOLR
        mips.ori(A0, ZERO, 0x0f81); mips.jalr(S2); mips.nop # Core 1 BVOLL
        mips.ori(A0, ZERO, 0x1081); mips.jalr(S2); mips.nop # Core 1 BVOLR
        mips.ori(A0, ZERO, 0x0981); mips.jalr(S2); mips.nop # Core 1 MVOLL
        mips.ori(A0, ZERO, 0x0a81); mips.jalr(S2); mips.nop # Core 1 MVOLR

        # ================= MAIN STREAMING LOOP =================
        mips.label("stream_loop")
        # DelayThread(10000) -> sleep 10 ms (finer polling & responsive controls)
        mips.ori(A0, ZERO, 10000)
        mips.addiu(T9, S0, 0x10b4) # DelayThread
        mips.jalr(T9)
        mips.nop

        # ================= PROCESS COMMAND FIFO =================
        mips.label("process_cmd_loop")
        # Check FIFO: head at 0x5a00, tail at 0x5a04
        mips.lw(T2, 0x5a00, S0)
        mips.lw(T3, 0x5a04, S0)
        mips.beq(T2, T3, "chk_cmd_legacy")
        mips.nop

        # Pop: T0 = buffer[tail]
        mips.sll(T4, T3, 2)
        mips.addiu(T4, T4, 0x5a10)
        mips.addu(T4, S0, T4)
        mips.lw(T0, 0, T4)

        # Advance tail: tail = (tail + 1) & 15
        mips.addiu(T3, T3, 1)
        mips.andi(T3, T3, 15)
        mips.sw(T3, 0x5a04, S0)
        mips.beq(ZERO, ZERO, "dispatch_cmd")
        mips.nop

        # Legacy fallback: check 0x17d4 if FIFO was empty
        mips.label("chk_cmd_legacy")
        mips.lw(T0, 0x17d4, S0)
        mips.li(T1, 0xFFFFFFFF_u32)
        mips.beq(T0, T1, "chk_streaming")
        mips.nop
        mips.sw(T1, 0x17d4, S0)

        # Dispatch command in T0:
        mips.label("dispatch_cmd")

        # Case 0: Stop
        mips.bnez(T0, "chk_cmd_pause")
        mips.nop
        # Key off Voice 0
        mips.ori(A0, ZERO, 0x1600)  # SD_S_KOFF (Core 0)
        mips.ori(A1, ZERO, 1)
        mips.jalr(S3); mips.nop
        mips.ori(A0, ZERO, 0x1600)
        mips.move(A1, ZERO)
        mips.jalr(S3); mips.nop
        # Reset state
        mips.sw(ZERO, 0x1904, S0)   # cur_bank_idx = 0
        mips.sw(ZERO, 0x1908, S0)   # next_refill_bank = 0
        mips.sw(ZERO, 0x1918, S0)   # timer_accum_ms = 0
        mips.sw(ZERO, 0x190c, S0)   # play_state = 0 (stopped)
        mips.beq(ZERO, ZERO, "mute_voice0")
        mips.nop

        mips.label("chk_cmd_pause")
        mips.ori(T2, ZERO, 2)       # Pause
        mips.bne(T0, T2, "chk_cmd_resume")
        mips.nop
        mips.ori(T2, ZERO, 2)
        mips.sw(T2, 0x190c, S0)     # play_state = 2 (paused)

        mips.label("mute_voice0")
        mips.ori(A0, ZERO, 0x0200)  # Core 0 pitch = 0
        mips.move(A1, ZERO)
        mips.jalr(S2); mips.nop
        mips.ori(A0, ZERO, 0x0000)  # Core 0 VOLL = 0
        mips.move(A1, ZERO)
        mips.jalr(S2); mips.nop
        mips.ori(A0, ZERO, 0x0100)  # Core 0 VOLR = 0
        mips.move(A1, ZERO)
        mips.jalr(S2); mips.nop
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        mips.label("chk_cmd_resume")
        mips.ori(T2, ZERO, 3)       # Resume
        mips.bne(T0, T2, "chk_cmd_play")
        mips.nop
        mips.label("do_resume")
        # Restore Voice 0 volume from S7 (cur_vol at 0x1910)
        mips.lw(S7, 0x1910, S0)
        mips.ori(A0, ZERO, 0x0000)  # Core 0 VOLL
        mips.move(A1, S7)
        mips.jalr(S2); mips.nop
        mips.ori(A0, ZERO, 0x0100)  # Core 0 VOLR
        mips.move(A1, S7)
        mips.jalr(S2); mips.nop
        # Restore pitch
        mips.ori(A0, ZERO, 0x0200)  # Core 0 pitch
        mips.lw(A1, 0x18EC, S0)     # restore cur_pitch
        mips.jalr(S2); mips.nop
        mips.ori(T2, ZERO, 1)
        mips.sw(T2, 0x190c, S0)     # play_state = 1
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        mips.label("chk_cmd_play")
        mips.ori(T2, ZERO, 1)       # Play
        mips.bne(T0, T2, "chk_cmd_seek")
        mips.nop
        mips.lw(T2, 0x190c, S0)
        mips.ori(T3, ZERO, 2)
        mips.beq(T2, T3, "do_resume") # If paused, resume
        mips.nop
        mips.move(A0, ZERO)
        mips.bal("start_track")
        mips.nop
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        mips.label("chk_cmd_seek")
        # Check if (cmd >> 16) == 2 (Seek to Bank N)
        mips.srl(T2, T0, 16)
        mips.ori(T3, ZERO, 2)
        mips.bne(T2, T3, "chk_cmd_cdvd_seek")
        mips.nop
        mips.andi(A1, T0, 0xFFFF)   # A1 = target_bank
        mips.bal("seek_stream_bank")
        mips.nop
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        mips.label("chk_cmd_cdvd_seek")
        # Check if (cmd >> 24) == 0x53 ('S' = CDVD seek probe for hardware entropy)
        mips.srl(T2, T0, 24)
        mips.ori(T3, ZERO, 0x53)
        mips.bne(T2, T3, "chk_cmd_track")
        mips.nop
        mips.li(T4, 0x00FFFFFF_u32)
        mips.and_(A0, T0, T4)       # A0 = target LBA
        mips.addiu(T9, S0, 0x0bf4)  # sceCdSeek (stub at 0x0bf4)
        mips.jalr(T9); mips.nop
        mips.move(A0, ZERO)
        mips.addiu(T9, S0, 0x0bec)  # sceCdSync(0)
        mips.jalr(T9); mips.nop
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        mips.label("chk_cmd_track")
        # Check if (cmd >> 8) == 1 (Play Track N)
        mips.srl(T2, T0, 8)
        mips.ori(T3, ZERO, 1)
        mips.bne(T2, T3, "chk_cmd_vol")
        mips.nop
        mips.andi(A0, T0, 0xFF)     # track index
        mips.bal("start_track")
        mips.nop
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        mips.label("chk_cmd_vol")
        # Check if (cmd >> 8) == 0x10 (Volume)
        mips.ori(T3, ZERO, 0x10)
        mips.bne(T2, T3, "process_cmd_loop")
        mips.nop
        mips.andi(T4, T0, 0xFF)
        mips.sll(S7, T4, 6)         # vol << 6
        mips.sw(S7, 0x1910, S0)
        mips.bal("set_all_volumes")
        mips.nop
        mips.beq(ZERO, ZERO, "process_cmd_loop"); mips.nop

        # Check streaming condition
        mips.label("chk_streaming")
        mips.lw(T0, 0x190c, S0)
        mips.ori(T1, ZERO, 1)
        mips.bne(T0, T1, "stream_loop")
        mips.nop

        # Update elapsed timer (+10 ms per loop tick):
        mips.lw(T0, 0x1918, S0) # timer_accum_ms
        mips.addiu(T0, T0, 10)  # +10 ms
        mips.lw(T1, 0x18F0, S0) # bank_dur_ms
        mips.sltu(T2, T0, T1)
        mips.bnez(T2, "timer_bank_not_expired")
        mips.nop

        # Timer expired: Voice 0 has transitioned banks!
        # Subtract bank_dur_ms and refill the newly-freed bank.
        mips.subu(T0, T0, T1)
        mips.srl(T2, T1, 1) # bank_dur_ms // 2
        mips.sltu(T3, T2, T0)
        mips.beqz(T3, "timer_rem_ok")
        mips.nop
        mips.move(T0, ZERO)
        mips.label("timer_rem_ok")
        mips.sw(T0, 0x1918, S0)

        # Check which bank needs refill: next_refill_bank at 0x1908
        mips.lw(T3, 0x1908, S0)
        mips.bnez(T3, "refill_bank_b")
        mips.nop

        # ================= REFILL BANK A (0x15000) =================
        # Voice 0 has entered Bank B, so Bank A is free to refill with next bank!
        mips.lui(A0, 0x0001)
        mips.ori(A0, A0, 0x5000)
        mips.ori(A1, ZERO, 1)    # loop_start = 1
        mips.move(A2, ZERO)      # loop_end = 0
        mips.bal("read_and_dma_bank")
        mips.nop
        mips.ori(T1, ZERO, 1)
        mips.sw(T1, 0x1908, S0)  # next_refill_bank = 1 (Bank B is next)
        mips.beq(ZERO, ZERO, "stream_loop")
        mips.nop

        # ================= REFILL BANK B (0x19000) =================
        # Voice 0 has entered Bank A, so Bank B is free to refill with next bank!
        mips.label("refill_bank_b")
        mips.lui(A0, 0x0001)
        mips.ori(A0, A0, 0x9000)
        mips.move(A1, ZERO)      # loop_start = 0
        mips.ori(A2, ZERO, 1)    # loop_end = 1
        mips.bal("read_and_dma_bank")
        mips.nop
        mips.sw(ZERO, 0x1908, S0) # next_refill_bank = 0 (Bank A is next)
        mips.beq(ZERO, ZERO, "stream_loop")
        mips.nop

        mips.label("timer_bank_not_expired")
        mips.sw(T0, 0x1918, S0)
        mips.beq(ZERO, ZERO, "stream_loop")
        mips.nop

        # ================= HELPER: read_and_dma_bank =================
        mips.label("read_and_dma_bank")
        mips.addiu(SP, SP, -64)
        mips.sw(RA, 60, SP)
        mips.sw(S1, 24, SP)
        mips.sw(S2, 28, SP)
        mips.sw(S3, 32, SP)
        mips.sw(S4, 36, SP)
        mips.sw(S5, 40, SP)
        mips.move(S1, A0) # spu_dest
        mips.move(S2, A1) # loop_start
        mips.move(S3, A2) # loop_end

        # Calculate sector to read:
        mips.lw(T0, 0x1900, S0) # cur_track
        mips.sll(T2, T0, 3)     # cur_track * 8
        mips.addiu(T3, S0, 0x1920)
        mips.addu(T3, T3, T2)   # &track_table[cur_track]
        mips.lw(S4, 0, T3)      # start_lba
        mips.lhu(S5, 4, T3)     # bank_count (16-bit)

        mips.lw(T4, 0x1904, S0) # cur_bank_idx
        mips.sltu(T5, T4, S5)
        mips.bnez(T5, "bank_in_range")
        mips.nop
        mips.move(T4, ZERO)     # wrap to bank 0
        mips.label("bank_in_range")

        mips.sll(T5, T4, 3)     # cur_bank_idx * 8 sectors
        mips.addu(A0, S4, T5)   # A0 = sector to read from disc!
        mips.ori(A1, ZERO, 8)   # A1 = 8 sectors (16 KB)
        mips.addiu(A2, S0, 0x1A00) # A2 = staging_buf (16 KB at S0 + 0x1A00)
        mips.addiu(A3, S0, 0x0c04) # A3 = &mode (sceCdRMode struct at 0x0c04)
        mips.addiu(T9, S0, 0x0be4) # sceCdRead (stub at 0x0be4)
        mips.jalr(T9); mips.nop

        # sceCdSync(0)
        mips.move(A0, ZERO)
        mips.addiu(T9, S0, 0x0bec) # sceCdSync (stub at 0x0bec)
        mips.jalr(T9); mips.nop

        # Print refill message only for initial priming (bank 0 and 1)
        mips.lw(A1, 0x1904, S0) # cur_bank_idx
        mips.sltiu(T1, A1, 2)
        mips.beqz(T1, "skip_refill_print")
        mips.nop
        mips.addiu(A0, S0, 0x1990)
        mips.move(A2, S1)        # spu_dest (0x15000 or 0x19000)
        mips.addiu(T9, S0, 0x1030) # printf
        mips.jalr(T9); mips.nop
        mips.label("skip_refill_print")

        # Patch ADPCM loop flags:
        mips.addiu(T6, S0, 0x1A00) # staging_buf
        mips.ori(T7, ZERO, 0x02)   # default: Repeat
        mips.beqz(S2, "no_flag_start")
        mips.nop
        mips.ori(T7, ZERO, 0x06)   # Loop Start + Repeat
        mips.label("no_flag_start")
        mips.sb(T7, 1, T6)

        mips.addiu(T8, T6, 16368)  # last block in 16KB bank
        mips.ori(T7, ZERO, 0x02)   # default: Repeat
        mips.beqz(S3, "no_flag_end")
        mips.nop
        mips.ori(T7, ZERO, 0x03)   # Loop End + Repeat
        mips.label("no_flag_end")
        mips.sb(T7, 1, T8)

        mips.label("do_voice_trans")
        # Flush CPU data cache to physical IOP RAM before DMA transfer
        mips.addiu(T9, S0, 0x0fc0) # FlushDcache
        mips.jalr(T9); mips.nop

        # sceSdVoiceTrans(0, 0, staging_buf, s1, 16384)
        mips.move(A0, ZERO)
        mips.move(A1, ZERO)
        mips.addiu(A2, S0, 0x1A00)
        mips.move(A3, S1)
        mips.ori(T0, ZERO, 0x4000) # 16384 bytes
        mips.sw(T0, 16, SP)
        mips.addiu(T9, S0, 0x0f34) # sceSdVoiceTrans
        mips.jalr(T9); mips.nop

        # Wait for DMA completion: sceSdVoiceTransStatus(0, 1)
        mips.move(A0, ZERO)        # Channel 0
        mips.ori(A1, ZERO, 1)      # 1 = SD_TRANS_STATUS_WAIT
        mips.addiu(T9, S0, 0x0f3c) # sceSdVoiceTransStatus
        mips.jalr(T9); mips.nop

        # Advance cur_bank_idx:
        mips.lw(T4, 0x1904, S0)
        mips.addiu(T4, T4, 1)
        mips.sltu(T5, T4, S5)
        mips.bnez(T5, "store_bank_advance")
        mips.nop
        mips.move(T4, ZERO) # wrap to bank 0
        mips.label("store_bank_advance")
        mips.sw(T4, 0x1904, S0)

        mips.lw(S1, 24, SP)
        mips.lw(S2, 28, SP)
        mips.lw(S3, 32, SP)
        mips.lw(S4, 36, SP)
        mips.lw(S5, 40, SP)
        mips.lw(RA, 60, SP)
        mips.addiu(SP, SP, 64)
        mips.jr(RA); mips.nop

        # ================= HELPER: start_track =================
        mips.label("start_track")
        mips.addiu(SP, SP, -64)
        mips.sw(RA, 60, SP)
        mips.sw(S6, 24, SP)
        mips.move(S6, A0) # track_idx
        mips.lw(T0, 0x1914, S0) # total_tracks
        mips.sltu(T1, S6, T0)
        mips.bnez(T1, "track_idx_in_bounds")
        mips.nop
        mips.move(S6, ZERO)
        mips.label("track_idx_in_bounds")

        # Print track switch message
        mips.addiu(A0, S0, 0x19B0)
        mips.move(A1, S6)
        mips.addiu(T9, S0, 0x1030) # printf
        mips.jalr(T9); mips.nop

        # Set cur_track = S6
        mips.sw(S6, 0x1900, S0)

        # Set Voice 0 Pitch & dynamic frame timing:
        mips.sll(T2, S6, 3)     # S6 * 8
        mips.addiu(T3, S0, 0x1920)
        mips.addu(T3, T3, T2)   # &track_table[S6]
        mips.lhu(A1, 6, T3)     # pitch_reg
        mips.bnez(A1, "pitch_val_ok")
        mips.nop
        mips.ori(A1, ZERO, 0x02AB)
        mips.label("pitch_val_ok")
        mips.sw(A1, 0x18EC, S0) # cur_pitch

        # Compute bank_dur_ms = 2446677 / cur_pitch:
        mips.li(T0, 2446677_u32)
        mips.lw(T1, 0x18EC, S0)
        mips.divu(T0, T1)
        mips.mflo(T2)
        mips.sw(T2, 0x18F0, S0) # bank_dur_ms

        # Set Volumes:
        mips.lw(S7, 0x1910, S0)
        mips.bal("set_all_volumes")
        mips.nop

        # Reset cur_bank_idx to 0:
        mips.sw(ZERO, 0x1904, S0)
        mips.beq(ZERO, ZERO, "prime_and_play_spu2_banks")
        mips.nop

        # ================= HELPER: seek_stream_bank =================
        mips.label("seek_stream_bank")
        mips.addiu(SP, SP, -64)
        mips.sw(RA, 60, SP)
        mips.sw(S6, 24, SP)
        mips.move(S6, A1) # target_bank

        # Check bounds against cur_track bank_count:
        mips.lw(T0, 0x1900, S0) # cur_track
        mips.sll(T2, T0, 3)     # cur_track * 8
        mips.addiu(T3, S0, 0x1920)
        mips.addu(T3, T3, T2)   # &track_table[cur_track]
        mips.lhu(T4, 4, T3)     # bank_count
        mips.sltu(T5, S6, T4)
        mips.bnez(T5, "seek_bank_in_bounds")
        mips.nop
        mips.move(S6, ZERO)
        mips.label("seek_bank_in_bounds")

        # Print seek message
        mips.addiu(A0, S0, 0x19C8)
        mips.move(A1, S6)
        mips.addiu(T9, S0, 0x1030) # printf
        mips.jalr(T9); mips.nop

        # Set cur_bank_idx = target_bank
        mips.sw(S6, 0x1904, S0)

        # ================= HELPER: prime_and_play_spu2_banks =================
        mips.label("prime_and_play_spu2_banks")
        # Key off Voice 0 on Core 0:
        mips.ori(A0, ZERO, 0x1600)
        mips.ori(A1, ZERO, 1)
        mips.jalr(S3); mips.nop
        mips.ori(A0, ZERO, 0x1600)
        mips.move(A1, ZERO)
        mips.jalr(S3); mips.nop

        # Permanently key off and silence Core 1 Voice 0:
        mips.ori(A0, ZERO, 0x1601)
        mips.ori(A1, ZERO, 1)
        mips.jalr(S3); mips.nop

        # Pre-fill Bank A (0x15000): loop_start=1, loop_end=0
        mips.lui(A0, 0x0001)
        mips.ori(A0, A0, 0x5000)
        mips.ori(A1, ZERO, 1)
        mips.move(A2, ZERO)
        mips.bal("read_and_dma_bank"); mips.nop

        # Pre-fill Bank B (0x19000): loop_start=0, loop_end=1
        mips.lui(A0, 0x0001)
        mips.ori(A0, A0, 0x9000)
        mips.move(A1, ZERO)
        mips.ori(A2, ZERO, 1)
        mips.bal("read_and_dma_bank"); mips.nop

        # Set Voice 0 SSA and LSA to 0x15000 on Core 0 ONLY
        mips.lui(A1, 0x0001); mips.ori(A1, A1, 0x5000)
        mips.ori(A0, ZERO, 0x2040)  # Core 0 SD_VA_SSA
        mips.jalr(S4); mips.nop
        mips.ori(A0, ZERO, 0x2060)  # Core 0 SD_VA_LSA
        mips.jalr(S4); mips.nop

        # Set Voice 0 Pitch = cur_pitch on Core 0 ONLY
        mips.ori(A0, ZERO, 0x0200) # Core 0 SD_VP_PITCH
        mips.lw(A1, 0x18EC, S0)
        mips.jalr(S2); mips.nop

        # Set Core 1 Voice 0 Pitch = 0 (silent)
        mips.ori(A0, ZERO, 0x0201)
        mips.move(A1, ZERO)
        mips.jalr(S2); mips.nop

        # Initial state flags: Voice 0 starts in Bank A (playing cur_bank_idx).
        mips.sw(ZERO, 0x1908, S0) # next_refill_bank = 0 (Bank A is first)
        mips.sw(ZERO, 0x1918, S0) # timer_accum_ms = 0
        mips.ori(T0, ZERO, 1)
        mips.sw(T0, 0x190C, S0)   # play_state = 1

        # Key on Voice 0 on Core 0 ONLY:
        mips.ori(A0, ZERO, 0x1500) # SD_S_KON (Core 0)
        mips.ori(A1, ZERO, 1)
        mips.jalr(S3); mips.nop

        mips.lw(S6, 24, SP)
        mips.lw(RA, 60, SP)
        mips.addiu(SP, SP, 64)
        mips.jr(RA); mips.nop

        # ================= HELPER: set_all_volumes =================
        mips.label("set_all_volumes")
        mips.addiu(SP, SP, -16)
        mips.sw(RA, 0, SP)

        # Route Core 0 Voice 0 to both Left and Right stereo channels at volume S7:
        mips.ori(A0, ZERO, 0x0000); mips.move(A1, S7); mips.jalr(S2); mips.nop # Core 0 Voice 0 VOLL
        mips.ori(A0, ZERO, 0x0100); mips.jalr(S2); mips.nop # Core 0 Voice 0 VOLR

        mips.lw(RA, 0, SP)
        mips.addiu(SP, SP, 16)
        mips.jr(RA); mips.nop

        mips.resolve!
        engine_bytes = mips.to_slice
        if engine_bytes.size > (0xbd0 - 0x4dc)
          raise "Streaming engine code too large: #{engine_bytes.size} bytes > #{0xbd0 - 0x4dc} bytes max"
        end
        base_elf[text_off + 0x4dc, engine_bytes.size].copy_from(engine_bytes)

        # Hook at 0x0c90 to jump to entry
        base_elf[text_off + 0x0c90, 4].copy_from(Bytes[0x12, 0xFE, 0x11, 0x04]) # bal 0x4dc
        base_elf[text_off + 0x0c94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        base_elf[text_off + 0x0c98, 4].copy_from(Bytes[0xF7, 0xFF, 0x00, 0x10]) # b 0x0c78
        base_elf[text_off + 0x0c9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        if audio_data
          # Auto-play startup sound on IRX boot at 0x0c64, then branch immediately to streaming engine at 0x04dc:
          # 0x0c64: bal 0x0170 (play startup chime)
          # 0x0c68: nop
          # 0x0c6c: bal 0x04dc (enter streaming engine)
          # 0x0c70: nop
          base_elf[text_off + 0x0c64, 4].copy_from(Bytes[0x42, 0xFD, 0x11, 0x04]) # bal 0x0170
          base_elf[text_off + 0x0c68, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
          base_elf[text_off + 0x0c6c, 4].copy_from(Bytes[0x1B, 0xFE, 0x11, 0x04]) # bal 0x04dc
          base_elf[text_off + 0x0c70, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
          base_elf[text_off + 0x0c74, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
        else
          # Directly enter streaming engine at 0x04dc on boot:
          base_elf[text_off + 0x0c64, 4].copy_from(Bytes[0x1D, 0xFE, 0x11, 0x04]) # bal 0x04dc
          base_elf[text_off + 0x0c68, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
          base_elf[text_off + 0x0c6c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
          base_elf[text_off + 0x0c70, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
          base_elf[text_off + 0x0c74, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
        end

        base_elf
      end
    end
  end
end
