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
        Circle
        Line
        Triangle
        Text
      end
      getter type : Type
      getter x1 : Int32
      getter y1 : Int32
      getter x2 : Int32
      getter y2 : Int32
      getter x3 : Int32
      getter y3 : Int32
      getter radius : Int32
      getter color : UInt32
      getter text : String

      def initialize(
        @type : Type,
        @x1 : Int32 = 0,
        @y1 : Int32 = 0,
        @x2 : Int32 = 0,
        @y2 : Int32 = 0,
        @x3 : Int32 = 0,
        @y3 : Int32 = 0,
        @radius : Int32 = 0,
        @color : UInt32 = 0_u32,
        @text : String = ""
      )
      end
    end

    struct Phase
      getter commands : Array(DrawCommand)
      getter delay_frames : UInt32

      def initialize(@commands : Array(DrawCommand), @delay_frames : UInt32 = 0_u32)
      end
    end

    TEXT_SIZE = 4096_u32
    RODATA_VADDR = 0x00100000_u32 + TEXT_SIZE

    ZERO = 0
    V0 = 2; V1 = 3
    A0 = 4; A1 = 5; A2 = 6; A3 = 7
    T0 = 8; T1 = 9; T2 = 10; T3 = 11; T4 = 12; T5 = 13; T6 = 14; T7 = 15
    S0 = 16; S1 = 17; S2 = 18; S3 = 19; S4 = 20; S5 = 21; S6 = 22; S7 = 23
    T8 = 24; T9 = 25
    SP = 29; RA = 31

    class MipsEmitter
      property base_vaddr : UInt32
      getter words = [] of UInt32
      getter labels = {} of String => UInt32
      getter fixups = [] of Tuple(Int32, String, Symbol)

      def initialize(@base_vaddr = 0x00100000_u32)
      end

      def label(name : String)
        @labels[name] = @base_vaddr + (@words.size.to_u32 * 4)
      end

      def emit(word : UInt32)
        @words << word
      end

      def nop
        emit(0x00000000_u32)
      end

      def lui(rt : Int32, imm : Int32)
        emit((0x0F_u32 << 26) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def ori(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0D_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def andi(rt : Int32, rs : Int32, imm : Int32)
        emit((0x0C_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def addiu(rt : Int32, rs : Int32, imm : Int32)
        emit((0x09_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16) | ((imm & 0xFFFF).to_u32))
      end

      def or_(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x25_u32)
      end

      def dsll32(rd : Int32, rt : Int32, sa : Int32)
        emit((rt.to_u32 << 16) | (rd.to_u32 << 11) | (sa.to_u32 << 6) | 0x3C_u32)
      end

      def lw(rt : Int32, offset : Int32, base : Int32)
        emit((0x23_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sw(rt : Int32, offset : Int32, base : Int32)
        emit((0x2B_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def ld(rt : Int32, offset : Int32, base : Int32)
        emit((0x37_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sd(rt : Int32, offset : Int32, base : Int32)
        emit((0x3F_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def lbu(rt : Int32, offset : Int32, base : Int32)
        emit((0x24_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def sb(rt : Int32, offset : Int32, base : Int32)
        emit((0x28_u32 << 26) | (base.to_u32 << 21) | (rt.to_u32 << 16) | ((offset & 0xFFFF).to_u32))
      end

      def subu(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x23_u32)
      end

      def addu(rd : Int32, rs : Int32, rt : Int32)
        emit((rs.to_u32 << 21) | (rt.to_u32 << 16) | (rd.to_u32 << 11) | 0x21_u32)
      end

      def move(rd : Int32, rs : Int32)
        or_(rd, rs, ZERO)
      end

      def jr(rs : Int32)
        emit((rs.to_u32 << 21) | 0x08_u32)
      end

      def syscall_inst
        emit(0x0000000C_u32)
      end

      def j(target_label : String)
        @fixups << {@words.size, target_label, :j}
        emit(0x08000000_u32)
      end

      def jal(target_label : String)
        @fixups << {@words.size, target_label, :jal}
        emit(0x0C000000_u32)
      end

      def bnez(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bnez}
        emit((0x05_u32 << 26) | (rs.to_u32 << 21))
      end

      def beqz(rs : Int32, target_label : String)
        @fixups << {@words.size, target_label, :beqz}
        emit((0x04_u32 << 26) | (rs.to_u32 << 21))
      end

      def bne(rs : Int32, rt : Int32, target_label : String)
        @fixups << {@words.size, target_label, :bne}
        emit((0x05_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16))
      end

      def beq(rs : Int32, rt : Int32, target_label : String)
        @fixups << {@words.size, target_label, :beq}
        emit((0x04_u32 << 26) | (rs.to_u32 << 21) | (rt.to_u32 << 16))
      end

      def resolve!
        @fixups.each do |idx, label_name, type|
          target_vaddr = @labels[label_name]? || raise "Unknown label: #{label_name}"
          inst_vaddr = @base_vaddr + (idx.to_u32 * 4)

          case type
          when :j
            @words[idx] = 0x08000000_u32 | ((target_vaddr >> 2) & 0x03FFFFFF_u32)
          when :jal
            @words[idx] = 0x0C000000_u32 | ((target_vaddr >> 2) & 0x03FFFFFF_u32)
          when :bnez, :beqz, :bne, :beq
            offset_bytes = target_vaddr.to_i32 - (inst_vaddr.to_i32 + 4)
            offset_insts = offset_bytes // 4
            @words[idx] = (@words[idx] & 0xFFFF0000_u32) | ((offset_insts & 0xFFFF).to_u32)
          end
        end
      end

      def pad_to(byte_size : Int32)
        while @words.size * 4 < byte_size
          nop
        end
      end

      def to_slice : Bytes
        io = IO::Memory.new(@words.size * 4)
        @words.each do |w|
          io.write_bytes(w, IO::ByteFormat::LittleEndian)
        end
        io.to_slice
      end
    end

    def self.build_default_runner_elf(cbc_bytes : Bytes? = nil) : Bytes
      builder = new
      builder.generate(cbc_bytes)
    end

    def generate(cbc_bytes : Bytes? = nil) : Bytes
      phases, debug_messages = parse_cbc(cbc_bytes)

      # Build GIF Packets
      env_packet = build_env_packet
      phase_packets = phases.map { |p| build_draw_packet(p.commands) }
      phase_qwcs = phase_packets.map { |pkt| (pkt.size // 16).to_u16 }

      env_qwc = (env_packet.size // 16).to_u16

      rodata_vaddr = RODATA_VADDR
      env_addr = rodata_vaddr
      curr_addr = env_addr + env_packet.size.to_u32

      phase_addrs = [] of UInt32
      phase_packets.each do |pkt|
        phase_addrs << curr_addr
        curr_addr += pkt.size.to_u32
      end

      # String addresses in .rodata
      banner_str = "[CITRINE] PS2 EE Engine Initialized\n\0"
      banner_addr = curr_addr
      curr_addr += banner_str.bytesize.to_u32

      debug_msg_addrs = [] of UInt32
      debug_messages.each do |msg|
        debug_msg_addrs << curr_addr
        curr_addr += (msg.bytesize + 2).to_u32 # msg + "\n\0"
      end

      emitter = MipsEmitter.new(0x00100000_u32)

      # Function 0 (_start at 0x00100000, 32 bytes):
      phase0_delay = phases[0].delay_frames
      emitter.label("_start")
      emitter.lui(SP, 0x0200)
      emitter.addiu(SP, SP, -16)
      emitter.lui(T0, 0x7000)
      emitter.lui(T1, 0xDEAD)
      emitter.ori(T1, T1, 0xBEEF)
      emitter.sw(T1, 0, T0)
      emitter.sw(ZERO, 4, T0)       # frame counter = 0
      emitter.sw(ZERO, 8, T0)       # phase index = 0
      emitter.lui(T1, (phase0_delay >> 16).to_i32)
      emitter.ori(T1, T1, (phase0_delay & 0xFFFF).to_i32)
      emitter.sw(T1, 12, T0)      # phase frames remaining
      emitter.j("main")
      emitter.nop

      # Function 1 (main at 0x00100020):
      emitter.label("main")
      emitter.addiu(SP, SP, -32)
      emitter.sw(RA, 28, SP)
      emitter.jal("dma_reset")
      emitter.nop

      # Reset GS: GS_CSR at 0x12001000
      emitter.lui(V1, 0x1200)
      emitter.ori(V1, V1, 0x1000)
      emitter.ori(V0, ZERO, 0x200)
      emitter.sd(V0, 0, V1)

      # Syscall _GsPutIMR(0xff00)
      emitter.ori(V1, ZERO, 0x71)
      emitter.lui(A0, 0x0000)
      emitter.ori(A0, A0, 0xff00)
      emitter.syscall_inst
      emitter.nop

      # Syscall _SetGsCrt(1, 2, 0) - Interlaced, NTSC, Field
      emitter.ori(V1, ZERO, 0x02)
      emitter.ori(A0, ZERO, 1)
      emitter.ori(A1, ZERO, 2)
      emitter.ori(A2, ZERO, 0)
      emitter.syscall_inst
      emitter.nop

      # Configure GS registers:
      emitter.lui(V1, 0x1200)

      # GS_PMODE at 0x12000000: 0xff65 (Circuit 1 enable, CRTMD=1, MMOD=1, AMOD=1, ALP=0xFF)
      emitter.lui(V0, 0x0000)
      emitter.ori(V0, V0, 0xff65)
      emitter.sd(V0, 0, V1)

      # GS_DISPFB1 at 0x12000070 and GS_DISPFB2 at 0x12000090: 0x1400 (FBP=0, FBW=10 [640 px], PSM=0 [PSMCT32])
      emitter.ori(V0, ZERO, 0x1400)
      emitter.sd(V0, 0x70, V1)
      emitter.sd(V0, 0x90, V1)

      # GS_DISPLAY1 at 0x12000080 and GS_DISPLAY2 at 0x120000A0: 0x001bf9ff01832290 (NTSC Field mode dy=50 centered)
      emitter.lui(T1, 0x001b)
      emitter.ori(T1, T1, 0xf9ff)
      emitter.dsll32(T1, T1, 0)
      emitter.lui(V0, 0x0183)
      emitter.ori(V0, V0, 0x2290)
      emitter.or_(T1, T1, V0)
      emitter.sd(T1, 0x80, V1)
      emitter.sd(T1, 0xa0, V1)

      # GS_BGCOLOR at 0x120000E0: 0x00000000 (Pure black background)
      emitter.sd(ZERO, 0xe0, V1)

      # Emit boot banner via debug_puts:
      emitter.lui(A0, (banner_addr >> 16).to_i32)
      emitter.ori(A0, A0, (banner_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop

      # Emit debug messages via debug_puts:
      debug_msg_addrs.each do |msg_addr|
        emitter.lui(A0, (msg_addr >> 16).to_i32)
        emitter.ori(A0, A0, (msg_addr & 0xFFFF).to_i32)
        emitter.jal("debug_puts")
        emitter.nop
      end

      # Send Environment Setup Packet (env_addr, env_qwc)
      emitter.jal("dma02_wait")
      emitter.nop
      emitter.lui(T8, 0x1000)
      emitter.ori(T8, T8, 0xa000)
      emitter.lui(T7, (env_addr >> 16).to_i32)
      emitter.ori(T7, T7, (env_addr & 0xFFFF).to_i32)
      emitter.sw(T7, 0x10, T8)
      emitter.ori(T6, ZERO, env_qwc.to_i32)
      emitter.sw(T6, 0x20, T8)
      emitter.ori(T6, ZERO, 0x101)
      emitter.sw(T6, 0x00, T8)
      emitter.jal("dma02_wait")
      emitter.nop

      # Frame Loop:
      emitter.label("frame_loop")
      # Increment frame counter in SPRAM at 0x70000004
      emitter.lui(T0, 0x7000)
      emitter.lw(T1, 4, T0)
      emitter.addiu(T1, T1, 1)
      emitter.sw(T1, 4, T0)

      if phases.size == 1
        emitter.lui(T7, (phase_addrs[0] >> 16).to_i32)
        emitter.ori(T7, T7, (phase_addrs[0] & 0xFFFF).to_i32)
        emitter.ori(T6, ZERO, phase_qwcs[0].to_i32)
      else
        emitter.lw(T2, 8, T0) # phase index
        phases.each_with_index do |phase, i|
          if i < phases.size - 1
            emitter.ori(T3, ZERO, i)
            emitter.bne(T2, T3, "check_phase_#{i + 1}")
            emitter.nop
          end
          emitter.lui(T7, (phase_addrs[i] >> 16).to_i32)
          emitter.ori(T7, T7, (phase_addrs[i] & 0xFFFF).to_i32)
          emitter.ori(T6, ZERO, phase_qwcs[i].to_i32)
          if i < phases.size - 1
            emitter.j("send_dma")
            emitter.nop
            emitter.label("check_phase_#{i + 1}")
          end
        end
        emitter.label("send_dma")
      end

      emitter.jal("dma02_wait")
      emitter.nop
      emitter.lui(T8, 0x1000)
      emitter.ori(T8, T8, 0xa000)
      emitter.sw(T7, 0x10, T8)
      emitter.sw(T6, 0x20, T8)
      emitter.ori(T5, ZERO, 0x101)
      emitter.sw(T5, 0x00, T8)
      emitter.jal("dma02_wait")
      emitter.nop

      # VSync wait loop (GS_CSR bit 3):
      emitter.lui(V1, 0x1200)
      emitter.ori(V1, V1, 0x1000)
      emitter.ori(V0, ZERO, 8)
      emitter.sd(V0, 0, V1)        # Clear VSINT with 64-bit store
      emitter.lui(T1, 0x0002)       # Timeout counter (~131072 iterations)

      emitter.label("vsync_spin")
      emitter.ld(V0, 0, V1)        # 64-bit load from GS_CSR
      emitter.andi(V0, V0, 8)
      emitter.bnez(V0, "vsync_done")
      emitter.addiu(T1, T1, -1)     # branch delay slot: decrement counter
      emitter.bnez(T1, "vsync_spin")
      emitter.nop                  # branch delay slot

      emitter.label("vsync_done")

      if phases.size > 1
        emitter.lui(T0, 0x7000)
        emitter.lw(T4, 12, T0) # frames remaining
        emitter.beqz(T4, "loop_continue")
        emitter.nop
        emitter.addiu(T4, T4, -1)
        emitter.sw(T4, 12, T0)
        emitter.bnez(T4, "loop_continue")
        emitter.nop

        # Timer hit 0! Advance to next phase
        emitter.lw(T2, 8, T0) # phase index
        emitter.addiu(T2, T2, 1)
        emitter.ori(T3, ZERO, phases.size)
        emitter.bne(T2, T3, "phase_clamped")
        emitter.nop
        emitter.addiu(T2, T3, -1) # clamp to last phase

        emitter.label("phase_clamped")
        emitter.sw(T2, 8, T0)

        phases.each_with_index do |phase, i|
          if i < phases.size - 1
            emitter.ori(T3, ZERO, i)
            emitter.bne(T2, T3, "check_delay_#{i + 1}")
            emitter.nop
          end
          emitter.lui(T4, (phase.delay_frames >> 16).to_i32)
          emitter.ori(T4, T4, (phase.delay_frames & 0xFFFF).to_i32)
          emitter.sw(T4, 12, T0)
          if i < phases.size - 1
            emitter.j("loop_continue")
            emitter.nop
            emitter.label("check_delay_#{i + 1}")
          end
        end

        emitter.label("loop_continue")
      end

      emitter.j("frame_loop")
      emitter.nop

      # Subroutine dma02_wait:
      emitter.label("dma02_wait")
      emitter.lui(T8, 0x1000)
      emitter.ori(T8, T8, 0xa000)
      emitter.label("dma02_wait_loop")
      emitter.lw(T9, 0, T8)
      emitter.andi(T9, T9, 0x100)
      emitter.bnez(T9, "dma02_wait_loop")
      emitter.nop
      emitter.jr(RA)
      emitter.nop

      # Subroutine dma_reset:
      emitter.label("dma_reset")
      emitter.lui(T8, 0x1000)
      emitter.ori(T8, T8, 0xa000)
      emitter.sw(ZERO, 0, T8)
      emitter.sw(ZERO, 0x10, T8)
      emitter.sw(ZERO, 0x30, T8)
      emitter.sw(ZERO, 0x40, T8)
      emitter.sw(ZERO, 0x50, T8)
      emitter.lui(T7, 0x1000)
      emitter.ori(T7, T7, 0xe000)
      emitter.ori(T6, ZERO, 0xff1f)
      emitter.sw(T6, 0x10, T7)
      emitter.sw(ZERO, 0, T7)
      emitter.sw(ZERO, 0x20, T7)
      emitter.sw(ZERO, 0x30, T7)
      emitter.sw(ZERO, 0x40, T7)
      emitter.sw(ZERO, 0x50, T7)
      emitter.lw(T6, 0, T7)
      emitter.ori(T6, T6, 1)
      emitter.sw(T6, 0, T7)
      emitter.jr(RA)
      emitter.nop

      # Subroutine debug_puts:
      # Writes null-terminated string at $a0 to SIO UART and invokes syscall 0x75 (PCSX2 BIOS Print)
      emitter.label("debug_puts")
      emitter.addiu(SP, SP, -32)
      emitter.sw(RA, 28, SP)
      emitter.sw(S0, 24, SP)
      emitter.sw(A0, 20, SP)

      # 1. Output string to EE SIO (UART at 0x1000f180) byte-by-byte
      emitter.lui(T8, 0x1000)
      emitter.ori(T8, T8, 0xf180)
      emitter.move(S0, A0)

      emitter.label("sio_loop")
      emitter.lbu(T6, 0, S0)
      emitter.beqz(T6, "sio_done")
      emitter.nop
      emitter.sb(T6, 0, T8)
      emitter.addiu(S0, S0, 1)
      emitter.j("sio_loop")
      emitter.nop

      emitter.label("sio_done")

      # 2. Syscall 0x75 (PCSX2 SYSCALL_print)
      emitter.lw(A0, 20, SP)
      emitter.ori(V1, ZERO, 0x75)
      emitter.syscall_inst
      emitter.nop

      emitter.lw(RA, 28, SP)
      emitter.lw(S0, 24, SP)
      emitter.jr(RA)
      emitter.addiu(SP, SP, 32)

      # Native API stubs (Citrine_VM_Run, etc.)
      stub_start = 0x00100000_u32 + (emitter.words.size.to_u32 * 4)
      60.times do
        emitter.addiu(SP, SP, -32)
        emitter.sw(RA, 28, SP)
        emitter.ori(V0, ZERO, 0)
        emitter.lw(RA, 28, SP)
        emitter.jr(RA)
        emitter.addiu(SP, SP, 32)
      end

      # Pad .text to 4096 bytes (0x1000)
      emitter.pad_to(TEXT_SIZE.to_i32)
      emitter.resolve!
      text_data = emitter.to_slice

      # .rodata segment
      rodata_bytes = IO::Memory.new
      rodata_bytes.write(env_packet)
      phase_packets.each do |pkt|
        rodata_bytes.write(pkt)
      end
      rodata_bytes.write(banner_str.to_slice)
      debug_messages.each do |msg|
        rodata_bytes.write("#{msg}\n\0".to_slice)
      end
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
        SymbolEntry.new("_start", emitter.labels["_start"], (emitter.labels["main"] - emitter.labels["_start"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", emitter.labels["main"], (emitter.labels["dma02_wait"] - emitter.labels["main"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma02_wait", emitter.labels["dma02_wait"], (emitter.labels["dma_reset"] - emitter.labels["dma02_wait"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma_reset", emitter.labels["dma_reset"], (emitter.labels["debug_puts"] - emitter.labels["dma_reset"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("debug_puts", emitter.labels["debug_puts"], (stub_start - emitter.labels["debug_puts"]), STT_FUNC, STB_GLOBAL, 1_u16),
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
      mem = IO::Memory.new(224)
      # GIFTag: NLOOP=13, EOP=1, PRE=0, PRIM=0, FLG=PACKED(0), NREG=1, REGS=0x0E (A+D)
      mem.write_bytes(0x100000000000800d_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x0e_u64, IO::ByteFormat::LittleEndian)

      # 1. FRAME_1 (0x4C): FBP=0, FBW=10 (640), PSM=0 (PSMCT32), FBMSK=0
      mem.write_bytes(0x000a0000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x4c_u64, IO::ByteFormat::LittleEndian)

      # 2. FRAME_2 (0x4D): FBP=0, FBW=10 (640), PSM=0 (PSMCT32), FBMSK=0
      mem.write_bytes(0x000a0000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x4d_u64, IO::ByteFormat::LittleEndian)

      # 3. ZBUF_1 (0x4E): ZBP=140, PSM=0, ZMSK=1 (Mask Z writes)
      mem.write_bytes(0x000000010000008c_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x4e_u64, IO::ByteFormat::LittleEndian)

      # 4. ZBUF_2 (0x4F): ZBP=140, PSM=0, ZMSK=1 (Mask Z writes)
      mem.write_bytes(0x000000010000008c_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x4f_u64, IO::ByteFormat::LittleEndian)

      # 5. XYOFFSET_1 (0x18): OFX=0, OFY=0 (Direct pixel coordinate space)
      mem.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x18_u64, IO::ByteFormat::LittleEndian)

      # 6. XYOFFSET_2 (0x19): OFX=0, OFY=0
      mem.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x19_u64, IO::ByteFormat::LittleEndian)

      # 7. SCISSOR_1 (0x40): X0=0, X1=639, Y0=0, Y1=447
      sciss = (447_u64 << 48) | (639_u64 << 16)
      mem.write_bytes(sciss, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x40_u64, IO::ByteFormat::LittleEndian)

      # 8. SCISSOR_2 (0x41)
      mem.write_bytes(sciss, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x41_u64, IO::ByteFormat::LittleEndian)

      # 9. PRMODECONT (0x1A): 1 (Use attributes from PRIM register)
      mem.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x1a_u64, IO::ByteFormat::LittleEndian)

      # 10. COLCLAMP (0x46): 1
      mem.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x46_u64, IO::ByteFormat::LittleEndian)

      # 11. DTHE (0x45): 0
      mem.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x45_u64, IO::ByteFormat::LittleEndian)

      # 12. TEST_1 (0x47): ZTE=1, ZTST=1 (ALLPASS - unconditional pass)
      mem.write_bytes(0x00030000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x47_u64, IO::ByteFormat::LittleEndian)

      # 13. TEST_2 (0x48): ZTE=1, ZTST=1 (ALLPASS)
      mem.write_bytes(0x00030000_u64, IO::ByteFormat::LittleEndian)
      mem.write_bytes(0x48_u64, IO::ByteFormat::LittleEndian)

      mem.to_slice
    end

    private def build_draw_packet(commands : Array(DrawCommand)) : Bytes
      body = IO::Memory.new

      commands.each do |cmd|
        r = (cmd.color & 0xFF).to_u8
        g = ((cmd.color >> 8) & 0xFF).to_u8
        b = ((cmd.color >> 16) & 0xFF).to_u8
        case cmd.type
        when DrawCommand::Type::Clear
          emit_quad(body, 0, 0, 640, 448, r, g, b)
        when DrawCommand::Type::Rect
          emit_quad(body, cmd.x1, cmd.y1, cmd.x2, cmd.y2, r, g, b)
        when DrawCommand::Type::Circle
          emit_circle(body, cmd.x1, cmd.y1, cmd.radius, r, g, b)
        when DrawCommand::Type::Line
          emit_line(body, cmd.x1, cmd.y1, cmd.x2, cmd.y2, r, g, b)
        when DrawCommand::Type::Triangle
          emit_triangle(body, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x3, cmd.y3, r, g, b)
        when DrawCommand::Type::Text
          scale = cmd.x2 >= 20 ? 2 : 1
          emit_text(body, cmd.text, cmd.x1, cmd.y1, scale, r, g, b)
        end
      end

      total_items = (body.pos // 16).to_u32
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
      gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian) # Register 0x0D = XYZ3 (queue without kick)
      gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
      io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)    # Register 0x05 = XYZ2 (queue and kick draw)
    end

    private def emit_line(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
      emit_single_line(io, x1, y1, x2, y2, r, g, b, a)
      if (x2 - x1).abs > (y2 - y1).abs
        emit_single_line(io, x1, y1 + 1, x2, y2 + 1, r, g, b, a)
      else
        emit_single_line(io, x1 + 1, y1, x2 + 1, y2, r, g, b, a)
      end
    end

    private def emit_single_line(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
      io.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u64, IO::ByteFormat::LittleEndian) # PRIM (0x00) = Line (1)
      rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
      io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
      io.write_bytes(1_u64, IO::ByteFormat::LittleEndian) # RGBAQ (0x01)
      gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian) # XYZ3 (0x0D)
      gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
      io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)    # XYZ2 (0x05)
    end

    private def emit_circle(io : IO::Memory, cx : Int32, cy : Int32, radius : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
      segments = 24
      segments.times do |i|
        a1 = (i.to_f64 / segments) * 2.0 * ::Math::PI
        a2 = ((i + 1).to_f64 / segments) * 2.0 * ::Math::PI
        px1 = (cx + radius * ::Math.cos(a1)).round.to_i
        py1 = (cy + radius * ::Math.sin(a1)).round.to_i
        px2 = (cx + radius * ::Math.cos(a2)).round.to_i
        py2 = (cy + radius * ::Math.sin(a2)).round.to_i

        emit_triangle(io, cx, cy, px1, py1, px2, py2, r, g, b, a)
      end
    end

    private def emit_triangle(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, x3 : Int32, y3 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
      io.write_bytes(3_u64, IO::ByteFormat::LittleEndian)
      io.write_bytes(0_u64, IO::ByteFormat::LittleEndian) # PRIM (0x00) = Triangle (3)
      rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
      io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
      io.write_bytes(1_u64, IO::ByteFormat::LittleEndian) # RGBAQ (0x01)
      gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian) # XYZ3 (0x0D)
      gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
      io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian) # XYZ3 (0x0D)
      gs_x3 = ((x3.to_i64 << 4) & 0xFFFF_i64).to_u64
      gs_y3 = ((y3.to_i64 << 4) & 0xFFFF_i64).to_u64
      io.write_bytes((gs_y3 << 16) | gs_x3, IO::ByteFormat::LittleEndian)
      io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)    # XYZ2 (0x05)
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

    def parse_cbc(cbc_bytes : Bytes?) : Tuple(Array(Phase), Array(String))
      debug_messages = [] of String
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
              constants << CVal.new(ctype, (v.to_i64 & 0xFFFFFFFF_u64).to_u32)
            when 5 # Color
              v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, v)
            when 6 # StringRef
              s_idx = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32, strings[s_idx]? || "")
            when 3 # Float32
              f = io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, (f.to_i32.to_i64 & 0xFFFFFFFF_u64).to_u32)
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

          instructions_start_pos = io.pos

          main_fn = fns.find { |f| strings[f.name_idx]? == "__main__" }
          if main_fn
            io.pos = instructions_start_pos + (main_fn.offset.to_i64 * 4)
            instructions = [] of UInt32
            main_fn.count.times do
              instructions << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            end

            regs = Array(Int64).new(256, 0_i64)
            current_commands = [] of DrawCommand
            phases = [] of Phase
            pc = 0
            max_steps = 10000
            steps = 0
            first_frame_done = false

            while pc >= 0 && pc < instructions.size && steps < max_steps && !first_frame_done
              steps += 1
              instr = instructions[pc]
              opcode = (instr >> 24) & 0xFF
              dst = ((instr >> 16) & 0xFF).to_i
              a = ((instr >> 8) & 0xFF).to_i
              b = (instr & 0xFF).to_i
              imm16 = (instr & 0xFFFF).to_i64
              val16 = (instr & 0xFFFF).to_i32
              imm16_signed = (val16 >= 0x8000 ? val16 - 0x10000 : val16).to_i64

              pc += 1

              case opcode
              when 0 # Nop
              when 1 # Move
                regs[dst] = regs[a]
              when 2 # LoadNil
                regs[dst] = 0_i64
              when 3 # LoadBool
                regs[dst] = imm16
              when 4 # LoadInt
                regs[dst] = imm16
              when 5 # LoadConst
                regs[dst] = imm16
              when 10 # Add
                regs[dst] = regs[a] + regs[b]
              when 11 # Sub
                regs[dst] = regs[a] - regs[b]
              when 12 # Mul
                regs[dst] = regs[a] * regs[b]
              when 13 # Div
                regs[dst] = regs[b] != 0 ? (regs[a] // regs[b]) : 0_i64
              when 14 # Mod
                regs[dst] = regs[b] != 0 ? (regs[a] % regs[b]) : 0_i64
              when 15 # Neg
                regs[dst] = -regs[a]
              when 30 # Eq
                regs[dst] = (regs[a] == regs[b]) ? 1_i64 : 0_i64
              when 31 # Ne
                regs[dst] = (regs[a] != regs[b]) ? 1_i64 : 0_i64
              when 32 # Lt
                regs[dst] = (regs[a] < regs[b]) ? 1_i64 : 0_i64
              when 33 # Le
                regs[dst] = (regs[a] <= regs[b]) ? 1_i64 : 0_i64
              when 34 # Gt
                regs[dst] = (regs[a] > regs[b]) ? 1_i64 : 0_i64
              when 35 # Ge
                regs[dst] = (regs[a] >= regs[b]) ? 1_i64 : 0_i64
              when 40 # Jump
                target_pc = pc + imm16_signed
                if imm16_signed < 0 && target_pc >= 0 && target_pc < instructions.size
                  target_instr = instructions[target_pc]
                  target_opcode = (target_instr >> 24) & 0xFF
                  target_native = target_instr & 0xFF
                  if target_opcode == 52 && target_native == 3
                    if phases.empty?
                      phases << Phase.new(current_commands.dup, 0_u32)
                      first_frame_done = true
                    end
                  end
                end
                pc += imm16_signed
              when 41 # JumpIfTrue
                pc += imm16_signed if regs[dst] != 0
              when 42 # JumpIfFalse
                pc += imm16_signed if regs[dst] == 0
              when 51 # Return
                break
              when 70 # Halt
                break
              when 52 # CallNative
                base = a
                native_id = b

                case native_id
                when 3 # WindowOpen
                  regs[dst] = 1_i64
                when 40, 41, 42 # ButtonDown, ButtonPressed, ButtonReleased
                  regs[dst] = 0_i64
                when 11 # EndDrawing
                  if current_commands.size > 0
                    phases << Phase.new(current_commands.dup, 0_u32)
                    first_frame_done = true
                  end
                when 12 # ClearBackground
                  c_idx = regs[base].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0_u32
                  current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: color)
                when 20 # DrawRectangle
                  x = regs[base].to_i
                  y = regs[base + 1].to_i
                  w = regs[base + 2].to_i
                  h = regs[base + 3].to_i
                  c_idx = regs[base + 4].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  current_commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x + w, y + h, color: color)
                when 21 # DrawCircle
                  cx = regs[base].to_i
                  cy = regs[base + 1].to_i
                  radius = regs[base + 2].to_i
                  c_idx = regs[base + 3].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  current_commands << DrawCommand.new(DrawCommand::Type::Circle, cx, cy, 0, 0, 0, 0, radius: radius, color: color)
                when 22 # DrawLine
                  x1 = regs[base].to_i
                  y1 = regs[base + 1].to_i
                  x2 = regs[base + 2].to_i
                  y2 = regs[base + 3].to_i
                  c_idx = regs[base + 4].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  current_commands << DrawCommand.new(DrawCommand::Type::Line, x1, y1, x2, y2, color: color)
                when 23 # DrawTriangle
                  x1 = regs[base].to_i
                  y1 = regs[base + 1].to_i
                  x2 = regs[base + 2].to_i
                  y2 = regs[base + 3].to_i
                  x3 = regs[base + 4].to_i
                  y3 = regs[base + 5].to_i
                  c_idx = regs[base + 6].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  current_commands << DrawCommand.new(DrawCommand::Type::Triangle, x1, y1, x2, y2, x3, y3, color: color)
                when 24 # DrawText
                  t_idx = regs[base].to_i
                  text = constants[t_idx]?.try(&.str_val) || ""
                  x = regs[base + 1].to_i
                  y = regs[base + 2].to_i
                  size = regs[base + 3].to_i
                  c_idx = regs[base + 4].to_i
                  color = constants[c_idx]?.try(&.u32_val) || 0xFFFFFFFF_u32
                  current_commands << DrawCommand.new(DrawCommand::Type::Text, x, y, size, 0, color: color, text: text)
                when 65 # Sleep(seconds)
                  sec = regs[base].to_i
                  sec = 1 if sec <= 0
                  delay_frames = (sec * 60).to_u32
                  phases << Phase.new(current_commands.dup, delay_frames)
                  if phases.size >= 4
                    first_frame_done = true
                  end
                when 70, 71 # Log / puts / print / debug_puts / debug_log
                  t_idx = regs[base].to_i
                  text = constants[t_idx]?.try(&.str_val) || ""
                  unless text.empty?
                    debug_messages << text
                  end
                  if current_commands.empty?
                    current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32)
                  end
                  y_pos = 60 + (current_commands.count { |c| c.type == DrawCommand::Type::Text } * 28)
                  current_commands << DrawCommand.new(DrawCommand::Type::Text, 60, y_pos, 20, 0, color: 0xFFFFFFFF_u32, text: text)
                when 99 # Panic
                  t_idx = regs[base].to_i
                  text = constants[t_idx]?.try(&.str_val) || "Citrine PS2 VM Panic"
                  debug_messages << "[CITRINE PANIC] #{text}"
                end
              end
            end

            if phases.empty?
              if current_commands.empty?
                current_commands = [
                  DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32),
                  DrawCommand.new(DrawCommand::Type::Text, 60, 60, 20, 0, color: 0xFFFFFFFF_u32, text: "Hello, world!")
                ]
              end
              phases << Phase.new(current_commands, 0_u32)
            elsif current_commands.size > phases.last.commands.size
              phases << Phase.new(current_commands.dup, 0_u32)
            end

            return {phases, debug_messages} if phases.size > 0
          end
        rescue ex
          STDERR.puts "[parse_cbc Exception] #{ex.class}: #{ex.message}\n#{ex.backtrace.join("\n")}"
        end
      end

      # Default Citrine PS2 fallback screen
      fallback_phases = [
        Phase.new([
          DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32),
          DrawCommand.new(DrawCommand::Type::Text, 60, 60, 20, 0, color: 0xFFFFFFFF_u32, text: "Hello, world!")
        ], 0_u32)
      ]
      {fallback_phases, debug_messages}
    end
  end
end
