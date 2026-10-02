require "io/memory"

module Citrine
  # Generates a valid 32-bit Little-Endian MIPS R5900 PlayStation 2 ELF executable.
  # Boots directly on Sony PlayStation 2 (PCSX2 or real EE hardware), sets up the
  # Graphic Synthesizer (GS) via DMA Channel 2 (GIF) to 640x448 NTSC, rasterizes
  # Citrine draw commands, and loops on VSync.
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

    struct CVal
      property type : UInt8
      property u32_val : UInt32
      property str_val : String
      def initialize(@type : UInt8, @u32_val : UInt32 = 0_u32, @str_val : String = "")
      end
    end

    struct FnEntry
      property name_idx : UInt32
      property argc : UInt8
      property num_regs : UInt8
      property offset : UInt32
      property count : UInt32
      def initialize(@name_idx, @argc, @num_regs, @offset, @count)
      end
    end

    FONT_5X7 = {
      ' ' => [0x00, 0x00, 0x00, 0x00, 0x00],
      '!' => [0x00, 0x00, 0x5F, 0x00, 0x00],
      '"' => [0x00, 0x07, 0x00, 0x07, 0x00],
      '#' => [0x14, 0x7F, 0x14, 0x7F, 0x14],
      '$' => [0x24, 0x2A, 0x7F, 0x2A, 0x12],
      '%' => [0x23, 0x13, 0x08, 0x64, 0x62],
      '&' => [0x36, 0x49, 0x55, 0x22, 0x50],
      '\'' => [0x00, 0x05, 0x03, 0x00, 0x00],
      '(' => [0x00, 0x1C, 0x22, 0x41, 0x00],
      ')' => [0x00, 0x41, 0x22, 0x1C, 0x00],
      '*' => [0x14, 0x08, 0x3E, 0x08, 0x14],
      '+' => [0x08, 0x08, 0x3E, 0x08, 0x08],
      ',' => [0x00, 0x50, 0x30, 0x00, 0x00],
      '-' => [0x08, 0x08, 0x08, 0x08, 0x08],
      '.' => [0x00, 0x60, 0x60, 0x00, 0x00],
      '/' => [0x20, 0x10, 0x08, 0x04, 0x02],
      '0' => [0x3E, 0x51, 0x49, 0x45, 0x3E],
      '1' => [0x00, 0x42, 0x7F, 0x40, 0x00],
      '2' => [0x42, 0x61, 0x51, 0x49, 0x46],
      '3' => [0x21, 0x41, 0x45, 0x4B, 0x31],
      '4' => [0x18, 0x14, 0x12, 0x7F, 0x10],
      '5' => [0x27, 0x45, 0x45, 0x45, 0x39],
      '6' => [0x3C, 0x4A, 0x49, 0x49, 0x30],
      '7' => [0x01, 0x71, 0x09, 0x05, 0x03],
      '8' => [0x36, 0x49, 0x49, 0x49, 0x36],
      '9' => [0x06, 0x49, 0x49, 0x29, 0x1E],
      ':' => [0x00, 0x36, 0x36, 0x00, 0x00],
      ';' => [0x00, 0x56, 0x36, 0x00, 0x00],
      '<' => [0x08, 0x14, 0x22, 0x41, 0x00],
      '=' => [0x14, 0x14, 0x14, 0x14, 0x14],
      '>' => [0x00, 0x41, 0x22, 0x14, 0x08],
      '?' => [0x02, 0x01, 0x51, 0x09, 0x06],
      '@' => [0x32, 0x49, 0x79, 0x41, 0x3E],
      'A' => [0x7E, 0x11, 0x11, 0x11, 0x7E],
      'B' => [0x7F, 0x49, 0x49, 0x49, 0x36],
      'C' => [0x3E, 0x41, 0x41, 0x41, 0x22],
      'D' => [0x7F, 0x41, 0x41, 0x22, 0x1C],
      'E' => [0x7F, 0x49, 0x49, 0x49, 0x41],
      'F' => [0x7F, 0x09, 0x09, 0x09, 0x01],
      'G' => [0x3E, 0x41, 0x49, 0x49, 0x7A],
      'H' => [0x7F, 0x08, 0x08, 0x08, 0x7F],
      'I' => [0x00, 0x41, 0x7F, 0x41, 0x00],
      'J' => [0x20, 0x40, 0x41, 0x3F, 0x01],
      'K' => [0x7F, 0x08, 0x14, 0x22, 0x41],
      'L' => [0x7F, 0x40, 0x40, 0x40, 0x40],
      'M' => [0x7F, 0x02, 0x0C, 0x02, 0x7F],
      'N' => [0x7F, 0x04, 0x08, 0x10, 0x7F],
      'O' => [0x3E, 0x41, 0x41, 0x41, 0x3E],
      'P' => [0x7F, 0x09, 0x09, 0x09, 0x06],
      'Q' => [0x3E, 0x41, 0x51, 0x21, 0x5E],
      'R' => [0x7F, 0x09, 0x19, 0x29, 0x46],
      'S' => [0x46, 0x49, 0x49, 0x49, 0x31],
      'T' => [0x01, 0x01, 0x7F, 0x01, 0x01],
      'U' => [0x3F, 0x40, 0x40, 0x40, 0x3F],
      'V' => [0x1F, 0x20, 0x40, 0x20, 0x1F],
      'W' => [0x7F, 0x20, 0x18, 0x20, 0x7F],
      'X' => [0x63, 0x14, 0x08, 0x14, 0x63],
      'Y' => [0x07, 0x08, 0x70, 0x08, 0x07],
      'Z' => [0x61, 0x51, 0x49, 0x45, 0x43],
      '[' => [0x00, 0x7F, 0x41, 0x41, 0x00],
      '\\' => [0x02, 0x04, 0x08, 0x10, 0x20],
      ']' => [0x00, 0x41, 0x41, 0x7F, 0x00],
      '^' => [0x04, 0x02, 0x01, 0x02, 0x04],
      '_' => [0x40, 0x40, 0x40, 0x40, 0x40],
      '|' => [0x00, 0x00, 0x7F, 0x00, 0x00],
    }

    struct DrawCommand
      enum Type
        Clear
        Rect
        Text
      end
      getter type : Type
      getter x1 : Int32
      getter y1 : Int32
      getter x2 : Int32
      getter y2 : Int32
      getter color : UInt32
      getter text : String

      def initialize(@type : Type, @x1 : Int32 = 0, @y1 : Int32 = 0, @x2 : Int32 = 0, @y2 : Int32 = 0, @color : UInt32 = 0_u32, @text : String = "")
      end
    end

    def self.build_default_runner_elf(cbc_bytes : Bytes? = nil) : Bytes
      builder = new
      builder.generate(cbc_bytes)
    end

    def generate(cbc_bytes : Bytes? = nil) : Bytes
      draw_commands = parse_cbc(cbc_bytes)

      # Build GIF Packets
      env_packet = build_env_packet
      draw_packet = build_draw_packet(draw_commands)

      env_qwc = (env_packet.size // 16).to_u16
      draw_qwc = (draw_packet.size // 16).to_u16

      # Text code buffer
      text_bytes = IO::Memory.new

      # Function 0 (_start at 0x00100000, 32 bytes):
      #   lui   $sp, 0x0200        # $sp = 0x02000000
      #   addiu $sp, $sp, -16      # $sp = 0x01FFFFF0
      #   lui   $t0, 0x7000        # $t0 = 0x70000000 (SPRAM base)
      #   lui   $t1, 0xDEAD
      #   ori   $t1, $t1, 0xBEEF   # $t1 = 0xDEADBEEF
      #   sw    $t1, 0($t0)        # SPRAM canary
      #   j     0x00100020         # jump to main
      #   nop
      text_bytes.write_bytes(0x3c1d0200_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x27bdfff0_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3c087000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3c09dead_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3529beef_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xad090000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x08040008_u32, IO::ByteFormat::LittleEndian) # j 0x00100020
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)

      # Section layout:
      # .text starts at 0x00100000, length will be padded to 1024 bytes (0x400)
      # So .rodata starts at 0x00100400
      rodata_vaddr = 0x00100400_u32
      env_addr = rodata_vaddr
      draw_addr = env_addr + env_packet.size.to_u32

      # Function 1 (main at 0x00100020):
      #   addiu $sp, $sp, -32
      #   sw    $ra, 28($sp)
      #   jal   dma_reset (at 0x00100158) -> jump target 0x00100158 >> 2 = 0x040056
      #   nop
      text_bytes.write_bytes(0x27bdffe0_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xafbf001c_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x0c040056_u32, IO::ByteFormat::LittleEndian) # jal 0x00100158
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)

      # Reset GS: GS_CSR at 0x12001000
      #   lui   $v1, 0x1200
      #   ori   $v1, $v1, 0x1000
      #   ori   $v0, $zero, 0x200
      #   sd    $v0, 0($v1)
      text_bytes.write_bytes(0x3c031200_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x34631000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x34020200_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xfc620000_u32, IO::ByteFormat::LittleEndian) # sd $v0, 0($v1)

      # Syscall _GsPutIMR(0xff00)
      #   ori   $v1, $zero, 0x71
      #   lui   $a0, 0x0000
      #   ori   $a0, $a0, 0xff00
      #   syscall
      #   nop
      text_bytes.write_bytes(0x34030071_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3c040000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3484ff00_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x0000000c_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)

      # Syscall _SetGsCrt(1, 2, 0) - Interlaced, NTSC, Field
      #   ori   $v1, $zero, 0x02
      #   ori   $a0, $zero, 1
      #   ori   $a1, $zero, 2
      #   ori   $a2, $zero, 0
      #   syscall
      #   nop
      text_bytes.write_bytes(0x34030002_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x34040001_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x34050002_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x34060000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x0000000c_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)

      # Configure GS registers:
      #   lui   $v1, 0x1200
      text_bytes.write_bytes(0x3c031200_u32, IO::ByteFormat::LittleEndian)

      # GS_PMODE at 0x12000000: 0xff62 (Circuit 2 enable, MMOD=1, AMOD=1, ALP=0xFF)
      #   ori   $v0, $zero, 0xff62
      #   sd    $v0, 0($v1)
      text_bytes.write_bytes(0x3402ff62_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xfc620000_u32, IO::ByteFormat::LittleEndian)

      # GS_DISPFB2 at 0x12000090: 0x1400 (FBP=0, FBW=10 [640 px], PSM=0 [PSMCT32])
      #   ori   $v0, $zero, 0x1400
      #   sd    $v0, 0x90($v1)
      text_bytes.write_bytes(0x34021400_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xfc620090_u32, IO::ByteFormat::LittleEndian)

      # GS_DISPLAY2 at 0x120000A0: 0x001bf9ff01824290 (DX=656, DY=36, MAGH=3, MAGV=0, DW=2559, DH=447)
      #   lui   $t1, 0x001b
      #   ori   $t1, $t1, 0xf9ff
      #   dsll32 $t1, $t1, 0
      #   lui   $v0, 0x0182
      #   ori   $v0, $v0, 0x4290
      #   or    $t1, $t1, $v0
      #   sd    $t1, 0xa0($v1)
      text_bytes.write_bytes(0x3c09001b_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3529f9ff_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x0009483c_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3c020182_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x34424290_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x01224825_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xfc6900a0_u32, IO::ByteFormat::LittleEndian)

      # GS_BGCOLOR at 0x120000E0: 0x0018141f (Citrine dark navy)
      #   lui   $v0, 0x0018
      #   ori   $v0, $v0, 0x141f
      #   sd    $v0, 0xe0($v1)
      text_bytes.write_bytes(0x3c020018_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3442141f_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0xfc6200e0_u32, IO::ByteFormat::LittleEndian)

      # Send Environment Setup Packet (env_addr, env_qwc)
      #   jal   dma02_wait (at 0x00100138 -> 0x0c04004e)
      #   nop
      #   lui   $t8, 0x1000
      #   ori   $t8, $t8, 0xa000
      #   lui   $t7, (env_addr >> 16)
      #   ori   $t7, $t7, (env_addr & 0xFFFF)
      #   sw    $t7, 0x10($t8)
      #   ori   $t6, $zero, env_qwc
      #   sw    $t6, 0x20($t8)
      #   ori   $t6, $zero, 0x101
      #   sw    $t6, 0x00($t8)
      #   jal   dma02_wait
      #   nop
      text_bytes.write_bytes(0x0c04004e_u32, IO::ByteFormat::LittleEndian) # jal 0x00100138
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3c181000_u32, IO::ByteFormat::LittleEndian) # lui $t8, 0x1000
      text_bytes.write_bytes(0x3718a000_u32, IO::ByteFormat::LittleEndian) # ori $t8, $t8, 0xa000
      text_bytes.write_bytes((0x3c0f0000_u32 | (env_addr >> 16)), IO::ByteFormat::LittleEndian) # lui $t7, hi
      text_bytes.write_bytes((0x35ef0000_u32 | (env_addr & 0xFFFF)), IO::ByteFormat::LittleEndian) # ori $t7, lo
      text_bytes.write_bytes(0xaf0f0010_u32, IO::ByteFormat::LittleEndian) # sw $t7, 0x10($t8)
      text_bytes.write_bytes((0x340e0000_u32 | env_qwc), IO::ByteFormat::LittleEndian) # ori $t6, $zero, env_qwc
      text_bytes.write_bytes(0xaf0e0020_u32, IO::ByteFormat::LittleEndian) # sw $t6, 0x20($t8)
      text_bytes.write_bytes(0x340e0101_u32, IO::ByteFormat::LittleEndian) # ori $t6, $zero, 0x101
      text_bytes.write_bytes(0xaf0e0000_u32, IO::ByteFormat::LittleEndian) # sw $t6, 0x00($t8)
      text_bytes.write_bytes(0x0c04004e_u32, IO::ByteFormat::LittleEndian) # jal 0x00100138
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)

      # Frame Loop (at 0x001000DC):
      #   jal   dma02_wait (0x00100138)
      #   nop
      #   lui   $t8, 0x1000
      #   ori   $t8, $t8, 0xa000
      #   lui   $t7, (draw_addr >> 16)
      #   ori   $t7, $t7, (draw_addr & 0xFFFF)
      #   sw    $t7, 0x10($t8)
      #   ori   $t6, $zero, draw_qwc
      #   sw    $t6, 0x20($t8)
      #   ori   $t6, $zero, 0x101
      #   sw    $t6, 0x00($t8)
      #   jal   dma02_wait
      #   nop
      #
      # VSync Wait (GS_CSR bit 3):
      #   lui   $v1, 0x1200
      #   ori   $v1, $v1, 0x1000
      #   ori   $v0, $zero, 8
      #   sw    $v0, 0($v1)
      # vsync_spin:
      #   lw    $v0, 0($v1)
      #   andi  $v0, $v0, 8
      #   beqz  $v0, -3 (vsync_spin)
      #   nop
      #   j     0x001000dc (frame_loop)
      #   nop
      text_bytes.write_bytes(0x0c04004e_u32, IO::ByteFormat::LittleEndian) # jal 0x00100138
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)
      text_bytes.write_bytes(0x3c181000_u32, IO::ByteFormat::LittleEndian) # lui $t8, 0x1000
      text_bytes.write_bytes(0x3718a000_u32, IO::ByteFormat::LittleEndian) # ori $t8, $t8, 0xa000
      text_bytes.write_bytes((0x3c0f0000_u32 | (draw_addr >> 16)), IO::ByteFormat::LittleEndian) # lui $t7, hi
      text_bytes.write_bytes((0x35ef0000_u32 | (draw_addr & 0xFFFF)), IO::ByteFormat::LittleEndian) # ori $t7, lo
      text_bytes.write_bytes(0xaf0f0010_u32, IO::ByteFormat::LittleEndian) # sw $t7, 0x10($t8)
      text_bytes.write_bytes((0x340e0000_u32 | draw_qwc), IO::ByteFormat::LittleEndian) # ori $t6, $zero, draw_qwc
      text_bytes.write_bytes(0xaf0e0020_u32, IO::ByteFormat::LittleEndian) # sw $t6, 0x20($t8)
      text_bytes.write_bytes(0x340e0101_u32, IO::ByteFormat::LittleEndian) # ori $t6, $zero, 0x101
      text_bytes.write_bytes(0xaf0e0000_u32, IO::ByteFormat::LittleEndian) # sw $t6, 0x00($t8)
      text_bytes.write_bytes(0x0c04004e_u32, IO::ByteFormat::LittleEndian) # jal 0x00100138
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)

      # VSync wait loop
      text_bytes.write_bytes(0x3c031200_u32, IO::ByteFormat::LittleEndian) # lui $v1, 0x1200
      text_bytes.write_bytes(0x34631000_u32, IO::ByteFormat::LittleEndian) # ori $v1, $v1, 0x1000
      text_bytes.write_bytes(0x34020008_u32, IO::ByteFormat::LittleEndian) # ori $v0, $zero, 8
      text_bytes.write_bytes(0xac620000_u32, IO::ByteFormat::LittleEndian) # sw $v0, 0($v1)
      text_bytes.write_bytes(0x8c620000_u32, IO::ByteFormat::LittleEndian) # lw $v0, 0($v1)
      text_bytes.write_bytes(0x30420008_u32, IO::ByteFormat::LittleEndian) # andi $v0, $v0, 8
      text_bytes.write_bytes(0x1040fffd_u32, IO::ByteFormat::LittleEndian) # beqz $v0, -3
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # nop
      text_bytes.write_bytes(0x08040037_u32, IO::ByteFormat::LittleEndian) # j 0x001000dc (frame_loop)
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # nop

      # Subroutine dma02_wait at 0x00100138 (32 bytes):
      text_bytes.write_bytes(0x3c181000_u32, IO::ByteFormat::LittleEndian) # lui $t8, 0x1000
      text_bytes.write_bytes(0x3718a000_u32, IO::ByteFormat::LittleEndian) # ori $t8, $t8, 0xa000
      text_bytes.write_bytes(0x8f190000_u32, IO::ByteFormat::LittleEndian) # lw $t9, 0($t8)
      text_bytes.write_bytes(0x33390100_u32, IO::ByteFormat::LittleEndian) # andi $t9, $t9, 0x100
      text_bytes.write_bytes(0x1720fffd_u32, IO::ByteFormat::LittleEndian) # bnez $t9, -3
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # nop
      text_bytes.write_bytes(0x03e00008_u32, IO::ByteFormat::LittleEndian) # jr $ra
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # nop

      # Subroutine dma_reset at 0x00100158 (84 bytes):
      text_bytes.write_bytes(0x3c181000_u32, IO::ByteFormat::LittleEndian) # lui $t8, 0x1000
      text_bytes.write_bytes(0x3718a000_u32, IO::ByteFormat::LittleEndian) # ori $t8, $t8, 0xa000
      text_bytes.write_bytes(0xaf000000_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0($t8)
      text_bytes.write_bytes(0xaf000010_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x10($t8)
      text_bytes.write_bytes(0xaf000030_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x30($t8)
      text_bytes.write_bytes(0xaf000040_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x40($t8)
      text_bytes.write_bytes(0xaf000050_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x50($t8)
      text_bytes.write_bytes(0x3c0f1000_u32, IO::ByteFormat::LittleEndian) # lui $t7, 0x1000
      text_bytes.write_bytes(0x35efe000_u32, IO::ByteFormat::LittleEndian) # ori $t7, $t7, 0xe000
      text_bytes.write_bytes(0x340eff1f_u32, IO::ByteFormat::LittleEndian) # ori $t6, $zero, 0xff1f
      text_bytes.write_bytes(0xaf0e0010_u32, IO::ByteFormat::LittleEndian) # sw $t6, 0x10($t7)
      text_bytes.write_bytes(0xaf000000_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0($t7)
      text_bytes.write_bytes(0xaf000020_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x20($t7)
      text_bytes.write_bytes(0xaf000030_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x30($t7)
      text_bytes.write_bytes(0xaf000040_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x40($t7)
      text_bytes.write_bytes(0xaf000050_u32, IO::ByteFormat::LittleEndian) # sw $zero, 0x50($t7)
      text_bytes.write_bytes(0x8f0e0000_u32, IO::ByteFormat::LittleEndian) # lw $t6, 0($t7)
      text_bytes.write_bytes(0x35ce0001_u32, IO::ByteFormat::LittleEndian) # ori $t6, $t6, 1
      text_bytes.write_bytes(0xaf0e0000_u32, IO::ByteFormat::LittleEndian) # sw $t6, 0($t7)
      text_bytes.write_bytes(0x03e00008_u32, IO::ByteFormat::LittleEndian) # jr $ra
      text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # nop

      # Native API stubs (Citrine_VM_Run, etc. starting at 0x001001AC)
      stub_start = text_bytes.pos.to_u32 + 0x00100000_u32
      60.times do
        text_bytes.write_bytes(0x27bdffe0_u32, IO::ByteFormat::LittleEndian) # addiu $sp, $sp, -32
        text_bytes.write_bytes(0xafbf001c_u32, IO::ByteFormat::LittleEndian) # sw $ra, 28($sp)
        text_bytes.write_bytes(0x24020000_u32, IO::ByteFormat::LittleEndian) # li $v0, 0
        text_bytes.write_bytes(0x8fbf001c_u32, IO::ByteFormat::LittleEndian) # lw $ra, 28($sp)
        text_bytes.write_bytes(0x03e00008_u32, IO::ByteFormat::LittleEndian) # jr $ra
        text_bytes.write_bytes(0x27bd0020_u32, IO::ByteFormat::LittleEndian) # addiu $sp, $sp, 32
      end

      # Pad .text to 1024 bytes (0x400)
      while text_bytes.pos < 1024
        text_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian)
      end
      text_data = text_bytes.to_slice

      # .rodata segment
      rodata_bytes = IO::Memory.new
      rodata_bytes.write(env_packet)
      rodata_bytes.write(draw_packet)
      rodata_bytes.write("Citrine PS2 Virtual Machine runtime v0.1.0\0".to_slice)
      rodata_bytes.write("Emotion Engine R5900 / Graphic Synthesizer\0".to_slice)
      rodata_data = rodata_bytes.to_slice

      # .data segment
      data_bytes = IO::Memory.new
      data_bytes.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian) # g_spram_base
      data_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # g_citrine_vm
      data_data = data_bytes.to_slice

      # .strtab
      strtab = IO::Memory.new
      strtab.write_byte(0_u8)
      add_str = ->(s : String) : UInt32 {
        off = strtab.pos.to_u32
        strtab.write(s.to_slice)
        strtab.write_byte(0_u8)
        off
      }

      symbols = [
        SymbolEntry.new("_start", 0x00100000_u32, 32_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", 0x00100020_u32, 280_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma02_wait", 0x00100138_u32, 32_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma_reset", 0x00100158_u32, 84_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_VM_Run", stub_start, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_InitWindow", stub_start + 24, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_CloseWindow", stub_start + 48, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_BeginDrawing", stub_start + 72, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_EndDrawing", stub_start + 96, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_ClearBackground", stub_start + 120, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawRectangle", stub_start + 144, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawCircle", stub_start + 168, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawLine", stub_start + 192, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawText", stub_start + 216, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_BeginMode3D", stub_start + 240, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_EndMode3D", stub_start + 264, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawCube", stub_start + 288, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawCubeWires", stub_start + 312, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawGrid", stub_start + 336, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawMesh", stub_start + 360, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_LoadTexture", stub_start + 384, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_DrawTexture", stub_start + 408, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_ButtonDown", stub_start + 432, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_ButtonPressed", stub_start + 456, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_GetAnalog", stub_start + 480, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_SetRumble", stub_start + 504, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_LoadSound", stub_start + 528, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("Citrine_PlaySound", stub_start + 552, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("citrine_vm_panic", stub_start + 576, 24_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("g_spram_base", 0x70000000_u32, 16384_u32, STT_OBJECT, STB_GLOBAL, 4_u16),
        SymbolEntry.new("g_citrine_vm", 0x00200004_u32, 512_u32, STT_OBJECT, STB_GLOBAL, 3_u16)
      ]

      symtab = IO::Memory.new
      16.times { symtab.write_byte(0_u8) } # Entry 0: STN_UNDEF

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

      # Layout
      offset_text = 0x80_u32
      offset_rodata = offset_text + text_data.size.to_u32
      offset_data = offset_rodata + rodata_data.size.to_u32
      offset_symtab = offset_data + data_data.size.to_u32
      offset_strtab = offset_symtab + symtab_data.size.to_u32
      offset_shstrtab = offset_strtab + strtab_data.size.to_u32
      shoff = (offset_shstrtab + shstrtab_data.size.to_u32 + 3) & ~3_u32

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
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian) # e_entry
      io.write_bytes(52_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(shoff, IO::ByteFormat::LittleEndian)
      io.write_bytes(EF_MIPS_R5900, IO::ByteFormat::LittleEndian)
      io.write_bytes(52_u16, IO::ByteFormat::LittleEndian)
      io.write_bytes(32_u16, IO::ByteFormat::LittleEndian)
      io.write_bytes(2_u16, IO::ByteFormat::LittleEndian) # 2 load segments
      io.write_bytes(40_u16, IO::ByteFormat::LittleEndian)
      io.write_bytes(8_u16, IO::ByteFormat::LittleEndian) # 8 sections
      io.write_bytes(7_u16, IO::ByteFormat::LittleEndian) # shstrndx = 7

      # Program Headers
      # PH 0: Code / Read-Only (.text + .rodata)
      io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)
      io.write_bytes(offset_text, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x00100000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes((text_data.size + rodata_data.size).to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes((text_data.size + rodata_data.size).to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(PF_R | PF_X, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)

      # PH 1: Data (.data)
      io.write_bytes(PT_LOAD, IO::ByteFormat::LittleEndian)
      io.write_bytes(offset_data, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x00200000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x00200000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(data_data.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(PF_R | PF_W, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x1000_u32, IO::ByteFormat::LittleEndian)

      while io.pos < offset_text
        io.write_byte(0_u8)
      end

      io.write(text_data)
      io.write(rodata_data)
      io.write(data_data)
      io.write(symtab_data)
      io.write(strtab_data)
      io.write(shstrtab_data)

      while io.pos < shoff
        io.write_byte(0_u8)
      end

      # Section Headers (8 x 40 bytes)
      # [0] NULL
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
      io.write_bytes(rodata_vaddr, IO::ByteFormat::LittleEndian)
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

      # [4] .spram
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

      # [5] .symtab
      io.write_bytes(sh_names[:symtab], IO::ByteFormat::LittleEndian)
      io.write_bytes(SHT_SYMTAB, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(offset_symtab, IO::ByteFormat::LittleEndian)
      io.write_bytes(symtab_data.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(6_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(4_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(16_u32, IO::ByteFormat::LittleEndian)

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

    private def build_env_packet : Bytes
      mem = IO::Memory.new(160)
      mem.write_bytes(0x1000000000008009_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x0e_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x000a0000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x4c_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x0000008c_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x4e_u64, IO::ByteFormat::LittleEndian)
      xyoff = (30976_u64 << 32) | 27648_u64
      mem.write_bytes(xyoff, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x18_u64, IO::ByteFormat::LittleEndian)
      sciss = (447_u64 << 48) | (639_u64 << 16)
      mem.write_bytes(sciss, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x40_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x1a_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x46_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x45_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x70000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x47_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x30000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x47_u64, IO::ByteFormat::LittleEndian)
      mem.to_slice
    end

    private def build_draw_packet(commands : Array(DrawCommand)) : Bytes
      body = IO::Memory.new
      quad_count = 0

      commands.each do |cmd|
        case cmd.type
        when DrawCommand::Type::Clear
          r = (cmd.color & 0xFF).to_u8
          g = ((cmd.color >> 8) & 0xFF).to_u8
          b = ((cmd.color >> 16) & 0xFF).to_u8
          emit_quad(body, 0, 0, 640, 448, r, g, b)
          quad_count += 1
        when DrawCommand::Type::Rect
          r = (cmd.color & 0xFF).to_u8
          g = ((cmd.color >> 8) & 0xFF).to_u8
          b = ((cmd.color >> 16) & 0xFF).to_u8
          emit_quad(body, cmd.x1, cmd.y1, cmd.x2, cmd.y2, r, g, b)
          quad_count += 1
        when DrawCommand::Type::Text
          r = (cmd.color & 0xFF).to_u8
          g = ((cmd.color >> 8) & 0xFF).to_u8
          b = ((cmd.color >> 16) & 0xFF).to_u8
          scale = cmd.x2 > 18 ? 2 : 1
          quad_count += emit_text(body, cmd.text, cmd.x1, cmd.y1, scale, r, g, b)
        end
      end

      total_items = (quad_count * 4).to_u32
      packet = IO::Memory.new
      gif_tag = (1_u64 << 60) | (1_u64 << 15) | (total_items.to_u64 & 0x7FFF)
      packet.write_bytes(gif_tag, IO::ByteFormat::LittleEndian)
      packet.write_bytes(0x0e_u64, IO::ByteFormat::LittleEndian)
      packet.write(body.to_slice)
      packet.to_slice
    end

    private def emit_quad(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
      io.write_bytes(6_u64, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
      rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
      io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
      io.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
      gs_x1 = ((1728 + x1) << 4) & 0xFFFF
      gs_y1 = ((1936 + y1) << 4) & 0xFFFF
      io.write_bytes((gs_y1.to_u64 << 16) | gs_x1.to_u64, IO::ByteFormat::LittleEndian)
      io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)
      gs_x2 = ((1728 + x2) << 4) & 0xFFFF
      gs_y2 = ((1936 + y2) << 4) & 0xFFFF
      io.write_bytes((gs_y2.to_u64 << 16) | gs_x2.to_u64, IO::ByteFormat::LittleEndian)
      io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)
    end

    private def emit_text(io : IO::Memory, text : String, start_x : Int32, start_y : Int32, scale : Int32, r : UInt8, g : UInt8, b : UInt8) : Int32
      quad_count = 0
      cx = start_x
      cy = start_y
      char_w = 5 * scale
      spacing = 2 * scale

      text.each_char do |ch|
        if ch == ' '
          cx += char_w + spacing
          next
        end

        glyph = FONT_5X7[ch.upcase]? || FONT_5X7['?']
        7.times do |row|
          in_run = false
          run_start = 0
          5.times do |col|
            pixel = ((glyph[col] >> row) & 1) == 1
            if pixel && !in_run
              in_run = true
              run_start = col
            elsif !pixel && in_run
              in_run = false
              x1 = cx + run_start * scale
              x2 = cx + col * scale
              y1 = cy + row * scale
              y2 = y1 + scale
              emit_quad(io, x1, y1, x2, y2, r, g, b)
              quad_count += 1
            end
          end
          if in_run
            x1 = cx + run_start * scale
            x2 = cx + 5 * scale
            y1 = cy + row * scale
            y2 = y1 + scale
            emit_quad(io, x1, y1, x2, y2, r, g, b)
            quad_count += 1
          end
        end

        cx += char_w + spacing
      end

      quad_count
    end

    private def parse_cbc(cbc_bytes : Bytes?) : Array(DrawCommand)
      if cbc_bytes && cbc_bytes.size > 20 && String.new(cbc_bytes[0..3]) == "CBC1"
        begin
          io = IO::Memory.new(cbc_bytes)
          io.read_string(4) # "CBC1"
          io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
          num_fns = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          num_consts = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          num_strings = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

          strings = [] of String
          num_strings.times do
            len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            strings << io.read_string(len)
          end

          constants = [] of CVal
          num_consts.times do
            ctype = io.read_byte.not_nil!
            case ctype
            when 2 # Int32
              v = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, v.to_u32)
            when 5 # Color
              v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, v)
            when 6 # StringRef
              s_idx = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32, strings[s_idx]? || "")
            when 3 # Float32
              f = io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, f.to_i32.to_u32)
            when 4 # Vec2
              io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32)
            when 1 # Bool
              b = io.read_byte.not_nil!
              constants << CVal.new(ctype, b.to_u32)
            else
              io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32)
            end
          end

          fns = [] of FnEntry
          num_fns.times do
            n_idx = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            argc = io.read_byte.not_nil!
            num_regs = io.read_byte.not_nil!
            off = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            cnt = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            fns << FnEntry.new(n_idx, argc, num_regs, off, cnt)
          end

          main_fn = fns.find { |f| strings[f.name_idx]? == "__main__" }
          if main_fn
            instructions = [] of UInt32
            main_fn.count.times do
              instructions << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            end

            regs = Array(UInt32).new(32, 0_u32)
            commands = [] of DrawCommand

            instructions.each do |instr|
              opcode = (instr >> 24) & 0xFF
              dst = ((instr >> 16) & 0xFF).to_i
              a = ((instr >> 8) & 0xFF).to_i
              b = (instr & 0xFF).to_i
              imm16 = instr & 0xFFFF

              case opcode
              when 4 # LoadInt
                regs[dst] = imm16.to_u32
              when 5 # LoadConst
                regs[dst] = imm16.to_u32
              when 52 # CallNative
                base = a
                native_id = b
                step = (base + 1 < 32 && regs[base + 1] != 0) ? 1 : -1

                case native_id
                when 12 # ClearBackground
                  c_idx = regs[base].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0_u32
                  commands << DrawCommand.new(DrawCommand::Type::Clear, color: color)
                when 20 # DrawRectangle
                  x = regs[base].to_i
                  y = regs[base + step].to_i
                  w = regs[base + 2 * step].to_i
                  h = regs[base + 3 * step].to_i
                  c_idx = regs[base + 4 * step].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x + w, y + h, color: color)
                when 24 # DrawText
                  t_idx = regs[base].to_i
                  text = constants[t_idx]?.try(&.str_val) || ""
                  x = regs[base + step].to_i
                  y = regs[base + 2 * step].to_i
                  size = regs[base + 3 * step].to_i
                  c_idx = regs[base + 4 * step].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  commands << DrawCommand.new(DrawCommand::Type::Text, x, y, size, 0, color: color, text: text)
                end
              end
            end

            return commands if commands.size > 0
          end
        rescue ex
        end
      end

      # Default Citrine PS2 welcome card and information screen
      [
        DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32),
        DrawCommand.new(DrawCommand::Type::Rect, 40, 40, 600, 408, color: 0xFFFF0000_u32),
        DrawCommand.new(DrawCommand::Type::Rect, 44, 44, 596, 404, color: 0xFF000000_u32),
        DrawCommand.new(DrawCommand::Type::Rect, 120, 180, 520, 250, color: 0xFF0000FF_u32),
        DrawCommand.new(DrawCommand::Type::Text, 180, 80, 24, 0, color: 0xFF00FFFF_u32, text: "CITRINE PS2 TOOLKIT"),
        DrawCommand.new(DrawCommand::Type::Text, 110, 120, 16, 0, color: 0xFFFFFFFF_u32, text: "Crystal Virtual Machine for Sony PlayStation 2"),
        DrawCommand.new(DrawCommand::Type::Text, 150, 205, 20, 0, color: 0xFFFFFFFF_u32, text: "HELLO PLAYSTATION 2!"),
        DrawCommand.new(DrawCommand::Type::Text, 110, 280, 14, 0, color: 0xFF00FF00_u32, text: "Target: Sony Emotion Engine (R5900 @ 294MHz)"),
        DrawCommand.new(DrawCommand::Type::Text, 110, 305, 14, 0, color: 0xFF00FF00_u32, text: "Renderer: Graphic Synthesizer (GS 4MB eDRAM @ 147MHz)"),
        DrawCommand.new(DrawCommand::Type::Text, 110, 330, 14, 0, color: 0xFF00FF00_u32, text: "Memory: 32MB Main RAM | 16KB Scratchpad RAM (SPRAM)"),
        DrawCommand.new(DrawCommand::Type::Text, 230, 370, 14, 0, color: 0xFF00FFFF_u32, text: "Press START to proceed")
      ]
    end
  end
end
