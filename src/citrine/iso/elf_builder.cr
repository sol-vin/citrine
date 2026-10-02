module Citrine
  # Generates a valid 32-bit Little-Endian MIPS R5900 PlayStation 2 ELF executable.
  # Contains section headers, program headers, and a symbol table for radare2 inspection and PCSX2 loading.
  class ElfBuilder
    # ELF Constants
    ELFMAG = Bytes[0x7F, 0x45, 0x4C, 0x46] # \x7FELF
    ELFCLASS32 = 1_u8
    ELFDATA2LSB = 1_u8
    EV_CURRENT = 1_u8
    ELFOSABI_SYSV = 0_u8
    ET_EXEC = 2_u16
    EM_MIPS = 8_u16
    
    # MIPS R5900 flags: EF_MIPS_NOREORDER (1) | EF_MIPS_CPIC (4) | EF_MIPS_ARCH_R5900 (0x20924000)
    EF_MIPS_R5900 = 0x20924001_u32

    # Section Types
    SHT_NULL = 0_u32
    SHT_PROGBITS = 1_u32
    SHT_SYMTAB = 2_u32
    SHT_STRTAB = 3_u32
    SHT_NOBITS = 8_u32

    # Section Flags
    SHF_WRITE = 0x1_u32
    SHF_ALLOC = 0x2_u32
    SHF_EXECINSTR = 0x4_u32

    # Program Header Types
    PT_LOAD = 1_u32
    PF_R = 4_u32
    PF_W = 2_u32
    PF_X = 1_u32

    # Symbol Bind / Type
    STB_GLOBAL = 1_u8
    STT_FUNC = 2_u8
    STT_OBJECT = 1_u8

    record SymbolEntry, name : String, address : UInt32, size : UInt32, type : UInt8, binding : UInt8, section_idx : UInt16

    def self.build_default_runner_elf : Bytes
      builder = new
      builder.generate
    end

    def generate : Bytes
      # MIPS R5900 instructions for Citrine VM entry and stubs:
      # Citrine_VM_Run at 0x00100000:
      #   addiu $sp, $sp, -32
      #   sw $ra, 28($sp)
      #   li $v0, 0
      #   lw $ra, 28($sp)
      #   jr $ra
      #   addiu $sp, $sp, 32
      text_bytes = IO::Memory.new
      # Emit basic MIPS opcodes for entrypoint and native wrappers
      64.times do |i|
        # 0x27bdffe0 : addiu $sp, $sp, -32
        text_bytes.write_bytes(0x27bdffe0_u32, IO::ByteFormat::LittleEndian)
        # 0xafbf001c : sw $ra, 28($sp)
        text_bytes.write_bytes(0xafbf001c_u32, IO::ByteFormat::LittleEndian)
        # 0x24020000 : li $v0, 0
        text_bytes.write_bytes(0x24020000_u32, IO::ByteFormat::LittleEndian)
        # 0x8fbf001c : lw $ra, 28($sp)
        text_bytes.write_bytes(0x8fbf001c_u32, IO::ByteFormat::LittleEndian)
        # 0x03e00008 : jr $ra
        text_bytes.write_bytes(0x03e00008_u32, IO::ByteFormat::LittleEndian)
        # 0x27bd0020 : addiu $sp, $sp, 32
        text_bytes.write_bytes(0x27bd0020_u32, IO::ByteFormat::LittleEndian)
      end
      text_data = text_bytes.to_slice

      # Read-only data
      rodata_bytes = IO::Memory.new
      rodata_bytes.write("Citrine PS2 Virtual Machine runtime v0.1.0\0".to_slice)
      rodata_bytes.write("Emotion Engine R5900 / Graphic Synthesizer\0".to_slice)
      rodata_data = rodata_bytes.to_slice

      # Initialized Data
      data_bytes = IO::Memory.new
      data_bytes.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian) # g_spram_base
      data_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # g_citrine_vm
      data_data = data_bytes.to_slice

      # String table for symbol names (.strtab)
      strtab = IO::Memory.new
      strtab.write_byte(0_u8) # initial null byte

      add_str = ->(s : String) : UInt32 {
        offset = strtab.pos.to_u32
        strtab.write(s.to_slice)
        strtab.write_byte(0_u8)
        offset
      }

      # Symbols to export
      symbols = [
        SymbolEntry.new("_start", 0x00100000_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", 0x00100018_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_VM_Run", 0x00100030_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_InitWindow", 0x00100048_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_CloseWindow", 0x00100060_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_BeginDrawing", 0x00100078_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_EndDrawing", 0x00100090_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_ClearBackground", 0x001000A8_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawRectangle", 0x001000C0_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawCircle", 0x001000D8_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawLine", 0x001000F0_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawText", 0x00100108_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_BeginMode3D", 0x00100120_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_EndMode3D", 0x00100138_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawCube", 0x00100150_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawCubeWires", 0x00100168_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawGrid", 0x00100180_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawMesh", 0x00100198_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_LoadTexture", 0x001001B0_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawTexture", 0x001001C8_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_ButtonDown", 0x001001E0_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_ButtonPressed", 0x001001F8_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_GetAnalog", 0x00100210_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_SetRumble", 0x00100228_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_LoadSound", 0x00100240_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_PlaySound", 0x00100258_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("citrine_vm_panic", 0x00100270_u32, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("g_spram_base", 0x70000000_u32, 16384_u32, STT_OBJECT, STB_GLOBAL, 4_u16),
        SymbolEntry.new("g_citrine_vm", 0x00200004_u32, 512_u32, STT_OBJECT, STB_GLOBAL, 3_u16)
      ]

      # Build .symtab binary data
      symtab = IO::Memory.new
      # Entry 0: STN_UNDEF
      16.times { symtab.write_byte(0_u8) }

      symbols.each do |sym|
        name_offset = add_str.call(sym.name)
        info = (sym.binding << 4) | (sym.type & 0xF)
        symtab.write_bytes(name_offset, IO::ByteFormat::LittleEndian) # st_name
        symtab.write_bytes(sym.address, IO::ByteFormat::LittleEndian)     # st_value
        symtab.write_bytes(sym.size, IO::ByteFormat::LittleEndian)        # st_size
        symtab.write_byte(info)                                           # st_info
        symtab.write_byte(0_u8)                                           # st_other
        symtab.write_bytes(sym.section_idx, IO::ByteFormat::LittleEndian) # st_shndx
      end

      symtab_data = symtab.to_slice
      strtab_data = strtab.to_slice

      # Section Header String Table (.shstrtab)
      shstrtab = IO::Memory.new
      shstrtab.write_byte(0_u8)
      add_shstr = ->(s : String) : UInt32 {
        offset = shstrtab.pos.to_u32
        shstrtab.write(s.to_slice)
        shstrtab.write_byte(0_u8)
        offset
      }

      sh_names = {
        null: 0_u32,
        text: add_shstr.call(".text"),
        rodata: add_shstr.call(".rodata"),
        data: add_shstr.call(".data"),
        spram: add_shstr.call(".spram"),
        symtab: add_shstr.call(".symtab"),
        strtab: add_shstr.call(".strtab"),
        shstrtab: add_shstr.call(".shstrtab")
      }
      shstrtab_data = shstrtab.to_slice

      # Layout calculation
      # ELF Header = 52 bytes
      # 2 Program Headers (32 bytes each) = 64 bytes
      # Offset starts at 52 + 64 = 116 bytes -> pad to 128 (0x80)
      offset_text = 0x80_u32
      offset_rodata = offset_text + text_data.size.to_u32
      offset_data = offset_rodata + rodata_data.size.to_u32
      offset_symtab = offset_data + data_data.size.to_u32
      offset_strtab = offset_symtab + symtab_data.size.to_u32
      offset_shstrtab = offset_strtab + strtab_data.size.to_u32
      shoff = (offset_shstrtab + shstrtab_data.size.to_u32 + 3) & ~3_u32 # 4-byte align section headers

      io = IO::Memory.new

      # 1. ELF Header (52 bytes)
      io.write(ELFMAG)
      io.write_byte(ELFCLASS32)
      io.write_byte(ELFDATA2LSB)
      io.write_byte(EV_CURRENT)
      io.write_byte(ELFOSABI_SYSV)
      8.times { io.write_byte(0_u8) } # e_ident padding

      io.write_bytes(ET_EXEC, IO::ByteFormat::LittleEndian)       # e_type
      io.write_bytes(EM_MIPS, IO::ByteFormat::LittleEndian)       # e_machine
      io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)         # e_version
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian)# e_entry
      io.write_bytes(52_u32, IO::ByteFormat::LittleEndian)        # e_phoff (immediately after ELF header)
      io.write_bytes(shoff, IO::ByteFormat::LittleEndian)         # e_shoff
      io.write_bytes(EF_MIPS_R5900, IO::ByteFormat::LittleEndian) # e_flags
      io.write_bytes(52_u16, IO::ByteFormat::LittleEndian)        # e_ehsize
      io.write_bytes(32_u16, IO::ByteFormat::LittleEndian)        # e_phentsize
      io.write_bytes(2_u16, IO::ByteFormat::LittleEndian)         # e_phnum (2 load segments)
      io.write_bytes(40_u16, IO::ByteFormat::LittleEndian)        # e_shentsize
      io.write_bytes(8_u16, IO::ByteFormat::LittleEndian)         # e_shnum (8 sections)
      io.write_bytes(7_u16, IO::ByteFormat::LittleEndian)         # e_shstrndx (section 7 is .shstrtab)

      # 2. Program Headers (2 x 32 bytes = 64 bytes)
      # PH 0: Code / Read-Only segment (.text + .rodata)
      io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)       # p_type
      io.write_bytes(offset_text, IO::ByteFormat::LittleEndian)   # p_offset
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian)# p_vaddr
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian)# p_paddr
      io.write_bytes((text_data.size + rodata_data.size).to_u32, IO::ByteFormat::LittleEndian) # p_filesz
      io.write_bytes((text_data.size + rodata_data.size).to_u32, IO::ByteFormat::LittleEndian) # p_memsz
      io.write_bytes(PF_R | PF_X, IO::ByteFormat::LittleEndian)   # p_flags
      io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)    # p_align

      # PH 1: Data segment (.data)
      io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)       # p_type
      io.write_bytes(offset_data, IO::ByteFormat::LittleEndian)   # p_offset
      io.write_bytes(0x00200000_u32, IO::ByteFormat::LittleEndian)# p_vaddr
      io.write_bytes(0x00200000_u32, IO::ByteFormat::LittleEndian)# p_paddr
      io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian) # p_filesz
      io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian) # p_memsz
      io.write_bytes(PF_R | PF_W, IO::ByteFormat::LittleEndian)   # p_flags
      io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)    # p_align

      # Pad to offset_text (0x80)
      while io.pos < offset_text
        io.write_byte(0_u8)
      end

      # Write section data
      io.write(text_data)
      io.write(rodata_data)
      io.write(data_data)
      io.write(symtab_data)
      io.write(strtab_data)
      io.write(shstrtab_data)

      # Pad to shoff
      while io.pos < shoff
        io.write_byte(0_u8)
      end

      # 3. Section Headers (8 x 40 bytes)
      # [0] NULL Section
      10.times { io.write_bytes(0_u32, IO::ByteFormat::LittleEndian) }

      # [1] .text
      io.write_bytes(sh_names[:text], IO::ByteFormat::LittleEndian)
      io.write_bytes(SHT_PROGBITS, IO::ByteFormat::LittleEndian)
      io.write_bytes(SHF_ALLOC | SHF_EXECINSTR, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian)
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
      io.write_bytes(0x00180000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(offset_rodata, IO::ByteFormat::LittleEndian)
      io.write_bytes(rodata_data.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

      # [3] .data
      io.write_bytes(sh_names[:data], IO::ByteFormat::LittleEndian)
      io.write_bytes(SHT_PROGBITS, IO::ByteFormat::LittleEndian)
      io.write_bytes(SHF_ALLOC | SHF_WRITE, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x00200000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(offset_data, IO::ByteFormat::LittleEndian)
      io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

      # [4] .spram (Scratchpad RAM at 0x70000000, 16KB)
      io.write_bytes(sh_names[:spram], IO::ByteFormat::LittleEndian)
      io.write_bytes(SHT_NOBITS, IO::ByteFormat::LittleEndian)
      io.write_bytes(SHF_ALLOC | SHF_WRITE, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(16384_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(16_u32, IO::ByteFormat::LittleEndian) # 16-byte aligned
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

      # [5] .symtab
      io.write_bytes(sh_names[:symtab], IO::ByteFormat::LittleEndian)
      io.write_bytes(SHT_SYMTAB, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(offset_symtab, IO::ByteFormat::LittleEndian)
      io.write_bytes(symtab_data.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(6_u32, IO::ByteFormat::LittleEndian) # Link to .strtab (section 6)
      io.write_bytes(1_u32, IO::ByteFormat::LittleEndian) # One local symbol (entry 0)
      io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(16_u32, IO::ByteFormat::LittleEndian) # Entry size = 16 bytes

      # [6] .strtab
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

      # [7] .shstrtab
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
