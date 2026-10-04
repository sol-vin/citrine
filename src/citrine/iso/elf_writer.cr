require "io/memory"
require "./pad_runtime_payload"

module Citrine
  module ISO
    # Low-level 32-bit Little-Endian MIPS R5900 ELF Executable Writer
    class ElfWriter
      # ELF Magic & Identity Constants
      ELFMAG        = Bytes[0x7F, 0x45, 0x4C, 0x46] # \x7FELF
      ELFCLASS32    = 1_u8
      ELFDATA2LSB   = 1_u8
      EV_CURRENT    = 1_u8
      ELFOSABI_SYSV = 0_u8
      ET_EXEC       = 2_u16
      EM_MIPS       = 8_u16

      # MIPS R5900 Flags: EF_MIPS_NOREORDER (1) | EF_MIPS_ARCH_R5900 (0x20924000)
      EF_MIPS_R5900 = 0x20924001_u32

      # Section Types
      SHT_NULL      = 0_u32
      SHT_PROGBITS  = 1_u32
      SHT_SYMTAB    = 2_u32
      SHT_STRTAB    = 3_u32
      SHT_NOBITS    = 8_u32

      # Section Flags
      SHF_WRITE     = 0x1_u32
      SHF_ALLOC     = 0x2_u32
      SHF_EXECINSTR = 0x4_u32

      # Program Header Types
      PT_LOAD       = 1_u32
      PF_R          = 4_u32
      PF_W          = 2_u32
      PF_X          = 1_u32

      # Symbol Bind & Types
      STB_GLOBAL    = 1_u8
      STT_FUNC      = 2_u8
      STT_OBJECT    = 1_u8

      record SymbolDef, name : String, address : UInt32, size : UInt32, type : UInt8, binding : UInt8, section_idx : UInt16

      def self.write(
        text_data : Bytes,
        rodata_data : Bytes,
        data_data : Bytes,
        symbols : Array(SymbolDef),
        entry_point : UInt32 = 0x00100000_u32,
        pad_payload : Bytes? = PadRuntimePayload.bytes,
        rodata_vaddr : UInt32 = 0x00500000_u32
      ) : Bytes
        # .strtab
        strtab = IO::Memory.new
        strtab.write_byte(0_u8)
        add_str = ->(s : String) : UInt32 {
          off = strtab.pos.to_u32
          strtab.write(s.to_slice)
          strtab.write_byte(0_u8)
          off
        }

        # .symtab
        symtab = IO::Memory.new
        16.times { symtab.write_byte(0_u8) } # STN_UNDEF

        symbols.each do |sym|
          name_offset = add_str.call(sym.name)
          info = (sym.binding << 4) | (sym.type & 0xF)
          symtab.write_bytes(name_offset, IO::ByteFormat::LittleEndian)
          symtab.write_bytes(sym.address, IO::ByteFormat::LittleEndian)
          symtab.write_bytes(sym.size, IO::ByteFormat::LittleEndian)
          symtab.write_byte(info)
          symtab.write_byte(0_u8)
          symtab.write_bytes(sym.section_idx, IO::ByteFormat::LittleEndian)
        end

        symtab_data = symtab.to_slice
        strtab_data = strtab.to_slice

        # .shstrtab
        shstrtab = IO::Memory.new
        shstrtab.write_byte(0_u8)
        add_shstr = ->(s : String) : UInt32 {
          off = shstrtab.pos.to_u32
          shstrtab.write(s.to_slice)
          shstrtab.write_byte(0_u8)
          off
        }

        sh_names = {
          null:     0_u32,
          text:     add_shstr.call(".text"),
          rodata:   add_shstr.call(".rodata"),
          pad:      pad_payload ? add_shstr.call(".pad") : 0_u32,
          data:     add_shstr.call(".data"),
          spram:    add_shstr.call(".spram"),
          symtab:   add_shstr.call(".symtab"),
          strtab:   add_shstr.call(".strtab"),
          shstrtab: add_shstr.call(".shstrtab"),
        }
        shstrtab_data = shstrtab.to_slice

        num_ph = pad_payload ? 4_u16 : 3_u16
        shnum = pad_payload ? 9_u16 : 8_u16
        shstrndx = pad_payload ? 8_u16 : 7_u16

        # Segment and section alignment (4096 bytes = 2 CD-ROM sectors, meeting PS2 CDVD DMA & page alignment)
        seg_align       = 0x1000_u32
        offset_text     = 0x1000_u32
        offset_rodata   = (offset_text + text_data.size.to_u32 + seg_align - 1) & ~(seg_align - 1)
        raw_pad_offset  = offset_rodata + rodata_data.size.to_u32
        offset_pad      = (raw_pad_offset + seg_align - 1) & ~(seg_align - 1)
        raw_data_offset = pad_payload ? (offset_pad + pad_payload.size.to_u32) : raw_pad_offset
        offset_data     = (raw_data_offset + seg_align - 1) & ~(seg_align - 1)
        offset_symtab   = offset_data + data_data.size.to_u32
        offset_strtab   = offset_symtab + symtab_data.size.to_u32
        offset_shstrtab = offset_strtab + strtab_data.size.to_u32
        shoff           = (offset_shstrtab + shstrtab_data.size.to_u32 + 3) & ~3_u32

        io = IO::Memory.new

        # ELF Header (52 bytes)
        io.write(ELFMAG)
        io.write_byte(ELFCLASS32)
        io.write_byte(ELFDATA2LSB)
        io.write_byte(EV_CURRENT)
        io.write_byte(ELFOSABI_SYSV)
        8.times { io.write_byte(0_u8) }

        io.write_bytes(ET_EXEC, IO::ByteFormat::LittleEndian)
        io.write_bytes(EM_MIPS, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(entry_point, IO::ByteFormat::LittleEndian)
        io.write_bytes(52_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(shoff, IO::ByteFormat::LittleEndian)
        io.write_bytes(EF_MIPS_R5900, IO::ByteFormat::LittleEndian)
        io.write_bytes(52_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(32_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(num_ph, IO::ByteFormat::LittleEndian)
        io.write_bytes(40_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(shnum, IO::ByteFormat::LittleEndian)
        io.write_bytes(shstrndx, IO::ByteFormat::LittleEndian)

        # Program Headers
        # PH 0: Code (.text)
        io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_text, IO::ByteFormat::LittleEndian)
        io.write_bytes(entry_point, IO::ByteFormat::LittleEndian)
        io.write_bytes(entry_point, IO::ByteFormat::LittleEndian)
        io.write_bytes(text_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(text_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(PF_R | PF_X, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)

        if pp = pad_payload
          # PH 1: Pad Driver Runtime (.pad at 0x00180000)
          io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)
          io.write_bytes(offset_pad, IO::ByteFormat::LittleEndian)
          io.write_bytes(PadRuntimePayload::VADDR, IO::ByteFormat::LittleEndian)
          io.write_bytes(PadRuntimePayload::VADDR, IO::ByteFormat::LittleEndian)
          io.write_bytes(pp.size.to_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(PadRuntimePayload::MEM_SIZE, IO::ByteFormat::LittleEndian)
          io.write_bytes(PF_R | PF_W | PF_X, IO::ByteFormat::LittleEndian)
          io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)
        end

        # PH 2 (or 1): Read-Only Data (.rodata at rodata_vaddr)
        io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_rodata, IO::ByteFormat::LittleEndian)
        io.write_bytes(rodata_vaddr, IO::ByteFormat::LittleEndian)
        io.write_bytes(rodata_vaddr, IO::ByteFormat::LittleEndian)
        io.write_bytes(rodata_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(rodata_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(PF_R, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)

        # PH 3 (or 2): Data (.data)
        data_vaddr = ((rodata_vaddr + rodata_data.size.to_u32 + 0xFFF) & ~0xFFF_u32)

        io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_data, IO::ByteFormat::LittleEndian)
        io.write_bytes(data_vaddr, IO::ByteFormat::LittleEndian)
        io.write_bytes(data_vaddr, IO::ByteFormat::LittleEndian)
        io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(PF_R | PF_W, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)

        # Padding to offset_text
        while io.pos < offset_text
          io.write_byte(0_u8)
        end

        # Segment contents
        io.write(text_data)
        while io.pos < offset_rodata
          io.write_byte(0_u8)
        end
        io.write(rodata_data)

        if pp = pad_payload
          while io.pos < offset_pad
            io.write_byte(0_u8)
          end
          io.write(pp)
        end

        while io.pos < offset_data
          io.write_byte(0_u8)
        end
        io.write(data_data)

        io.write(symtab_data)
        io.write(strtab_data)
        io.write(shstrtab_data)

        # Padding to shoff
        while io.pos < shoff
          io.write_byte(0_u8)
        end

        # Section Headers
        # [0] NULL
        10.times { io.write_bytes(0_u32, IO::ByteFormat::LittleEndian) }

        # [1] .text
        io.write_bytes(sh_names[:text], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_PROGBITS, IO::ByteFormat::LittleEndian)
        io.write_bytes(SHF_ALLOC | SHF_EXECINSTR, IO::ByteFormat::LittleEndian)
        io.write_bytes(entry_point, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_text, IO::ByteFormat::LittleEndian)
        io.write_bytes(text_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

        # [2] .rodata
        io.write_bytes(sh_names[:rodata], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_PROGBITS, IO::ByteFormat::LittleEndian)
        io.write_bytes(SHF_ALLOC, IO::ByteFormat::LittleEndian)
        io.write_bytes(rodata_vaddr, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_rodata, IO::ByteFormat::LittleEndian)
        io.write_bytes(rodata_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(16_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

        if pp = pad_payload
          # [3] .pad
          io.write_bytes(sh_names[:pad], IO::ByteFormat::LittleEndian)
          io.write_bytes(SHT_PROGBITS, IO::ByteFormat::LittleEndian)
          io.write_bytes(SHF_ALLOC | SHF_WRITE | SHF_EXECINSTR, IO::ByteFormat::LittleEndian)
          io.write_bytes(PadRuntimePayload::VADDR, IO::ByteFormat::LittleEndian)
          io.write_bytes(offset_pad, IO::ByteFormat::LittleEndian)
          io.write_bytes(pp.size.to_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(16_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        end

        # [3 or 4] .data
        io.write_bytes(sh_names[:data], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_PROGBITS, IO::ByteFormat::LittleEndian)
        io.write_bytes(SHF_ALLOC | SHF_WRITE, IO::ByteFormat::LittleEndian)
        io.write_bytes(data_vaddr, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_data, IO::ByteFormat::LittleEndian)
        io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

        # [4 or 5] .spram
        io.write_bytes(sh_names[:spram], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_NOBITS, IO::ByteFormat::LittleEndian)
        io.write_bytes(SHF_ALLOC | SHF_WRITE, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(16384_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(16_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

        # [5 or 6] .symtab
        strtab_idx = pad_payload ? 7_u32 : 6_u32
        io.write_bytes(sh_names[:symtab], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_SYMTAB, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_symtab, IO::ByteFormat::LittleEndian)
        io.write_bytes(symtab_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(strtab_idx, IO::ByteFormat::LittleEndian) # Link to .strtab
        io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(16_u32, IO::ByteFormat::LittleEndian)

        # [6 or 7] .strtab
        io.write_bytes(sh_names[:strtab], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_STRTAB, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_strtab, IO::ByteFormat::LittleEndian)
        io.write_bytes(strtab_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

        # [7 or 8] .shstrtab
        io.write_bytes(sh_names[:shstrtab], IO::ByteFormat::LittleEndian)
        io.write_bytes(SHT_STRTAB, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(offset_shstrtab, IO::ByteFormat::LittleEndian)
        io.write_bytes(shstrtab_data.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

        io.to_slice
      end
    end
  end
end
