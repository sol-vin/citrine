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

        # 3. Update Section Headers:
        e_shentsize = 40_u32
        13.times do |i|
          hdr = new_shoff + i.to_u32 * e_shentsize
          sh_offset = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[hdr + 0x10, 4])
          if sh_offset >= orig_data_end
            IO::ByteFormat::LittleEndian.encode(sh_offset + shift, out_bytes[hdr + 0x10, 4])
          end
        end

        # 4. Patch instructions in .text (file offset 0x90):
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

        # Multi-mode sound dispatcher at .text+0x4dc (replaces dead TestThread space):
        # Dispatches SoundMode (passed in v0 from SoundHandler):
        #   0 = Stop (calls StopSound)
        #   1 = Play (calls PlaySound, initializes cur_vol at 0x17d8)
        #   2 = Pause (sets voice 0 pitch to 0, sets master volume to 0)
        #   3 = Resume (restores voice 0 pitch to 0x075A, restores master volume)
        #   0x1000..0x10FF = Set Volume (cur_vol = (mode & 0xFF) << 6, sets master volume)
        disp = MipsEmitter.new(0x000004dc_u32)

        # Case 1: Play
        disp.label("chk_play")
        disp.ori(T1, ZERO, 1)
        disp.bne(V0, T1, "chk_stop")
        disp.nop
        disp.jal("PlaySound")
        disp.nop
        disp.lui(A0, 0)
        disp.lw(A1, 0x17d8, A0)
        disp.bnez(A1, "play_ret")
        disp.nop
        disp.ori(A1, ZERO, 0x3C00)
        disp.sw(A1, 0x17d8, A0)
        disp.label("play_ret")
        disp.j("SoundThread_Loop")
        disp.nop

        # Case 0: Stop
        disp.label("chk_stop")
        disp.bnez(V0, "chk_pause")
        disp.nop
        disp.jal("StopSound")
        disp.nop
        disp.j("SoundThread_Loop")
        disp.nop

        # Case 2: Pause
        disp.label("chk_pause")
        disp.ori(T1, ZERO, 2)
        disp.bne(V0, T1, "chk_resume")
        disp.nop
        disp.ori(A0, ZERO, 0x200) # SD_VP_PITCH Voice 0 = 0
        disp.move(A1, ZERO)
        disp.jal("sceSdSetParam")
        disp.nop
        disp.ori(A0, ZERO, 0x980) # SD_C_MVOLL = 0
        disp.move(A1, ZERO)
        disp.jal("sceSdSetParam")
        disp.nop
        disp.ori(A0, ZERO, 0xa80) # SD_C_MVOLR = 0
        disp.move(A1, ZERO)
        disp.jal("sceSdSetParam")
        disp.nop
        disp.j("SoundThread_Loop")
        disp.nop

        # Case 3: Resume
        disp.label("chk_resume")
        disp.ori(T1, ZERO, 3)
        disp.bne(V0, T1, "chk_vol")
        disp.nop
        disp.ori(A0, ZERO, 0x200) # SD_VP_PITCH Voice 0 = 0x075A
        disp.ori(A1, ZERO, 0x075A)
        disp.jal("sceSdSetParam")
        disp.nop
        disp.lui(T0, 0)
        disp.lw(A1, 0x17d8, T0)
        disp.bnez(A1, "res_vol_l")
        disp.nop
        disp.ori(A1, ZERO, 0x3C00)
        disp.label("res_vol_l")
        disp.ori(A0, ZERO, 0x980) # SD_C_MVOLL
        disp.jal("sceSdSetParam")
        disp.nop
        disp.lui(T0, 0)
        disp.lw(A1, 0x17d8, T0)
        disp.bnez(A1, "res_vol_r")
        disp.nop
        disp.ori(A1, ZERO, 0x3C00)
        disp.label("res_vol_r")
        disp.ori(A0, ZERO, 0xa80) # SD_C_MVOLR
        disp.jal("sceSdSetParam")
        disp.nop
        disp.j("SoundThread_Loop")
        disp.nop

        # Case 4: Set Volume (0x1000..0x10FF)
        disp.label("chk_vol")
        disp.srl(T1, V0, 12)
        disp.ori(T2, ZERO, 1)
        disp.bne(T1, T2, "disp_done")
        disp.nop
        disp.andi(A1, V0, 0xFF)
        disp.sll(A1, A1, 6) # scale 0..255 -> 0..16320
        disp.lui(T0, 0)
        disp.sw(A1, 0x17d8, T0)
        disp.ori(A0, ZERO, 0x980) # SD_C_MVOLL
        disp.jal("sceSdSetParam")
        disp.nop
        disp.lui(T0, 0)
        disp.lw(A1, 0x17d8, T0)
        disp.ori(A0, ZERO, 0xa80) # SD_C_MVOLR
        disp.jal("sceSdSetParam")
        disp.nop

        disp.label("disp_done")
        disp.j("SoundThread_Loop")
        disp.nop

        disp.labels["PlaySound"] = 0x00000170_u32
        disp.labels["StopSound"] = 0x00000484_u32
        disp.labels["sceSdSetParam"] = 0x00000f0c_u32
        disp.labels["SoundThread_Loop"] = 0x00000cb4_u32
        disp.resolve!

        disp_bytes = disp.to_slice
        out_bytes[text_off + 0x4dc, disp_bytes.size].copy_from(disp_bytes)

        # Hook SoundThread at 0xc90: j 0x4dc; nop
        out_bytes[text_off + 0xc90, 4].copy_from(Bytes[0x37, 0x01, 0x00, 0x08]) # j 0x4dc
        out_bytes[text_off + 0xc94, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop

        out_bytes
      end
    end
  end
end
