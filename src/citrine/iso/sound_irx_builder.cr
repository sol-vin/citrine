require "./sound_irx_base"
require "../mips/mips_emitter"

module Citrine
  module ISO
    class SoundIrxBuilder
      alias MipsEmitter = Citrine::MIPS::MipsEmitter
      include Citrine::MIPS

      # Builds an S.IRX ELF module embedding the given VAG audio stream.
      # If vag_bytes is nil or smaller than a standard VAG header (48 bytes),
      # returns the base IRX unaltered.
      def self.build(vag_bytes : Bytes?, max_duration_sec : Float64 = 60.0) : Bytes
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
          # Disable thid1 creation: sw zero, 56(sp); nop; nop
          out_bytes[text_off + 0x0d94, 4].copy_from(Bytes[0x38, 0x00, 0xA0, 0xAF])
          out_bytes[text_off + 0x0d98, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
          out_bytes[text_off + 0x0d9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
          out_bytes
        }

        return silence_elf.call if vag_bytes.nil? || vag_bytes.size <= 48

        vag_adpcm = vag_bytes[48..-1]
        max_blocks = vag_adpcm.size // 16
        return silence_elf.call if max_blocks == 0

        # Round down to multiple of 4 blocks (64 bytes for SPU2 DMA compliance)
        target_blocks = (max_blocks // 4) * 4

        # Bound by max_duration_sec (at 22050 Hz, 28 samples per block -> 787.5 blocks/sec)
        max_allowed_blocks = ((max_duration_sec * 22050.0 / 28.0) // 4).to_i * 4
        target_blocks = Math.min(target_blocks, max_allowed_blocks)
        target_blocks = (target_blocks // 4) * 4
        return silence_elf.call if target_blocks == 0

        chunk_size = (target_blocks * 16).to_u32

        # Create audio payload: 64-byte header + chunk_size bytes ADPCM
        audio_mem = IO::Memory.new(64 + chunk_size)
        audio_mem.write(vag_bytes[0..47])
        16.times { audio_mem.write_byte(0_u8) } # 16 bytes padding -> 64 bytes total header
        audio_mem.write(vag_adpcm[0...chunk_size])

        audio_data = audio_mem.to_slice.dup

        # SPU2 Hardware ADPCM Loop Flags:
        # Block 0 (offset 0x40): flag = 0x06 (Loop Start + Loop Repeat: Bit 2 | Bit 1)
        audio_data[0x40 + 1] = 0x06_u8

        # Ensure all intermediate blocks have Bit 1 (0x02) set:
        (1...target_blocks - 1).each do |b|
          audio_data[0x40 + b * 16 + 1] = 0x02_u8
        end

        # Last block: flag = 0x03 (Loop End + Loop Repeat: Bit 0 | Bit 1)
        last_blk_off = 0x40 + chunk_size.to_i - 16
        audio_data[last_blk_off + 1] = 0x03_u8

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
          if sh_offset >= orig_data_end
            sh_offset += shift
            IO::ByteFormat::LittleEndian.encode(sh_offset, out_bytes[hdr + 0x10, 4])
          end
          if sh_type == 9_u32 # SHT_REL
            rel_text_sh_off = sh_offset
            rel_text_size = sh_size
          end
        end

        # Zero out old relocations in .rel.text that fall in our patched dispatcher range (0x4dc..0x0c50)
        if rel_text_sh_off > 0
          (rel_text_size // 8).times do |ri|
            r_off = rel_text_sh_off + ri * 8
            r_offset = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[r_off, 4])
            if r_offset >= 0x4dc && r_offset < 0x0c50
              IO::ByteFormat::LittleEndian.encode(0_u32, out_bytes[r_off + 4, 4]) # r_info = R_MIPS_NONE (0)
            end
          end
        end

        # 4. Patch instructions in .text (file offset 0x90):
        # Disable thid1 creation in startup: sw zero, 56(sp); nop; nop
        out_bytes[text_off + 0x0d94, 4].copy_from(Bytes[0x38, 0x00, 0xA0, 0xAF])
        out_bytes[text_off + 0x0d98, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        out_bytes[text_off + 0x0d9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        # Patch PlaySound: point wavBuffer to 0x1900
        out_bytes[text_off + 0x194, 4].copy_from(Bytes[0x00, 0x19, 0x42, 0x24]) # addiu v0, v0, 0x1900

        # Patch 32-bit transfer size:
        hi_size = (chunk_size >> 16).to_u16
        lo_size = (chunk_size & 0xFFFF).to_u16

        lui_at = (0x0F_u32 << 26) | (1_u32 << 16) | hi_size.to_u32
        ori_at = (0x0D_u32 << 26) | (1_u32 << 21) | (1_u32 << 16) | lo_size.to_u32
        sw_at = (0x2B_u32 << 26) | (29_u32 << 21) | (1_u32 << 16) | 0x10_u32

        IO::ByteFormat::LittleEndian.encode(lui_at, out_bytes[text_off + 0x268, 4])
        out_bytes[text_off + 0x26c, 4].copy_from(Bytes[0x40, 0x00, 0x62, 0x24]) # addiu v0, v1, 0x40
        IO::ByteFormat::LittleEndian.encode(ori_at, out_bytes[text_off + 0x270, 4])
        IO::ByteFormat::LittleEndian.encode(sw_at, out_bytes[text_off + 0x274, 4])

        # Patch pitch at .text+0x434: li a1, 0x075A (exact 22,050 Hz on 48.0 kHz SPU2 core: 22050 * 4096 / 48000 = 1881.6 ~= 1882)
        out_bytes[text_off + 0x434, 4].copy_from(Bytes[0x5A, 0x07, 0x05, 0x24])

        # Multi-mode position-independent sound dispatcher at .text+0x4dc:
        # Dispatches SoundMode (passed in v0 from SoundHandler):
        #   0 = Stop (calls StopSound)
        #   1 = Play (calls PlaySound, initializes cur_vol at 0x17d8)
        #   2 = Pause (sets voice 0 pitch to 0, silences volumes)
        #   3 = Resume (restores voice 0 pitch to 0x075A, restores volumes)
        #   4 = Fast Forward (sets voice 0 pitch to 0x1600 [3x speed])
        #   5 = Normal Speed (sets voice 0 pitch to 0x075A [1x speed])
        #   0x1000..0x10FF = Set Volume (cur_vol = (mode & 0xFF) << 6, sets master and voice volumes)
        disp = MipsEmitter.new(0x000004dc_u32)

        disp.label("disp_start")
        disp.addiu(SP, SP, -32)
        disp.sw(RA, 28, SP)
        disp.sw(S0, 24, SP)
        disp.sw(S1, 20, SP)

        # Position-independent module base calculation:
        disp.bal("get_base")
        disp.nop
        disp.label("get_base")
        disp.addiu(S0, RA, -0x4F4) # ra = module_base + 0x4f4

        # Case 1: Play (v0 == 1)
        disp.label("chk_play")
        disp.ori(T1, ZERO, 1)
        disp.bne(V0, T1, "chk_stop")
        disp.nop
        disp.addiu(T8, S0, 0x0170) # PlaySound
        disp.jalr(T8)
        disp.nop
        disp.lw(A1, 0x17D8, S0)
        disp.bnez(A1, "disp_exit")
        disp.nop
        disp.ori(A1, ZERO, 0x3C00)
        disp.sw(A1, 0x17D8, S0)
        disp.beq(ZERO, ZERO, "disp_exit")
        disp.nop

        # Case 0: Stop (v0 == 0)
        disp.label("chk_stop")
        disp.bnez(V0, "chk_pause")
        disp.nop
        disp.addiu(T8, S0, 0x0484) # StopSound
        disp.jalr(T8)
        disp.nop
        disp.beq(ZERO, ZERO, "disp_exit")
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
        disp.ori(A0, ZERO, 0x0200) # SD_VP_PITCH Voice 0 = 0x075A
        disp.ori(A1, ZERO, 0x075A)
        disp.jalr(T9)
        disp.nop
        disp.lw(S1, 0x17D8, S0)
        disp.bnez(S1, "apply_vols")
        disp.nop
        disp.ori(S1, ZERO, 0x3C00)
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
        disp.ori(A1, ZERO, 0x075A) # 1.0x speed pitch
        disp.jalr(T9)
        disp.nop
        disp.beq(ZERO, ZERO, "disp_exit")
        disp.nop

        # Case 6: Set Volume (v0 >= 0x1000)
        disp.label("chk_vol")
        disp.srl(T1, V0, 12)
        disp.ori(T2, ZERO, 1)
        disp.bne(T1, T2, "disp_exit")
        disp.nop
        disp.andi(S1, V0, 0xFF)
        disp.sll(S1, S1, 6) # scale 0..255 -> 0..16320
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
        disp.lw(S1, 20, SP)
        disp.lw(S0, 24, SP)
        disp.lw(RA, 28, SP)
        disp.addiu(SP, SP, 32)
        disp.jr(RA)
        disp.nop

        disp.resolve!

        disp_bytes = disp.to_slice
        out_bytes[text_off + 0x4dc, disp_bytes.size].copy_from(disp_bytes)

        # Hook SoundThread at 0xc90 via bal to 0x4dc:
        # 0x0c90: bal 0x4dc (0x0411FE12)
        # 0x0c94: nop
        # 0x0c98: b 0xcb4 (0x10000006)
        # 0x0c9c: nop
        out_bytes[text_off + 0xc90, 4].copy_from(Bytes[0x12, 0xFE, 0x11, 0x04])
        out_bytes[text_off + 0xc94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])
        out_bytes[text_off + 0xc98, 4].copy_from(Bytes[0x06, 0x00, 0x00, 0x10])
        out_bytes[text_off + 0xc9c, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00])

        out_bytes
      end
    end
  end
end
