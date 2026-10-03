require "io/memory"
require "../mips/mips_emitter"
require "../gs/gs_config"
require "../gs/gif_packet_builder"
require "../subsystems/controller"
require "./elf_writer"
require "./regex_engine"

module Citrine
  # Generates a valid 32-bit Little-Endian MIPS R5900 PlayStation 2 ELF executable.
  # Boots directly on Sony PlayStation 2 (PCSX2 or real EE hardware), sets up the
  # Graphic Synthesizer (GS) via DMA Channel 2 (GIF) to 640x448 NTSC, rasterizes
  # Citrine draw commands, and loops on VSync.
  class ElfBuilder
    # Backward compatibility aliases
    alias MipsEmitter      = Citrine::MIPS::MipsEmitter
    alias DrawCommand      = Citrine::GS::DrawCommand
    alias Phase            = Citrine::GS::Phase
    alias GifPacketBuilder = Citrine::GS::GifPacketBuilder
    alias ElfWriter        = Citrine::ISO::ElfWriter
    alias SymbolEntry      = Citrine::ISO::ElfWriter::SymbolDef

    # Register aliases
    ZERO = Citrine::MIPS::ZERO
    AT   = Citrine::MIPS::AT
    V0   = Citrine::MIPS::V0;  V1 = Citrine::MIPS::V1
    A0   = Citrine::MIPS::A0;  A1 = Citrine::MIPS::A1;  A2 = Citrine::MIPS::A2;  A3 = Citrine::MIPS::A3
    T0   = Citrine::MIPS::T0;  T1 = Citrine::MIPS::T1;  T2 = Citrine::MIPS::T2;  T3 = Citrine::MIPS::T3
    T4   = Citrine::MIPS::T4;  T5 = Citrine::MIPS::T5;  T6 = Citrine::MIPS::T6;  T7 = Citrine::MIPS::T7
    S0   = Citrine::MIPS::S0;  S1 = Citrine::MIPS::S1;  S2 = Citrine::MIPS::S2;  S3 = Citrine::MIPS::S3
    S4   = Citrine::MIPS::S4;  S5 = Citrine::MIPS::S5;  S6 = Citrine::MIPS::S6;  S7 = Citrine::MIPS::S7
    T8   = Citrine::MIPS::T8;  T9 = Citrine::MIPS::T9
    SP   = Citrine::MIPS::SP;  RA = Citrine::MIPS::RA; FP = Citrine::MIPS::FP
    STT_FUNC   = Citrine::ISO::ElfWriter::STT_FUNC
    STT_OBJECT = Citrine::ISO::ElfWriter::STT_OBJECT
    STB_GLOBAL = Citrine::ISO::ElfWriter::STB_GLOBAL

    TEXT_SIZE = 8192_u32
    RODATA_VADDR = 0x00100000_u32 + TEXT_SIZE

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

    struct CallFrame
      property return_pc : Int32
      property caller_instructions : Array(UInt32)
      property caller_dest : Int32
      property caller_reg_base : Int32
      def initialize(@return_pc, @caller_instructions, @caller_dest, @caller_reg_base)
      end
    end

    struct AllocationRecord
      property base_addr : Int64
      property size_bytes : Int32
      property context_name : String
      property freed : Bool
      property is_object : Bool
      property is_struct : Bool
      property field_count : Int32

      def initialize(@base_addr, @size_bytes, @context_name, @freed = false, @is_object = false, @is_struct = false, @field_count = 0)
      end
    end

    def self.build_default_runner_elf(cbc_bytes : Bytes? = nil, input_schedule : Array(VirtualInput) = [] of VirtualInput) : Bytes
      builder = new
      builder.generate(cbc_bytes, input_schedule)
    end

    def generate(cbc_bytes : Bytes? = nil, input_schedule : Array(VirtualInput) = [] of VirtualInput) : Bytes
      phases, boot_messages, loop_start_phase, is_animated, is_dvd_screensaver = parse_cbc(cbc_bytes)

      # Build GIF Packets
      env_packet = GifPacketBuilder.build_env_packet
      phase_packets = phases.map { |p| GifPacketBuilder.build_draw_packet(p.commands) }
      phase_qwcs = phase_packets.map { |pkt| (pkt.size // 16).to_u16 }

      env_qwc = (env_packet.size // 16).to_u16

      rodata_vaddr = RODATA_VADDR
      env_addr = rodata_vaddr
      curr_addr = env_addr + env_packet.size.to_u32

      static_dvd_addr = 0_u32
      static_dvd_qwc = 0_u16
      static_dvd_packet = Bytes.empty
      font_quad_addr = 0_u32
      font_quad_slice = Bytes.empty
      color_palette_addr = 0_u32
      color_palette_slice = Bytes.empty

      phase_addrs = [] of UInt32
      phase_table_slice = Bytes.empty
      phase_table_addr = 0_u32

      if is_dvd_screensaver
        static_cmds = [
          DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32),
          DrawCommand.new(DrawCommand::Type::Rect, 0, 0, 640, 6, color: 0xFF808080_u32),
          DrawCommand.new(DrawCommand::Type::Rect, 0, 442, 640, 6, color: 0xFF808080_u32),
          DrawCommand.new(DrawCommand::Type::Rect, 0, 0, 6, 448, color: 0xFF808080_u32),
          DrawCommand.new(DrawCommand::Type::Rect, 634, 0, 6, 448, color: 0xFF808080_u32),
          DrawCommand.new(DrawCommand::Type::Text, 60, 420, 14, 0, color: 0xFF00FFFF_u32, text: "CROSS: +1 | R1: +10 | TRIANGLE: RESET | STRESS TEST")
        ]
        static_dvd_packet = GifPacketBuilder.build_draw_packet(static_cmds)
        static_dvd_qwc = (static_dvd_packet.size // 16).to_u16
        static_dvd_addr = curr_addr
        curr_addr += static_dvd_packet.size.to_u32

        raw_fq = GifPacketBuilder.extract_text_glyph_quads("HELLO WORLD!", 2)
        fq_pad = (16 - (raw_fq.size % 16)) % 16
        if fq_pad > 0
          fq_mem = IO::Memory.new(raw_fq.size + fq_pad)
          fq_mem.write(raw_fq)
          fq_pad.times { fq_mem.write_byte(0_u8) }
          font_quad_slice = fq_mem.to_slice
        else
          font_quad_slice = raw_fq
        end
        font_quad_addr = curr_addr
        curr_addr += font_quad_slice.size.to_u32

        c_mem = IO::Memory.new(64)
        c_mem.write_bytes(0x3F800000_800000FF_u64, IO::ByteFormat::LittleEndian) # 0: Red
        c_mem.write_bytes(0x3F800000_8000FF00_u64, IO::ByteFormat::LittleEndian) # 1: Green
        c_mem.write_bytes(0x3F800000_80FF0000_u64, IO::ByteFormat::LittleEndian) # 2: Blue
        c_mem.write_bytes(0x3F800000_8000FFFF_u64, IO::ByteFormat::LittleEndian) # 3: Yellow
        c_mem.write_bytes(0x3F800000_80FFFF00_u64, IO::ByteFormat::LittleEndian) # 4: Cyan
        c_mem.write_bytes(0x3F800000_80FF00FF_u64, IO::ByteFormat::LittleEndian) # 5: Magenta
        c_mem.write_bytes(0x3F800000_80FFFFFF_u64, IO::ByteFormat::LittleEndian) # 6: White
        c_mem.write_bytes(0x3F800000_80000000_u64, IO::ByteFormat::LittleEndian) # 7: Black
        color_palette_slice = c_mem.to_slice
        color_palette_addr = curr_addr
        curr_addr += color_palette_slice.size.to_u32
      else
        phase_packets.each do |pkt|
          phase_addrs << curr_addr
          curr_addr += pkt.size.to_u32
        end

        # Phase dispatch table in .rodata for O(1) indexed frames
        phase_table_addr = curr_addr
        phase_table_bytes = IO::Memory.new
        if is_animated
          phases.each_with_index do |_, i|
            phase_table_bytes.write_bytes(phase_addrs[i], IO::ByteFormat::LittleEndian)
            phase_table_bytes.write_bytes(phase_qwcs[i].to_u32, IO::ByteFormat::LittleEndian)
          end
          pt_pad = (16 - (phase_table_bytes.size % 16)) % 16
          pt_pad.times { phase_table_bytes.write_byte(0_u8) }
          curr_addr += phase_table_bytes.size.to_u32
        end
        phase_table_slice = phase_table_bytes.to_slice
      end

      # Virtual Input Schedule table in .rodata (placed before strings for guaranteed 16-byte alignment):
      sched_addr = curr_addr
      sched_bytes = IO::Memory.new
      input_schedule.each do |s|
        sched_bytes.write_bytes(s.start_frame, IO::ByteFormat::LittleEndian)
        sched_bytes.write_bytes(s.button_mask, IO::ByteFormat::LittleEndian)
        sched_bytes.write_bytes(s.duration_frames, IO::ByteFormat::LittleEndian)
      end
      # Terminator:
      sched_bytes.write_bytes(0xFFFFFFFF_u32, IO::ByteFormat::LittleEndian)
      sched_bytes.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
      sched_bytes.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
      sched_pad = (16 - (sched_bytes.size % 16)) % 16
      sched_pad.times { sched_bytes.write_byte(0_u8) }
      sched_slice = sched_bytes.to_slice
      curr_addr += sched_slice.size.to_u32

      # String addresses in .rodata
      banner_str = "[CITRINE] PS2 EE Engine Initialized\n\0"
      banner_addr = curr_addr
      curr_addr += banner_str.bytesize.to_u32

      boot_msg_addrs = [] of UInt32
      boot_messages.each do |msg|
        boot_msg_addrs << curr_addr
        curr_addr += (msg.bytesize + 2).to_u32 # msg + "\n\0"
      end

      phase_msg_addrs = {} of Int32 => UInt32
      phases.each_with_index do |phase, i|
        if msg = phase.message
          phase_msg_addrs[i] = curr_addr
          curr_addr += (msg.bytesize + 2).to_u32 # msg + "\n\0"
        end
      end

      # Dedicated Button press debug strings in .rodata:
      cross_msg_str = "[CITRINE] Button Cross (X) pressed!\n\0"
      cross_msg_addr = curr_addr
      curr_addr += cross_msg_str.bytesize.to_u32

      triangle_msg_str = "[CITRINE] Button Triangle pressed!\n\0"
      triangle_msg_addr = curr_addr
      curr_addr += triangle_msg_str.bytesize.to_u32

      circle_msg_str = "[CITRINE] Button Circle pressed!\n\0"
      circle_msg_addr = curr_addr
      curr_addr += circle_msg_str.bytesize.to_u32

      square_msg_str = "[CITRINE] Button Square pressed!\n\0"
      square_msg_addr = curr_addr
      curr_addr += square_msg_str.bytesize.to_u32

      r1_msg_str = "[CITRINE] Button R1 pressed!\n\0"
      r1_msg_addr = curr_addr
      curr_addr += r1_msg_str.bytesize.to_u32

      emitter = MipsEmitter.new(0x00100000_u32)

      phase0_delay = phases.empty? ? 0_u32 : phases[0].delay_frames
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
      emitter.sw(ZERO, 16, T0)    # pad buttons current = 0  (0x70000010)
      emitter.sw(ZERO, 20, T0)    # pad buttons prev = 0     (0x70000014)
      emitter.sw(ZERO, 24, T0)    # pad buttons pressed = 0  (0x70000018)
      emitter.sw(ZERO, 28, T0)    # pad buttons released = 0 (0x7000001C)

      if is_dvd_screensaver
        emitter.ori(T1, ZERO, 1)
        emitter.sw(T1, 32, T0)      # logo_count = 1 at 0x70000020
        emitter.sw(ZERO, 36, T0)    # debounce = 0   at 0x70000024
        # Harvest hardware entropy: EE COP0 Count ($9) XOR Timer 1 Count (0x10000800) XOR GS CSR (0x12001000)
        emitter.mfc0(T1, 9)
        emitter.lui(T2, 0x1000)
        emitter.lw(T3, 0x0800, T2)  # Timer 1 count
        emitter.xor_(T1, T1, T3)
        emitter.lui(T2, 0x1200)
        emitter.lw(T3, 0x1000, T2)  # GS CSR
        emitter.xor_(T1, T1, T3)
        # Ensure seed is non-zero
        emitter.bnez(T1, "dvd_seed_ready")
        emitter.nop
        emitter.ori(T1, ZERO, 0x1337)
        emitter.label("dvd_seed_ready")
        emitter.sw(T1, 40, T0)      # rng_seed at 0x70000028
        emitter.sw(ZERO, 44, T0)    # manual_override = 0 at 0x7000002C

        # Logo 0 at 0x70000100:
        # pos_x = 240, pos_y = 200, vel_x = 7, vel_y = 6, text_color_idx = 3, bg_color_idx = 2
        emitter.ori(T1, ZERO, 240)
        emitter.sw(T1, 0x0100, T0)
        emitter.ori(T1, ZERO, 200)
        emitter.sw(T1, 0x0104, T0)
        emitter.ori(T1, ZERO, 7)
        emitter.sw(T1, 0x0108, T0)
        emitter.ori(T1, ZERO, 6)
        emitter.sw(T1, 0x010C, T0)
        emitter.ori(T1, ZERO, 3)
        emitter.sw(T1, 0x0110, T0)
        emitter.ori(T1, ZERO, 2)
        emitter.sw(T1, 0x0114, T0)
      else
        emitter.sw(ZERO, 32, T0)    # current bank = 0         (0x70000020)
        emitter.sw(ZERO, 36, T0)    # button debounce = 0      (0x70000024)
      end
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

      # Emit boot messages via debug_puts:
      boot_msg_addrs.each do |msg_addr|
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

      # Decrement button debounce counter at 0x70000024 if > 0
      emitter.lw(T3, 36, T0)
      emitter.beqz(T3, "debounce_ok")
      emitter.nop
      emitter.addiu(T3, T3, -1)
      emitter.sw(T3, 36, T0)
      emitter.label("debounce_ok")

      # VSync wait loop (GS_CSR bit 3):
      # Wait for previous frame presentation to finish before clearing and rendering next frame
      emitter.lui(V1, 0x1200)
      emitter.ori(V1, V1, 0x1000)
      emitter.ori(V0, ZERO, 8)
      emitter.sd(V0, 0, V1)        # Clear VSINT with 64-bit store
      emitter.lui(T1, 0x0020)       # Timeout counter (~2097152 iterations, ~80ms safety timeout)

      emitter.label("vsync_spin")
      emitter.ld(V0, 0, V1)        # 64-bit load from GS_CSR
      emitter.andi(V0, V0, 8)
      emitter.bnez(V0, "vsync_done")
      emitter.addiu(T1, T1, -1)     # branch delay slot: decrement counter
      emitter.bnez(T1, "vsync_spin")
      emitter.nop                  # branch delay slot

      emitter.label("vsync_done")

      if is_dvd_screensaver
        emitter.jal("dma02_wait")
        emitter.nop
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xa000)
        emitter.lui(T7, (static_dvd_addr >> 16).to_i32)
        emitter.ori(T7, T7, (static_dvd_addr & 0xFFFF).to_i32)
        emitter.sw(T7, 0x10, T8)
        emitter.ori(T6, ZERO, static_dvd_qwc.to_i32)
        emitter.sw(T6, 0x20, T8)
        emitter.ori(T5, ZERO, 0x101)
        emitter.sw(T5, 0x00, T8)
        emitter.jal("dma02_wait")
        emitter.nop
      elsif is_animated
        emitter.lw(T2, 8, T0) # T2 = phase index
        emitter.sll(T3, T2, 3) # T3 = phase_index * 8
        emitter.lui(T8, (phase_table_addr >> 16).to_i32)
        emitter.ori(T8, T8, (phase_table_addr & 0xFFFF).to_i32)
        emitter.addu(T8, T8, T3)
        emitter.lw(T7, 0, T8) # D2_MADR
        emitter.lw(T6, 4, T8) # D2_QWC
      elsif phases.size == 1
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

      unless is_dvd_screensaver
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
      end

      emitter.lui(T0, 0x7000)

      # 1. Check Virtual Input Schedule at sched_addr
      emitter.lw(T1, 4, T0)         # T1 = current frame
      emitter.lui(T8, (sched_addr >> 16).to_i32)
      emitter.ori(T8, T8, (sched_addr & 0xFFFF).to_i32)
      emitter.ori(T9, ZERO, 0)      # T9 = injected button mask = 0

      emitter.label("sched_loop")
      emitter.lw(T6, 0, T8)        # T6 = entry.start_frame
      emitter.lui(T5, 0xFFFF)
      emitter.ori(T5, T5, 0xFFFF)
      emitter.beq(T6, T5, "sched_done") # if entry.start_frame == 0xFFFFFFFF
      emitter.nop
      emitter.sltu(T7, T1, T6)     # T7 = 1 if frame < start_frame
      emitter.bnez(T7, "sched_next")
      emitter.nop
      emitter.lhu(T4, 6, T8)       # T4 = duration_frames
      emitter.addu(T6, T6, T4)     # T6 = start_frame + duration
      emitter.sltu(T7, T1, T6)     # T7 = 1 if frame < end_frame
      emitter.beqz(T7, "sched_next")
      emitter.nop
      # Inside duration: OR button_mask into T9
      emitter.lhu(T4, 4, T8)       # T4 = button_mask
      emitter.or_(T9, T9, T4)
      emitter.label("sched_next")
      emitter.addiu(T8, T8, 8)     # Next entry (8 bytes)
      emitter.j("sched_loop")
      emitter.nop

      emitter.label("sched_done")
      # OR injected mask into SPRAM 0x70000010:
      emitter.lw(T5, 16, T0)
      emitter.or_(T5, T5, T9)
      emitter.sw(T5, 16, T0)

      # 2. Poll EE SIO UART Rx (0x1000f110 LSR, 0x1000f1c0 RXFIFO)
      emitter.lui(T8, 0x1000)
      emitter.ori(T8, T8, 0xf100)
      emitter.lbu(T6, 0x10, T8)       # SIO_LSR at 0x1000f110
      emitter.andi(T6, T6, 0x01)      # bit 0 = Data Ready (DR)
      emitter.beqz(T6, "sio_rx_done")
      emitter.nop
      emitter.lbu(T7, 0xc0, T8)       # SIO_RXFIFO at 0x1000f1c0
      emitter.beqz(T7, "sio_rx_done")
      emitter.nop

      # Map received character to PS2 button:
      # Cross (0x4000): 'x' (0x78), 'X' (0x58), Enter (0x0D), Space (0x20)
      emitter.ori(T6, ZERO, 0x78)
      emitter.beq(T7, T6, "sio_set_cross")
      emitter.nop
      emitter.ori(T6, ZERO, 0x58)
      emitter.beq(T7, T6, "sio_set_cross")
      emitter.nop
      emitter.ori(T6, ZERO, 0x0d)
      emitter.beq(T7, T6, "sio_set_cross")
      emitter.nop
      emitter.ori(T6, ZERO, 0x20)
      emitter.beq(T7, T6, "sio_set_cross")
      emitter.nop

      # Triangle (0x1000): 't' (0x74), 'T' (0x54), 'v' (0x76), 'V' (0x56)
      emitter.ori(T6, ZERO, 0x74)
      emitter.beq(T7, T6, "sio_set_triangle")
      emitter.nop
      emitter.ori(T6, ZERO, 0x54)
      emitter.beq(T7, T6, "sio_set_triangle")
      emitter.nop
      emitter.ori(T6, ZERO, 0x76)
      emitter.beq(T7, T6, "sio_set_triangle")
      emitter.nop
      emitter.ori(T6, ZERO, 0x56)
      emitter.beq(T7, T6, "sio_set_triangle")
      emitter.nop

      # Circle (0x2000): 'c' (0x63), 'C' (0x43)
      emitter.ori(T6, ZERO, 0x63)
      emitter.beq(T7, T6, "sio_set_circle")
      emitter.nop
      emitter.ori(T6, ZERO, 0x43)
      emitter.beq(T7, T6, "sio_set_circle")
      emitter.nop

      # Square (0x8000): 's' (0x73), 'S' (0x53), 'z' (0x7A), 'Z' (0x5A)
      emitter.ori(T6, ZERO, 0x73)
      emitter.beq(T7, T6, "sio_set_square")
      emitter.nop
      emitter.ori(T6, ZERO, 0x53)
      emitter.beq(T7, T6, "sio_set_square")
      emitter.nop
      emitter.ori(T6, ZERO, 0x7a)
      emitter.beq(T7, T6, "sio_set_square")
      emitter.nop
      emitter.ori(T6, ZERO, 0x5a)
      emitter.beq(T7, T6, "sio_set_square")
      emitter.nop
      # R1 (0x0800): 'r' (0x72), 'R' (0x52)
      emitter.ori(T6, ZERO, 0x72)
      emitter.beq(T7, T6, "sio_set_r1")
      emitter.nop
      emitter.ori(T6, ZERO, 0x52)
      emitter.beq(T7, T6, "sio_set_r1")
      emitter.nop

      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_cross")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x4000)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_triangle")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x1000)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_circle")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x2000)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_square")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x8000)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_r1")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0800)
      emitter.sw(T5, 16, T0)

      emitter.label("sio_rx_done")

      # 3. Compute edge transitions:
      emitter.lw(T5, 16, T0)       # T5 = current buttons (0x70000010)
      emitter.lw(T6, 20, T0)       # T6 = previous buttons (0x70000014)
      emitter.sw(T5, 20, T0)       # update previous buttons = current
      emitter.nor(T7, T6, ZERO)    # T7 = ~previous
      emitter.and_(T8, T5, T7)     # T8 = newly pressed edges (curr & ~prev)
      emitter.sw(T8, 24, T0)       # store pressed edges at 0x70000018
      emitter.nor(T7, T5, ZERO)    # T7 = ~current
      emitter.and_(T7, T6, T7)     # T7 = newly released edges (prev & ~curr)
      emitter.sw(T7, 28, T0)       # store released edges at 0x7000001C

      # 4. Emit button press console debug logs:
      # Check Cross (0x4000)
      emitter.andi(T7, T8, 0x4000)
      emitter.beqz(T7, "chk_btn_triangle")
      emitter.nop
      emitter.lui(A0, (cross_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (cross_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)

      emitter.label("chk_btn_triangle")
      emitter.andi(T7, T8, 0x1000)
      emitter.beqz(T7, "chk_btn_circle")
      emitter.nop
      emitter.lui(A0, (triangle_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (triangle_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)

      emitter.label("chk_btn_circle")
      emitter.andi(T7, T8, 0x2000)
      emitter.beqz(T7, "chk_btn_square")
      emitter.nop
      emitter.lui(A0, (circle_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (circle_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)

      emitter.label("chk_btn_square")
      emitter.andi(T7, T8, 0x8000)
      emitter.beqz(T7, "chk_btn_r1")
      emitter.nop
      emitter.lui(A0, (square_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (square_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)

      emitter.label("chk_btn_r1")
      emitter.andi(T7, T8, 0x0800)
      emitter.beqz(T7, "btn_chk_done")
      emitter.nop
      emitter.lui(A0, (r1_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (r1_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)

      emitter.label("btn_chk_done")
      # Reset current buttons at 0x70000010 to 0 (so next frame re-polls schedule or hardware)
      emitter.sw(ZERO, 16, T0)

      if is_dvd_screensaver
        # --- DVD BUTTONS & LOGO MANAGEMENT ---
        emitter.lw(T5, 24, T0) # T5 = pressed edges (0x70000018)
        emitter.lw(T4, 32, T0) # T4 = logo_count    (0x70000020)
        emitter.lw(T3, 36, T0) # T3 = debounce      (0x70000024)

        # Check manual override: if user ever pressed any button, set 0x7000002C = 1
        emitter.lw(T8, 44, T0) # T8 = manual_override at 0x7000002C
        emitter.beqz(T5, "dvd_skip_override")
        emitter.nop
        emitter.ori(T8, ZERO, 1)
        emitter.sw(T8, 44, T0)
        emitter.label("dvd_skip_override")

        # 1. Triangle (0x1000): reset to 1 logo
        emitter.andi(T7, T5, 0x1000)
        emitter.bnez(T7, "dvd_do_reset")
        emitter.nop

        # 2. R1 (0x0800): stress test spawn 10 logos
        emitter.andi(T7, T5, 0x0800)
        emitter.bnez(T7, "dvd_do_spawn_10")
        emitter.nop

        # 3. Cross (0x4000): spawn 1 logo
        emitter.andi(T7, T5, 0x4000)
        emitter.bnez(T7, "dvd_do_spawn_1")
        emitter.nop

        # 4. Autonomous Demo Mode (if no manual interaction has occurred)
        emitter.bnez(T8, "dvd_buttons_done")
        emitter.nop
        emitter.lw(T1, 4, T0) # T1 = frame_counter
        emitter.ori(T6, ZERO, 1200)
        emitter.divu(T1, T6)
        emitter.mfhi(T2) # T2 = frame % 1200
        emitter.ori(T6, ZERO, 240)
        emitter.beq(T2, T6, "dvd_do_spawn_1")
        emitter.nop
        emitter.ori(T6, ZERO, 420)
        emitter.beq(T2, T6, "dvd_do_spawn_1")
        emitter.nop
        emitter.ori(T6, ZERO, 600)
        emitter.beq(T2, T6, "dvd_do_spawn_1")
        emitter.nop
        emitter.ori(T6, ZERO, 1199)
        emitter.beq(T2, T6, "dvd_do_reset")
        emitter.nop
        emitter.j("dvd_buttons_done")
        emitter.nop

        emitter.label("dvd_do_reset")
        emitter.bnez(T3, "dvd_buttons_done")
        emitter.nop
        emitter.ori(T4, ZERO, 1)
        emitter.sw(T4, 32, T0)  # logo_count = 1
        emitter.ori(T3, ZERO, 10)
        emitter.sw(T3, 36, T0)  # debounce = 10
        emitter.j("dvd_buttons_done")
        emitter.nop

        emitter.label("dvd_do_spawn_10")
        emitter.bnez(T3, "dvd_buttons_done")
        emitter.nop
        emitter.ori(S4, ZERO, 10)
        emitter.j("dvd_spawn_loop")
        emitter.nop

        emitter.label("dvd_do_spawn_1")
        emitter.bnez(T3, "dvd_buttons_done")
        emitter.nop
        emitter.ori(S4, ZERO, 1)

        emitter.label("dvd_spawn_loop")
        emitter.sltiu(T7, T4, 500)
        emitter.beqz(T7, "dvd_spawn_end")
        emitter.nop

        emitter.lui(T0, 0x7000)
        # Calculate slot address in SPRAM: 0x70000100 + (logo_count * 24)
        emitter.sll(S1, T4, 4)  # T4 * 16
        emitter.sll(S2, T4, 3)  # T4 * 8
        emitter.addu(S1, S1, S2)
        emitter.addiu(S1, S1, 0x0100)
        emitter.addu(S0, T0, S1) # S0 = new logo SPRAM address

        # rx = rng.next_int(40, 400)
        emitter.ori(A0, ZERO, 40)
        emitter.ori(A1, ZERO, 400)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.sw(V0, 0, S0)

        # ry = rng.next_int(40, 320)
        emitter.ori(A0, ZERO, 40)
        emitter.ori(A1, ZERO, 320)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.sw(V0, 4, S0)

        # dir_x: rng_next_int(0, 1) == 0 ? -3 : 3
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 1)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.ori(T6, ZERO, 3)
        emitter.bnez(V0, "dvd_dir_x_set")
        emitter.nop
        emitter.subu(T6, ZERO, T6) # T6 = -3
        emitter.label("dvd_dir_x_set")
        emitter.sw(T6, 8, S0)

        # dir_y: rng_next_int(0, 1) == 0 ? -2 : 2
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 1)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.ori(T6, ZERO, 2)
        emitter.bnez(V0, "dvd_dir_y_set")
        emitter.nop
        emitter.subu(T6, ZERO, T6) # T6 = -2
        emitter.label("dvd_dir_y_set")
        emitter.sw(T6, 12, S0)

        # rt_col = rng_next_int(0, 5)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(S2, V0)
        emitter.sw(S2, 16, S0) # text_color_idx

        # bg_step = rng_next_int(1, 5) -> rbg_col = (rt_col + bg_step) % 6
        emitter.ori(A0, ZERO, 1)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.addu(S2, S2, V0)
        emitter.ori(T6, ZERO, 6)
        emitter.divu(S2, T6)
        emitter.mfhi(S2)
        emitter.sw(S2, 20, S0) # bg_color_idx

        # logo_count++
        emitter.lui(T0, 0x7000)
        emitter.lw(T4, 32, T0)
        emitter.addiu(T4, T4, 1)
        emitter.sw(T4, 32, T0)

        emitter.addiu(S4, S4, -1)
        emitter.bnez(S4, "dvd_spawn_loop")
        emitter.nop

        emitter.label("dvd_spawn_end")
        emitter.lui(T0, 0x7000)
        emitter.ori(T3, ZERO, 6)
        emitter.sw(T3, 36, T0)

        emitter.label("dvd_buttons_done")

        # --- DVD PHYSICS UPDATE FOR ALL LOGOS ---
        emitter.lui(T0, 0x7000)
        emitter.lw(S6, 32, T0)  # S6 = logo_count
        emitter.move(S7, ZERO)  # S7 = logo index (0 .. logo_count - 1)

        emitter.label("dvd_physics_loop")
        emitter.sll(S1, S7, 4)
        emitter.sll(S2, S7, 3)
        emitter.addu(S1, S1, S2)
        emitter.addiu(S1, S1, 0x0100)
        emitter.addu(S0, T0, S1) # S0 = current logo address

        emitter.lw(T1, 0, S0)  # x
        emitter.lw(T2, 8, S0)  # vx
        emitter.addu(T1, T1, T2)

        emitter.lw(T3, 4, S0)  # y
        emitter.lw(T4, 12, S0) # vy
        emitter.addu(T3, T3, T4)

        emitter.move(S3, ZERO) # S3 = bounced = 0

        # if x <= 10
        emitter.ori(T6, ZERO, 10)
        emitter.slt(T7, T6, T1) # 10 < x
        emitter.bnez(T7, "dvd_chk_x_hi")
        emitter.nop
        emitter.ori(T1, ZERO, 10)
        emitter.subu(T2, ZERO, T2)
        emitter.ori(S3, ZERO, 1)

        emitter.label("dvd_chk_x_hi")
        # if x >= 430
        emitter.ori(T6, ZERO, 430)
        emitter.slt(T7, T1, T6) # x < 430
        emitter.bnez(T7, "dvd_chk_y_lo")
        emitter.nop
        emitter.ori(T1, ZERO, 430)
        emitter.subu(T2, ZERO, T2)
        emitter.ori(S3, ZERO, 1)

        emitter.label("dvd_chk_y_lo")
        # if y <= 10
        emitter.ori(T6, ZERO, 10)
        emitter.slt(T7, T6, T3) # 10 < y
        emitter.bnez(T7, "dvd_chk_y_hi")
        emitter.nop
        emitter.ori(T3, ZERO, 10)
        emitter.subu(T4, ZERO, T4)
        emitter.ori(S3, ZERO, 1)

        emitter.label("dvd_chk_y_hi")
        # if y >= 360
        emitter.ori(T6, ZERO, 360)
        emitter.slt(T7, T3, T6) # y < 360
        emitter.bnez(T7, "dvd_physics_store")
        emitter.nop
        emitter.ori(T3, ZERO, 360)
        emitter.subu(T4, ZERO, T4)
        emitter.ori(S3, ZERO, 1)

        emitter.label("dvd_physics_store")
        emitter.sw(T1, 0, S0)
        emitter.sw(T3, 4, S0)
        emitter.sw(T2, 8, S0)
        emitter.sw(T4, 12, S0)

        emitter.beqz(S3, "dvd_physics_next")
        emitter.nop

        # On bounce: text_col = (text_col + step) % 6; bg_col = (text_col + bg_step) % 6
        emitter.ori(A0, ZERO, 1)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.lui(T0, 0x7000)
        emitter.lw(T5, 16, S0) # old text_color_idx
        emitter.addu(T5, T5, V0)
        emitter.ori(T6, ZERO, 6)
        emitter.divu(T5, T6)
        emitter.mfhi(T5)
        emitter.sw(T5, 16, S0) # new text_color_idx

        emitter.ori(A0, ZERO, 1)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.lui(T0, 0x7000)
        emitter.lw(T5, 16, S0) # text_color_idx
        emitter.addu(T5, T5, V0)
        emitter.ori(T6, ZERO, 6)
        emitter.divu(T5, T6)
        emitter.mfhi(T5)
        emitter.sw(T5, 20, S0) # new bg_color_idx

        emitter.label("dvd_physics_next")
        emitter.addiu(S7, S7, 1)
        emitter.bne(S7, S6, "dvd_physics_loop")
        emitter.nop

        # --- DVD DYNAMIC GIF PACKET GENERATION ---
        # Buffer pointer S0 in RAM at 0x20210010 (offset 16 bytes for GIFTag header)
        emitter.lui(S0, 0x2021)
        emitter.ori(S0, S0, 0x0010)

        emitter.lui(T0, 0x7000)
        emitter.lw(S6, 32, T0)  # S6 = logo_count
        emitter.move(S7, ZERO)  # S7 = logo index (0 .. logo_count - 1)

        emitter.label("dvd_draw_logo_loop")
        emitter.sll(S1, S7, 4)
        emitter.sll(S2, S7, 3)
        emitter.addu(S1, S1, S2)
        emitter.addiu(S1, S1, 0x0100)
        emitter.addu(A1, T0, S1) # A1 = logo struct address

        emitter.lw(T1, 0, A1)   # px
        emitter.lw(T2, 4, A1)   # py
        emitter.lw(T3, 16, A1)  # txt_col
        emitter.lw(T4, 20, A1)  # bg_col

        # Load bg_rgba into S2
        emitter.lui(A2, (color_palette_addr >> 16).to_i32)
        emitter.ori(A2, A2, (color_palette_addr & 0xFFFF).to_i32)
        emitter.sll(T5, T4, 3)
        emitter.addu(T5, A2, T5)
        emitter.ld(S2, 0, T5)

        # Load txt_rgba into S3
        emitter.sll(T5, T3, 3)
        emitter.addu(T5, A2, T5)
        emitter.ld(S3, 0, T5)

        # Load black_rgba (at offset 56) into S4
        emitter.ld(S4, 56, A2)

        # 1. Outer rect: (px, py, px + 190, py + 44), color = bg_rgba (S2)
        emitter.move(A0, T1)
        emitter.move(A1, T2)
        emitter.addiu(A2, T1, 190)
        emitter.addiu(A3, T2, 44)
        emitter.move(T4, S2)
        emitter.jal("emit_quad_s0")
        emitter.nop

        # 2. Inner border: (px + 2, py + 2, px + 188, py + 42), color = black_rgba (S4)
        emitter.addiu(A0, T1, 2)
        emitter.addiu(A1, T2, 2)
        emitter.addiu(A2, T1, 188)
        emitter.addiu(A3, T2, 42)
        emitter.move(T4, S4)
        emitter.jal("emit_quad_s0")
        emitter.nop

        # 3. Inner rect: (px + 4, py + 4, px + 186, py + 40), color = bg_rgba (S2)
        emitter.addiu(A0, T1, 4)
        emitter.addiu(A1, T2, 4)
        emitter.addiu(A2, T1, 186)
        emitter.addiu(A3, T2, 40)
        emitter.move(T4, S2)
        emitter.jal("emit_quad_s0")
        emitter.nop

        # 4. Text Quads (111 quads)
        # S1 = px + 16 (Origin X)
        # FP = py + 12 (Origin Y)
        emitter.addiu(S1, T1, 16)
        emitter.addiu(FP, T2, 12)

        # Store font_quad_addr in SPRAM at 0x70000030
        emitter.lui(T5, (font_quad_addr >> 16).to_i32)
        emitter.ori(T5, T5, (font_quad_addr & 0xFFFF).to_i32)
        emitter.lui(T0, 0x7000)
        emitter.sw(T5, 48, T0)

        emitter.ori(S5, ZERO, 111) # loop counter

        emitter.label("dvd_glyph_loop")
        emitter.lui(T0, 0x7000)
        emitter.lw(T5, 48, T0)
        emitter.lbu(T6, 0, T5)  # dx1
        emitter.lbu(T7, 1, T5)  # dy1
        emitter.lbu(T8, 2, T5)  # dx2
        emitter.lbu(T9, 3, T5)  # dy2
        emitter.addiu(T5, T5, 4)
        emitter.sw(T5, 48, T0)

        emitter.addu(A0, S1, T6) # x1
        emitter.addu(A1, FP, T7) # y1
        emitter.addu(A2, S1, T8) # x2
        emitter.addu(A3, FP, T9) # y2
        emitter.move(T4, S3)     # txt_rgba

        emitter.jal("emit_quad_s0")
        emitter.nop

        emitter.addiu(S5, S5, -1)
        emitter.bnez(S5, "dvd_glyph_loop")
        emitter.nop

        # Next logo
        emitter.lui(T0, 0x7000)
        emitter.lw(S6, 32, T0)
        emitter.addiu(S7, S7, 1)
        emitter.bne(S7, S6, "dvd_draw_logo_loop")
        emitter.nop

        # --- WRITE GIFTAG AND KICK DMA CHANNEL 2 ---
        # total_items = logo_count * 114 * 4 = logo_count * 456
        emitter.lui(T0, 0x7000)
        emitter.lw(T1, 32, T0)
        emitter.ori(T2, ZERO, 456)
        emitter.multu(T1, T2)
        emitter.mflo(T1) # T1 = total_items

        # GIFTag at 0x20210000:
        emitter.lui(T0, 0x2021)
        emitter.lui(T2, 0x1000)
        emitter.dsll32(T2, T2, 0) # bit 60 PRE = 1
        emitter.ori(T3, ZERO, 0x8000) # bit 15 EOP = 1
        emitter.or_(T2, T2, T3)
        emitter.andi(T3, T1, 0x7FFF)
        emitter.or_(T2, T2, T3)
        emitter.sd(T2, 0, T0)
        emitter.ori(T3, ZERO, 0x0E)
        emitter.sd(T3, 8, T0)

        # Kick DMA:
        emitter.jal("dma02_wait")
        emitter.nop
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xa000)
        emitter.lui(T7, 0x0021)
        emitter.sw(T7, 0x10, T8) # D2_MADR = 0x00210000
        emitter.addiu(T6, T1, 1) # D2_QWC = total_items + 1
        emitter.sw(T6, 0x20, T8)
        emitter.ori(T5, ZERO, 0x101)
        emitter.sw(T5, 0x00, T8)
        emitter.jal("dma02_wait")
        emitter.nop

        # Clear buttons:
        emitter.lui(T0, 0x7000)
        emitter.sw(ZERO, 16, T0)

        emitter.j("frame_loop")
        emitter.nop
      elsif is_animated
        # Animated mode bank & frame advance:
        emitter.lw(T5, 24, T0) # T5 = pressed edges (0x70000018)
        emitter.lw(T4, 32, T0) # T4 = current_bank (at 0x70000020)
        emitter.lw(T3, 36, T0) # T3 = debounce counter (at 0x70000024)

        # 1. Check Triangle (bit 12: 0x1000): reset to Bank 0
        emitter.andi(T7, T5, 0x1000)
        emitter.beqz(T7, "chk_cross_advance")
        emitter.nop
        # Only reset if debounce counter == 0:
        emitter.bnez(T3, "advance_frame")
        emitter.nop
        emitter.sw(ZERO, 32, T0)  # current_bank = 0
        emitter.sw(ZERO, 8, T0)   # phase_index = 0
        emitter.ori(T3, ZERO, 12) # debounce = 12 frames (~200ms)
        emitter.sw(T3, 36, T0)
        emitter.j("advance_frame_done")
        emitter.nop

        emitter.label("chk_cross_advance")
        # 2. Check Cross (bit 14: 0x4000): if current_bank < 3, advance bank!
        emitter.andi(T7, T5, 0x4000)
        emitter.beqz(T7, "advance_frame")
        emitter.nop
        # Only advance if debounce counter == 0:
        emitter.bnez(T3, "advance_frame")
        emitter.nop
        emitter.sltiu(T7, T4, 3) # T7 = 1 if current_bank < 3
        emitter.beqz(T7, "advance_frame")
        emitter.nop
        emitter.addiu(T4, T4, 1)  # current_bank += 1
        emitter.sw(T4, 32, T0)
        emitter.sll(T2, T4, 6)    # phase_index = current_bank * 64
        emitter.sw(T2, 8, T0)
        emitter.ori(T3, ZERO, 12) # debounce = 12 frames (~200ms)
        emitter.sw(T3, 36, T0)
        emitter.j("advance_frame_done")
        emitter.nop

        emitter.label("advance_frame")
        # 3. Every frame: advance phase_index within current bank (modulo 64)
        emitter.lw(T2, 8, T0)    # T2 = phase_index
        emitter.addiu(T2, T2, 1) # phase_index++
        emitter.andi(T7, T2, 63) # if (phase_index & 63) == 0, wrapped around 64!
        emitter.bnez(T7, "store_phase_index")
        emitter.nop
        emitter.addiu(T2, T2, -64) # wrap back to start of bank!

        emitter.label("store_phase_index")
        emitter.sw(T2, 8, T0)

        emitter.label("advance_frame_done")
      elsif phases.size > 1
        # Check if Triangle button (bit 12: 0x1000) was pressed in edges (0x70000018)
        # to reset phase index back to 0 (single logo state)
        emitter.lw(T5, 24, T0)
        emitter.andi(T7, T5, 0x1000)
        emitter.beqz(T7, "chk_cross_advance")
        emitter.nop
        emitter.sw(ZERO, 8, T0)
        emitter.ori(T2, ZERO, 0)
        emitter.j("apply_phase_update")
        emitter.nop

        emitter.label("chk_cross_advance")
        # Check if Cross button (bit 14: 0x4000) was pressed in edges (0x70000018)
        emitter.andi(T7, T5, 0x4000)
        emitter.bnez(T7, "advance_phase")
        emitter.nop

        # Timer countdown check
        emitter.lw(T4, 12, T0) # frames remaining
        emitter.beqz(T4, "loop_continue")
        emitter.nop
        emitter.addiu(T4, T4, -1)
        emitter.sw(T4, 12, T0)
        emitter.bnez(T4, "loop_continue")
        emitter.nop

        # Timer hit 0 or button pressed! Advance to next phase
        emitter.label("advance_phase")
        emitter.lw(T2, 8, T0) # phase index
        emitter.addiu(T2, T2, 1)
        emitter.ori(T3, ZERO, phases.size)
        emitter.bne(T2, T3, "phase_in_range")
        emitter.nop
        emitter.ori(T2, ZERO, loop_start_phase) # wrap back to loop start phase

        emitter.label("phase_in_range")
        emitter.sw(T2, 8, T0)

        emitter.label("apply_phase_update")
        phases.each_with_index do |phase, i|
          if i < phases.size - 1
            emitter.ori(T3, ZERO, i)
            emitter.bne(T2, T3, "check_delay_#{i + 1}")
            emitter.nop
          end

          # If this phase has a live debug message, emit it via debug_puts:
          if msg_addr = phase_msg_addrs[i]?
            emitter.lui(A0, (msg_addr >> 16).to_i32)
            emitter.ori(A0, A0, (msg_addr & 0xFFFF).to_i32)
            emitter.jal("debug_puts")
            emitter.nop
            emitter.lui(T0, 0x7000)
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

      # Subroutine rng_next_int:
      # a0 = min, a1 = max, returns v0
      emitter.label("rng_next_int")
      emitter.lui(T8, 0x7000)
      emitter.lw(T0, 40, T8)       # rng_seed at 0x70000028
      emitter.lui(T1, 0x41C6)
      emitter.ori(T1, T1, 0x4E6D)  # 1103515245
      emitter.multu(T0, T1)
      emitter.mflo(T0)
      emitter.addiu(T0, T0, 12345)
      emitter.lui(T2, 0x7FFF)
      emitter.ori(T2, T2, 0xFFFF)  # 0x7FFFFFFF
      emitter.and_(T0, T0, T2)
      emitter.sw(T0, 40, T8)       # store new seed
      emitter.subu(T3, A1, A0)     # max - min
      emitter.addiu(T3, T3, 1)     # range = max - min + 1
      emitter.divu(T0, T3)
      emitter.mfhi(V0)             # seed % range
      emitter.addu(V0, V0, A0)     # min + (seed % range)
      emitter.jr(RA)
      emitter.nop

      # Subroutine emit_quad_s0:
      # s0 = write pointer in RAM (advanced by 64 bytes)
      # a0 = x1, a1 = y1, a2 = x2, a3 = y2, t4 = rgbaq (lower 64 bits)
      emitter.label("emit_quad_s0")
      emitter.ori(T6, ZERO, 6)
      emitter.sd(T6, 0, S0)
      emitter.sd(ZERO, 8, S0)

      emitter.sd(T4, 16, S0)
      emitter.ori(T6, ZERO, 1)
      emitter.sd(T6, 24, S0)

      emitter.sll(T6, A0, 4)
      emitter.andi(T6, T6, 0xFFFF)
      emitter.sll(T7, A1, 20)
      emitter.or_(T6, T6, T7)
      emitter.sd(T6, 32, S0)
      emitter.ori(T7, ZERO, 0x0d)
      emitter.sd(T7, 40, S0)

      emitter.sll(T6, A2, 4)
      emitter.andi(T6, T6, 0xFFFF)
      emitter.sll(T7, A3, 20)
      emitter.or_(T6, T6, T7)
      emitter.sd(T6, 48, S0)
      emitter.ori(T7, ZERO, 5)
      emitter.sd(T7, 56, S0)

      emitter.addiu(S0, S0, 64)
      emitter.jr(RA)
      emitter.nop

      # Native API stubs (Citrine_VM_Run, etc.)
      stub_start = 0x00100000_u32 + (emitter.words.size.to_u32 * 4)
      60.times do |stub_idx|
        if stub_idx == 18 # Citrine_ButtonDown (A0 = button index, returns V0 = 1 if down, 0 if up)
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 16, T0)
          emitter.srlv(V0, V0, A0)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        elsif stub_idx == 19 # Citrine_ButtonPressed (A0 = button index, returns V0 = 1 if pressed, 0 if not)
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 24, T0)
          emitter.srlv(V0, V0, A0)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        else
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.ori(V0, ZERO, 0)
          emitter.lw(RA, 28, SP)
          emitter.jr(RA)
          emitter.addiu(SP, SP, 32)
        end
      end

      # Pad .text to 8192 bytes
      emitter.pad_to(TEXT_SIZE.to_i32)
      emitter.resolve!
      text_data = emitter.to_slice

      # .rodata segment
      rodata_bytes = IO::Memory.new
      rodata_bytes.write(env_packet)
      if is_dvd_screensaver
        rodata_bytes.write(static_dvd_packet)
        rodata_bytes.write(font_quad_slice)
        rodata_bytes.write(color_palette_slice)
      else
        phase_packets.each do |pkt|
          rodata_bytes.write(pkt)
        end
        if is_animated
          rodata_bytes.write(phase_table_slice)
        end
      end
      rodata_bytes.write(sched_slice)
      rodata_bytes.write(banner_str.to_slice)
      boot_messages.each do |msg|
        rodata_bytes.write("#{msg}\n\0".to_slice)
      end
      phases.each do |phase|
        if msg = phase.message
          rodata_bytes.write("#{msg}\n\0".to_slice)
        end
      end
      rodata_bytes.write(cross_msg_str.to_slice)
      rodata_bytes.write(triangle_msg_str.to_slice)
      rodata_bytes.write(circle_msg_str.to_slice)
      rodata_bytes.write(square_msg_str.to_slice)
      rodata_bytes.write(r1_msg_str.to_slice)
      rodata_bytes.write("Citrine PS2 Virtual Machine runtime v0.1.0\0".to_slice)
      rodata_bytes.write("Emotion Engine R5900 / Graphic Synthesizer\0".to_slice)
      rodata_data = rodata_bytes.to_slice

      # .data segment
      data_bytes = IO::Memory.new
      data_bytes.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian) # g_spram_base
      data_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # g_citrine_vm
      data_data = data_bytes.to_slice

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

      ElfWriter.write(text_data, rodata_data, data_data, symbols, 0x00100000_u32)
    end

    def build_headless_elf(boot_messages : Array(String) = [] of String) : Bytes
      emitter = MipsEmitter.new
      emitter.lui(SP, 0x01FF)
      emitter.ori(SP, SP, 0xFFF0)
      emitter.lui(T0, 0x1000)
      emitter.ori(T0, T0, 0xF180) # EE TTY data register

      emitter.label("headless_loop")
      emitter.j("headless_loop")
      emitter.nop

      text_slice = emitter.to_slice
      symbols = [
        SymbolEntry.new("_start", 0x00100000_u32, 16_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", 0x00100000_u32, text_slice.size.to_u32, STT_FUNC, STB_GLOBAL, 1_u16)
      ]
      ElfWriter.write(text_slice, Bytes.empty, Bytes.empty, symbols, 0x00100000_u32)
    end

    def parse_cbc(cbc_bytes : Bytes?) : Tuple(Array(Phase), Array(String), Int32, Bool, Bool)
      boot_messages = [] of String
      loop_start_phase = 0
      is_dvd_screensaver = false
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
          is_dvd_screensaver = strings.any? { |s| s.includes?("BouncingLogo") || s.includes?("DVD Bouncing Screensaver") }

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

            regs = Array(Int64).new(1024, 0_i64)
            reg_base = 0
            call_stack = [] of CallFrame
            objects = Hash(Int64, Array(Int64)).new
            next_obj_id = 1_i64
            arrays = Hash(Int64, Array(Int64)).new
            next_arr_id = 1000_i64
            io_streams = Hash(Int64, IO::Memory).new
            next_io_id = 2000_i64
            memory = Hash(Int64, Int64).new
            next_heap_addr = 0x00200000_i64
            object_classes = Hash(Int64, UInt32).new
            active_context_name = ""
            scratch_pool_base = 0x00400000_i64
            scratch_pool_ptr = scratch_pool_base
            allocations = Hash(Int64, AllocationRecord).new
            free_list = [] of Tuple(Int64, Int32)
            compiled_regexes = Hash(Int64, SimpleRegex).new
            next_regex_id = 5000_i64
            vec2_store = Hash(Int64, Tuple(Int64, Int64)).new
            next_vec2_id = 10000_i64
            current_commands = [] of DrawCommand
            phases = [] of Phase
            pc = 0
            max_steps = 600_000
            steps = 0
            first_frame_done = false
            in_main_loop = false
            current_loop_message : String? = nil

            has_button_checks = instructions.any? do |instr|
              op = (instr >> 24) & 0xFF
              nat = instr & 0xFF
              op == 52 && (nat == 40 || nat == 41 || nat == 42)
            end
            has_drawing = instructions.any? do |instr|
              op = (instr >> 24) & 0xFF
              nat = instr & 0xFF
              op == 52 && (nat == 10 || nat == 11 || (nat >= 20 && nat <= 34) || (nat >= 100 && nat <= 111))
            end
            simulated_button_press = false
            button_phase_count = 0

            is_animated = false
            animation_checked = false
            prev_frame_cmds = [] of DrawCommand
            anim_frame_count = 0
            anim_bank = 0
            max_banks = 4
            frames_per_bank = 64

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

              dst_r = (reg_base + dst).clamp(0, 1023)
              a_r = (reg_base + a).clamp(0, 1023)
              b_r = (reg_base + b).clamp(0, 1023)

              pc += 1

              case opcode
              when 0 # Nop
              when 1 # Move
                regs[dst_r] = regs[a_r]
              when 2 # LoadNil
                regs[dst_r] = 0_i64
              when 3 # LoadBool
                regs[dst_r] = imm16
              when 4 # LoadInt
                regs[dst_r] = imm16
              when 5 # LoadConst
                if imm16 < constants.size
                  c = constants[imm16]
                  case c.type
                  when 2 # Int32
                    regs[dst_r] = c.u32_val.to_i32.to_i64
                  when 5 # Color
                    regs[dst_r] = c.u32_val.to_i64
                  when 1 # Bool
                    regs[dst_r] = c.u32_val.to_i64
                  else
                    regs[dst_r] = imm16.to_i64
                  end
                else
                  regs[dst_r] = imm16.to_i64
                end
              when 10 # Add
                regs[dst_r] = regs[a_r] &+ regs[b_r]
              when 11 # Sub
                regs[dst_r] = regs[a_r] &- regs[b_r]
              when 12 # Mul
                regs[dst_r] = regs[a_r] &* regs[b_r]
              when 13 # Div
                regs[dst_r] = regs[b_r] != 0 ? (regs[a_r] // regs[b_r]) : 0_i64
              when 14 # Mod
                regs[dst_r] = regs[b_r] != 0 ? (regs[a_r] % regs[b_r]) : 0_i64
              when 15 # Neg
                regs[dst_r] = 0_i64 &- regs[a_r]
              when 16 # BitAnd
                regs[dst_r] = regs[a_r] & regs[b_r]
              when 17 # BitOr
                regs[dst_r] = regs[a_r] | regs[b_r]
              when 18 # BitXor
                regs[dst_r] = regs[a_r] ^ regs[b_r]
              when 19 # ShiftLeft
                shift = (regs[b_r] & 0x3F).to_i
                regs[dst_r] = ((regs[a_r].to_u64! << shift) & 0xFFFFFFFFFFFFFFFF_u64).to_i64!
              when 20 # Vec2New
                id = next_vec2_id
                next_vec2_id += 1
                vec2_store[id] = {regs[a_r], regs[b_r]}
                regs[dst_r] = id
              when 21 # Vec2GetX
                id = regs[a_r]
                regs[dst_r] = vec2_store[id]?.try(&.[0]) || 0_i64
              when 22 # Vec2GetY
                id = regs[a_r]
                regs[dst_r] = vec2_store[id]?.try(&.[1]) || 0_i64
              when 23 # Vec2SetX
                id = regs[dst_r]
                if entry = vec2_store[id]?
                  vec2_store[id] = {regs[a_r], entry[1]}
                end
              when 24 # Vec2SetY
                id = regs[dst_r]
                if entry = vec2_store[id]?
                  vec2_store[id] = {entry[0], regs[a_r]}
                end
              when 25 # Vec2Add
                id1 = regs[a_r]
                id2 = regs[b_r]
                v1 = vec2_store[id1]? || {0_i64, 0_i64}
                v2 = vec2_store[id2]? || {0_i64, 0_i64}
                new_id = next_vec2_id
                next_vec2_id += 1
                vec2_store[new_id] = {v1[0] &+ v2[0], v1[1] &+ v2[1]}
                regs[dst_r] = new_id
              when 27 # ShiftRight
                shift = (regs[b_r] & 0x3F).to_i
                regs[dst_r] = (regs[a_r].to_u64! >> shift).to_i64!
              when 28 # BitNot
                regs[dst_r] = ~regs[a_r]
              when 30 # Eq
                val_a = regs[a_r]
                val_b = regs[b_r]
                is_eq = if val_a == val_b
                          true
                        else
                          str_a = if val_a >= 0 && val_a < constants.size && constants[val_a.to_i]?.try(&.type) == 6_u8
                                    constants[val_a.to_i].str_val
                                  elsif val_a >= 0 && val_a <= Int32::MAX && strings[val_a.to_i32!]?
                                    strings[val_a.to_i32!]
                                  else
                                    nil
                                  end
                          str_b = if val_b >= 0 && val_b < constants.size && constants[val_b.to_i]?.try(&.type) == 6_u8
                                    constants[val_b.to_i].str_val
                                  elsif val_b >= 0 && val_b <= Int32::MAX && strings[val_b.to_i32!]?
                                    strings[val_b.to_i32!]
                                  else
                                    nil
                                  end
                          if str_a && str_b
                            str_a == str_b
                          else
                            false
                          end
                        end
                regs[dst_r] = is_eq ? 1_i64 : 0_i64
              when 31 # Ne
                val_a = regs[a_r]
                val_b = regs[b_r]
                is_eq = if val_a == val_b
                          true
                        else
                          str_a = if val_a >= 0 && val_a < constants.size && constants[val_a.to_i]?.try(&.type) == 6_u8
                                    constants[val_a.to_i].str_val
                                  elsif val_a >= 0 && val_a <= Int32::MAX && strings[val_a.to_i32!]?
                                    strings[val_a.to_i32!]
                                  else
                                    nil
                                  end
                          str_b = if val_b >= 0 && val_b < constants.size && constants[val_b.to_i]?.try(&.type) == 6_u8
                                    constants[val_b.to_i].str_val
                                  elsif val_b >= 0 && val_b <= Int32::MAX && strings[val_b.to_i32!]?
                                    strings[val_b.to_i32!]
                                  else
                                    nil
                                  end
                          if str_a && str_b
                            str_a == str_b
                          else
                            false
                          end
                        end
                regs[dst_r] = !is_eq ? 1_i64 : 0_i64
              when 32 # Lt
                regs[dst_r] = (regs[a_r] < regs[b_r]) ? 1_i64 : 0_i64
              when 33 # Le
                regs[dst_r] = (regs[a_r] <= regs[b_r]) ? 1_i64 : 0_i64
              when 34 # Gt
                regs[dst_r] = (regs[a_r] > regs[b_r]) ? 1_i64 : 0_i64
              when 35 # Ge
                regs[dst_r] = (regs[a_r] >= regs[b_r]) ? 1_i64 : 0_i64
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
                pc += imm16_signed if regs[dst_r] != 0
              when 42 # JumpIfFalse
                pc += imm16_signed if regs[dst_r] == 0
              when 50 # Call
                target_fn_idx = imm16.to_i
                if target_fn = fns[target_fn_idx]?
                  saved_pos = io.pos
                  io.pos = instructions_start_pos + (target_fn.offset.to_i64 * 4)
                  fn_instructions = [] of UInt32
                  target_fn.count.times do
                    fn_instructions << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
                  end
                  io.pos = saved_pos

                  call_stack << CallFrame.new(pc, instructions, dst_r, reg_base)
                  reg_base = (reg_base + dst + 1).clamp(0, 1000)
                  instructions = fn_instructions
                  pc = 0
                end
              when 51 # Return
                if frame = call_stack.pop?
                  ret_val = regs[dst_r]
                  reg_base = frame.caller_reg_base
                  regs[frame.caller_dest] = ret_val
                  instructions = frame.caller_instructions
                  pc = frame.return_pc
                else
                  break
                end
              when 70 # Halt
                break
              when 52 # CallNative
                base = a
                base_r = (reg_base + base).clamp(0, 1023)
                native_id = b

                case native_id
                when 3 # WindowOpen
                  in_main_loop = true
                  regs[dst_r] = 1_i64
                  break if is_dvd_screensaver
                when 40, 41, 42 # ButtonDown, ButtonPressed, ButtonReleased
                  btn_idx = regs[base_r].to_i
                  btn = constants[btn_idx]?.try(&.u32_val) || btn_idx.to_u32
                  if btn == 14 # Button::Cross
                    regs[dst_r] = simulated_button_press ? 1_i64 : 0_i64
                  else
                    regs[dst_r] = 0_i64
                  end
                when 11 # EndDrawing
                  # Rewind Tier 1 Per-Frame Scratch Pool at V-Blank (O(1))
                  scratch_pool_ptr = scratch_pool_base
                  allocations.reject! do |addr, a|
                    if a.is_struct || addr >= scratch_pool_base
                      (a.size_bytes // 4).times { |i| memory.delete(addr + (i * 4)) }
                      true
                    else
                      false
                    end
                  end

                  if current_commands.size > 0
                    if !animation_checked
                      if phases.empty?
                        # Record Frame 0 without simulated button press
                        prev_frame_cmds = current_commands.dup
                        phases << Phase.new(current_commands.dup, 1_u32, current_loop_message)
                        current_loop_message = nil
                        current_commands = [] of DrawCommand
                        simulated_button_press = false
                      else
                        # Frame 1: check if scene is moving autonomously
                        animation_checked = true
                        if current_commands != prev_frame_cmds
                          # Active animation loop!
                          is_animated = true
                          phases << Phase.new(current_commands.dup, 1_u32, current_loop_message)
                          current_loop_message = nil
                          current_commands = [] of DrawCommand
                          anim_frame_count = 2
                        elsif has_button_checks
                          # Static scene with button checks (e.g. 01_hello_pad, 08_controller_tester)
                          phases[0].delay_frames = 0_u32
                          button_phase_count += 1
                          simulated_button_press = true
                          current_commands = [] of DrawCommand
                        else
                          phases[0].delay_frames = 0_u32
                          first_frame_done = true
                        end
                      end
                    elsif is_animated
                      phases << Phase.new(current_commands.dup, 1_u32, current_loop_message)
                      current_loop_message = nil
                      current_commands = [] of DrawCommand
                      # Spawn next logo on the boundary between banks
                      if (phases.size % frames_per_bank) == 0 && anim_bank < (max_banks - 1)
                        simulated_button_press = true
                        anim_bank += 1
                      else
                        simulated_button_press = false
                      end

                      if phases.size >= max_banks * frames_per_bank
                        first_frame_done = true
                      end
                    else
                      # Static button handling
                      duplicate_idx = phases.index { |p| p.commands == current_commands }
                      if duplicate_idx
                        if duplicate_idx == 0 && current_loop_message
                          phases[0].message ||= current_loop_message
                        end
                        first_frame_done = true
                      else
                        phases << Phase.new(current_commands.dup, 0_u32, current_loop_message)
                        current_loop_message = nil
                        button_phase_count += 1
                        if button_phase_count >= 8
                          first_frame_done = true
                        else
                          simulated_button_press = true
                          current_commands = [] of DrawCommand
                        end
                      end
                    end
                  end
                when 12 # ClearBackground
                  val = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: color)
                when 20 # DrawRectangle
                  x = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  w = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  h = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x + w, y + h, color: color)
                when 21 # DrawCircle
                  cx = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  cy = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  radius = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Circle, cx, cy, 0, 0, 0, 0, radius: radius, color: color)
                when 22 # DrawLine
                  x1 = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y1 = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  x2 = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  y2 = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Line, x1, y1, x2, y2, color: color)
                when 23 # DrawTriangle
                  x1 = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y1 = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  x2 = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  y2 = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  x3 = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_i32!
                  y3 = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Triangle, x1, y1, x2, y2, x3, y3, color: color)
                when 24 # DrawText
                  t_val = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
                  text = constants[t_val.to_i32!]?.try(&.str_val) || ""
                  x = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  y = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  size = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Text, x, y, size, 0, color: color, text: text)
                when 25 # DrawQuad (decomposes to 2 triangles)
                  x1 = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y1 = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  x2 = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  y2 = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  x3 = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_i32!
                  y3 = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_i32!
                  x4 = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_i32!
                  y4 = (regs[base_r + 7] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 8] & 0xFFFFFFFF_i64).to_u32
                  color = constants[val.to_i32!]?.try(&.u32_val) || val
                  current_commands << DrawCommand.new(DrawCommand::Type::Quad, x1, y1, x2, y2, x3, y3, x4, y4, color: color)
                when 65 # Sleep(seconds)
                  sec = regs[base_r].to_i
                  sec = 1 if sec <= 0
                  delay_frames = (sec * 60).to_u32
                  phases << Phase.new(current_commands.dup, delay_frames, current_loop_message)
                  current_loop_message = nil
                  if phases.size >= 10
                    first_frame_done = true
                  end
                when 70, 71 # Log / puts / print / debug_puts / debug_log
                  t_idx = regs[base_r].to_i
                  text = constants[t_idx]?.try(&.str_val) || ""
                  unless text.empty?
                    if in_main_loop
                      if cur = current_loop_message
                        current_loop_message = "#{cur}\n#{text}"
                      else
                        current_loop_message = text
                      end
                    else
                      boot_messages << text
                    end
                  end
                  unless has_drawing
                    if current_commands.empty?
                      current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32)
                    end
                    text_count = current_commands.count { |c| c.type == DrawCommand::Type::Text }
                    if text_count >= 12
                      if first_idx = current_commands.index { |c| c.type == DrawCommand::Type::Text }
                        current_commands.delete_at(first_idx)
                      end
                      new_cmds = [] of DrawCommand
                      text_idx = 0
                      current_commands.each do |c|
                        if c.type == DrawCommand::Type::Text
                          new_cmds << DrawCommand.new(c.type, c.x1, 60 + (text_idx * 28), c.x2, c.y2, c.x3, c.y3, radius: c.radius, color: c.color, text: c.text)
                          text_idx += 1
                        else
                          new_cmds << c
                        end
                      end
                      current_commands = new_cmds
                    end
                    y_pos = 60 + (current_commands.count { |c| c.type == DrawCommand::Type::Text } * 28)
                    current_commands << DrawCommand.new(DrawCommand::Type::Text, 60, y_pos, 20, 0, color: 0xFFFFFFFF_u32, text: text)
                  end
                when 99 # Panic
                  t_idx = regs[base_r].to_i
                  text = constants[t_idx]?.try(&.str_val) || "Citrine PS2 VM Panic"
                  boot_messages << "[CITRINE PANIC] #{text}"
                when 120 # ArrayNew
                  arr_id = next_arr_id
                  next_arr_id += 1
                  arrays[arr_id] = [] of Int64
                  regs[dst_r] = arr_id
                when 121 # ArrayGet
                  arr_id = regs[base_r]
                  idx = regs[base_r + 1].to_i
                  if arr = arrays[arr_id]?
                    regs[dst_r] = arr[idx]? || 0_i64
                  elsif arr_id >= 0x00100000_i64
                    target_addr = arr_id + (idx.to_i64 * 4)
                    if target_addr == 0x70000010_i64 || target_addr == 0x70000018_i64
                      regs[dst_r] = simulated_button_press ? 0x4000_i64 : 0_i64
                    else
                      regs[dst_r] = memory[target_addr]? || 0_i64
                    end
                  else
                    regs[dst_r] = 0_i64
                  end
                when 122 # ArraySet
                  arr_id = regs[base_r]
                  idx = regs[base_r + 1].to_i
                  val = regs[base_r + 2]
                  if arr = arrays[arr_id]?
                    while arr.size <= idx
                      arr << 0_i64
                    end
                    arr[idx] = val
                  elsif arr_id >= 0x00100000_i64
                    target_addr = arr_id + (idx.to_i64 * 4)
                    memory[target_addr] = val
                  end
                  regs[dst_r] = val
                when 123 # ArrayPush
                  arr_id = regs[base_r]
                  val = regs[base_r + 1]
                  if arr = arrays[arr_id]?
                    arr << val
                  end
                  regs[dst_r] = arr_id
                when 124 # ArrayPop
                  arr_id = regs[base_r]
                  regs[dst_r] = arrays[arr_id]?.try(&.pop?) || 0_i64
                when 125 # ArraySize
                  arr_id = regs[base_r]
                  regs[dst_r] = (arrays[arr_id]?.try(&.size) || 0).to_i64
                when 126 # ArrayClear
                  arr_id = regs[base_r]
                  arrays[arr_id]?.try(&.clear)
                  regs[dst_r] = 0_i64
                when 130 # StaticArrayNew
                  sz = regs[base_r].to_i
                  def_val = regs[base_r + 1]
                  arr_id = next_arr_id
                  next_arr_id += 1
                  arrays[arr_id] = Array(Int64).new(sz, def_val)
                  regs[dst_r] = arr_id
                when 131 # StaticArrayGet
                  arr_id = regs[base_r]
                  idx = regs[base_r + 1].to_i
                  regs[dst_r] = arrays[arr_id]?.try(&.[idx]?) || 0_i64
                when 132 # StaticArraySet
                  arr_id = regs[base_r]
                  idx = regs[base_r + 1].to_i
                  val = regs[base_r + 2]
                  if arr = arrays[arr_id]?
                    while arr.size <= idx
                      arr << 0_i64
                    end
                    arr[idx] = val
                  end
                  regs[dst_r] = val
                when 133 # StaticArraySize
                  arr_id = regs[base_r]
                  regs[dst_r] = (arrays[arr_id]?.try(&.size) || 0).to_i64
                when 140 # MemoryIONew
                  io_id = next_io_id
                  next_io_id += 1
                  io_streams[io_id] = IO::Memory.new
                  regs[dst_r] = io_id
                when 141 # MemoryIOWriteByte
                  io_id = regs[base_r]
                  byte = regs[base_r + 1].to_u8
                  io_streams[io_id]?.try(&.write_byte(byte))
                  regs[dst_r] = 1_i64
                when 142 # MemoryIOWrite
                  io_id = regs[base_r]
                  t_idx = regs[base_r + 1].to_i
                  str = constants[t_idx]?.try(&.str_val) || ""
                  io_streams[io_id]?.try(&.print(str))
                  regs[dst_r] = str.bytesize.to_i64
                when 143 # MemoryIOPuts
                  io_id = regs[base_r]
                  t_idx = regs[base_r + 1].to_i
                  str = constants[t_idx]?.try(&.str_val) || ""
                  io_streams[io_id]?.try(&.puts(str))
                  boot_messages << str unless str.empty?
                  regs[dst_r] = (str.bytesize + 1).to_i64
                when 144 # MemoryIOToS
                  io_id = regs[base_r]
                  str = io_streams[io_id]?.try(&.to_s) || ""
                  s_idx = strings.index(str) || (strings << str; strings.size - 1)
                  constants << CVal.new(6_u8, 0_u32, str)
                  regs[dst_r] = (constants.size - 1).to_i64
                when 145 # MemoryIORewind
                  io_id = regs[base_r]
                  io_streams[io_id]?.try(&.rewind)
                  regs[dst_r] = 0_i64
                when 146 # MemoryIOPos
                  io_id = regs[base_r]
                  regs[dst_r] = (io_streams[io_id]?.try(&.pos) || 0).to_i64
                when 147 # MemoryIOSize
                  io_id = regs[base_r]
                  regs[dst_r] = (io_streams[io_id]?.try(&.size) || 0).to_i64
                when 148 # MemoryIOClear
                  io_id = regs[base_r]
                  io_streams[io_id]?.try(&.clear)
                  regs[dst_r] = 0_i64
                when 150 # ObjectNew
                  cid = regs[base_r].to_u32
                  field_count = regs[base_r + 1].to_i
                  is_struct = (regs[base_r + 2]? || 0_i64) == 1_i64
                  size_bytes = (8 + (field_count * 4) + 7) & ~7 # 8-byte aligned

                  if is_struct
                    obj_addr = scratch_pool_ptr
                    scratch_pool_ptr += size_bytes
                  else
                    found_idx = free_list.index { |(_, sz)| sz >= size_bytes }
                    if found_idx
                      obj_addr, _ = free_list.delete_at(found_idx)
                    else
                      obj_addr = next_heap_addr
                      next_heap_addr += size_bytes
                    end
                  end

                  memory[obj_addr] = cid.to_i64
                  memory[obj_addr + 4] = field_count.to_i64
                  field_count.times do |i|
                    memory[obj_addr + 8 + (i * 4)] = 0_i64
                  end

                  allocations[obj_addr] = AllocationRecord.new(
                    obj_addr, size_bytes, active_context_name,
                    freed: false, is_object: true, is_struct: is_struct, field_count: field_count
                  )
                  object_classes[obj_addr] = cid
                  objects[obj_addr] = Array(Int64).new(field_count, 0_i64)
                  regs[dst_r] = obj_addr
                when 151 # ObjectGetField
                  obj_id = regs[base_r]
                  f_idx = regs[base_r + 1].to_i
                  if alloc = allocations[obj_id]?
                    if alloc.freed
                      boot_messages << "[CITRINE MEMORY ERROR] Use-after-free: read from freed object at 0x#{obj_id.to_s(16)}"
                      regs[dst_r] = 0_i64
                    elsif f_idx < 0 || f_idx >= alloc.field_count
                      boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} for field_count #{alloc.field_count}"
                      regs[dst_r] = 0_i64
                    else
                      regs[dst_r] = memory[obj_id + 8 + (f_idx * 4)]? || 0_i64
                    end
                  elsif obj = objects[obj_id]?
                    if f_idx < 0 || f_idx >= obj.size
                      boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} for size #{obj.size}"
                      regs[dst_r] = 0_i64
                    else
                      regs[dst_r] = obj[f_idx]? || 0_i64
                    end
                  else
                    regs[dst_r] = memory[obj_id + 8 + (f_idx * 4)]? || 0_i64
                  end
                when 152 # ObjectSetField
                  obj_id = regs[base_r]
                  f_idx = regs[base_r + 1].to_i
                  val = regs[base_r + 2]
                  if alloc = allocations[obj_id]?
                    if alloc.freed
                      boot_messages << "[CITRINE MEMORY ERROR] Use-after-free: write to freed object at 0x#{obj_id.to_s(16)}"
                    elsif f_idx < 0 || f_idx >= alloc.field_count
                      boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} for field_count #{alloc.field_count}"
                    else
                      memory[obj_id + 8 + (f_idx * 4)] = val
                      if obj = objects[obj_id]?
                        while obj.size <= f_idx; obj << 0_i64; end
                        obj[f_idx] = val
                      end
                    end
                  elsif obj = objects[obj_id]?
                    if f_idx < 0
                      boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} < 0"
                    else
                      while obj.size <= f_idx; obj << 0_i64; end
                      obj[f_idx] = val
                      memory[obj_id + 8 + (f_idx * 4)] = val
                    end
                  else
                    memory[obj_id + 8 + (f_idx * 4)] = val
                  end
                  regs[dst_r] = val
                when 153 # StructCopy
                  src_addr = regs[base_r]
                  if alloc = allocations[src_addr]?
                    size_bytes = alloc.size_bytes
                    copy_addr = scratch_pool_ptr
                    scratch_pool_ptr += size_bytes
                    (size_bytes // 4).times do |i|
                      memory[copy_addr + (i * 4)] = memory[src_addr + (i * 4)]? || 0_i64
                    end
                    allocations[copy_addr] = AllocationRecord.new(
                      copy_addr, size_bytes, active_context_name,
                      freed: false, is_object: true, is_struct: true, field_count: alloc.field_count
                    )
                    if cid = object_classes[src_addr]?
                      object_classes[copy_addr] = cid
                    end
                    if obj = objects[src_addr]?
                      objects[copy_addr] = obj.dup
                    end
                    regs[dst_r] = copy_addr
                  else
                    regs[dst_r] = src_addr
                  end
                when 160 # PointerMalloc
                  cnt = regs[base_r].to_i
                  cnt = 1 if cnt <= 0
                  size_bytes = ((cnt * 4) + 7) & ~7 # 8-byte aligned

                  found_idx = free_list.index { |(_, sz)| sz >= size_bytes }
                  if found_idx
                    ptr_addr, _ = free_list.delete_at(found_idx)
                  else
                    ptr_addr = next_heap_addr
                    next_heap_addr += size_bytes
                  end

                  cnt.times { |i| memory[ptr_addr + (i.to_i64 * 4)] = 0_i64 }
                  allocations[ptr_addr] = AllocationRecord.new(
                    ptr_addr, size_bytes, active_context_name,
                    freed: false, is_object: false, is_struct: false
                  )
                  regs[dst_r] = ptr_addr
                when 161 # PointerGet
                  addr = regs[base_r]
                  idx = regs[base_r + 1]
                  if addr < 0x00100000_i64 && idx == 0_i64
                    regs[dst_r] = addr
                  else
                    target_addr = addr + (idx * 4)
                    if alloc = allocations[addr]?
                      if alloc.freed
                        boot_messages << "[CITRINE MEMORY ERROR] Use-after-free detected at address 0x#{target_addr.to_s(16)}"
                      end
                    end
                    if target_addr == 0x70000010_i64 || target_addr == 0x70000018_i64
                    regs[dst_r] = simulated_button_press ? 0x4000_i64 : 0_i64
                  elsif target_addr == 0x10000800_i64
                    regs[dst_r] = (steps * 13) & 0xFFFF_i64
                  elsif target_addr == 0x12001000_i64
                    regs[dst_r] = (steps * 7) & 0xFFFF_i64
                  elsif arr = arrays[addr]?
                    if idx < 0 || idx >= arr.size
                      boot_messages << "[CITRINE PANIC] Array index out of bounds: #{idx}"
                      regs[dst_r] = 0_i64
                    else
                      regs[dst_r] = arr[idx.to_i]? || 0_i64
                    end
                  else
                    regs[dst_r] = memory[target_addr]? || 0_i64
                  end
                end
                when 162 # PointerSet
                  addr = regs[base_r]
                  idx = regs[base_r + 1]
                  val = regs[base_r + 2]
                  target_addr = addr + (idx * 4)
                  if alloc = allocations[addr]?
                    if alloc.freed
                      boot_messages << "[CITRINE MEMORY ERROR] Use-after-free detected at address 0x#{target_addr.to_s(16)}"
                    end
                  end
                  if target_addr >= 0x00100000_i64 && target_addr < 0x00200000_i64
                    boot_messages << "[CITRINE PANIC] Memory protection violation: attempt to write to read-only code space at 0x#{target_addr.to_s(16)}"
                  elsif arr = arrays[addr]?
                    if idx < 0
                      boot_messages << "[CITRINE PANIC] Array index out of bounds: #{idx} < 0"
                    else
                      while arr.size <= idx.to_i
                        arr << 0_i64
                      end
                      arr[idx.to_i] = val
                    end
                  else
                    memory[target_addr] = val
                  end
                  regs[dst_r] = val
                when 163 # PointerOffset
                  addr = regs[base_r]
                  off = regs[base_r + 1]
                  regs[dst_r] = addr + (off * 4)
                when 164 # PointerAddress
                  regs[dst_r] = regs[base_r]
                when 165 # PointerNew
                  regs[dst_r] = regs[base_r]
                when 166 # BoxNew
                  val = regs[base_r]
                  box_addr = next_heap_addr
                  next_heap_addr += 4_i64
                  memory[box_addr] = val
                  regs[dst_r] = box_addr
                when 167 # BoxUnbox
                  box_addr = regs[base_r]
                  regs[dst_r] = memory[box_addr]? || 0_i64
                when 168 # PointerFree
                  addr = regs[base_r]
                  if alloc = allocations[addr]?
                    if alloc.freed
                      boot_messages << "[CITRINE MEMORY ERROR] Double free detected on pointer 0x#{addr.to_s(16)}"
                    else
                      alloc.freed = true
                      (alloc.size_bytes // 4).times do |i|
                        memory.delete(addr + (i * 4))
                      end
                      objects.delete(addr)
                      arrays.delete(addr)
                      free_list << {addr, alloc.size_bytes}
                    end
                  elsif memory.has_key?(addr) || objects.has_key?(addr) || arrays.has_key?(addr)
                    memory.delete(addr)
                    objects.delete(addr)
                    arrays.delete(addr)
                  else
                    boot_messages << "[CITRINE MEMORY ERROR] Free called on unallocated pointer 0x#{addr.to_s(16)}"
                  end
                  regs[dst_r] = 0_i64
                when 170 # TypeIsA
                  val = regs[base_r]
                  target_id = regs[base_r + 1].to_u32
                  is_match = false
                  if target_id == TypeKind::Nil.value
                    is_match = val == 0_i64
                  elsif target_id == TypeKind::Bool.value
                    is_match = val == 0_i64 || val == 1_i64
                  elsif target_id == TypeKind::Int32.value
                    is_match = val >= -2147483648_i64 && val <= 2147483647_i64
                  elsif target_id == TypeKind::Float32.value
                    is_match = true
                  elsif target_id == TypeKind::String.value
                    is_match = val < constants.size && constants[val.to_i]?.try(&.type) == 6_u8
                  elsif target_id == TypeKind::Array.value
                    is_match = arrays.has_key?(val)
                  elsif target_id == TypeKind::Pointer.value
                    is_match = val >= 0x00100000_i64
                  elsif target_id == TypeKind::Box.value
                    is_match = val >= 0x00100000_i64
                  elsif obj_cid = object_classes[val]?
                    is_match = obj_cid == target_id
                  end
                  regs[dst_r] = is_match ? 1_i64 : 0_i64
                when 171 # TypeAsCast
                  val = regs[base_r]
                  regs[dst_r] = val
                when 180 # ContextSet
                  s_idx = regs[base_r].to_i
                  ctx_str = constants[s_idx]?.try(&.str_val) || ""
                  active_context_name = ctx_str
                  regs[dst_r] = s_idx.to_i64
                when 181 # ContextClear
                  s_idx = regs[base_r].to_i
                  ctx_str = constants[s_idx]?.try(&.str_val) || ""
                  reclaimed_bytes = 0_i64
                  allocations.reject! do |addr, a|
                    if a.context_name == ctx_str
                      a.freed = true
                      (a.size_bytes // 4).times { |i| memory.delete(addr + (i * 4)) }
                      objects.delete(addr)
                      arrays.delete(addr)
                      free_list << {addr, a.size_bytes}
                      reclaimed_bytes += a.size_bytes
                      true
                    else
                      false
                    end
                  end
                  regs[dst_r] = reclaimed_bytes
                when 182 # MemoryStats
                  active_bytes = allocations.values.reject(&.freed).sum(&.size_bytes)
                  regs[dst_r] = active_bytes.to_i64
                when 185 # GCCycle / GC.collect
                  marked_objects = Set(Int64).new
                  marked_arrays = Set(Int64).new
                  (0...regs.size).each do |r|
                    val = regs[r]
                    marked_objects << val if objects.has_key?(val)
                    marked_arrays << val if arrays.has_key?(val)
                  end
                  memory.each do |addr, val|
                    if addr >= 0x00300000_i64 && addr < 0x00310000_i64
                      marked_objects << val if objects.has_key?(val)
                      marked_arrays << val if arrays.has_key?(val)
                    end
                  end
                  changed = true
                  while changed
                    changed = false
                    marked_objects.to_a.each do |oid|
                      if fields = objects[oid]?
                        fields.each do |fval|
                          if objects.has_key?(fval) && !marked_objects.includes?(fval)
                            marked_objects << fval
                            changed = true
                          elsif arrays.has_key?(fval) && !marked_arrays.includes?(fval)
                            marked_arrays << fval
                            changed = true
                          end
                        end
                      end
                    end
                    marked_arrays.to_a.each do |aid|
                      if elems = arrays[aid]?
                        elems.each do |eval|
                          if objects.has_key?(eval) && !marked_objects.includes?(eval)
                            marked_objects << eval
                            changed = true
                          elsif arrays.has_key?(eval) && !marked_arrays.includes?(eval)
                            marked_arrays << eval
                            changed = true
                          end
                        end
                      end
                    end
                  end
                  reclaimed = 0_i64
                  objects.reject! do |oid, _|
                    if marked_objects.includes?(oid)
                      false
                    else
                      reclaimed += 1
                      true
                    end
                  end
                  arrays.reject! do |aid, _|
                    if marked_arrays.includes?(aid)
                      false
                    else
                      reclaimed += 1
                      true
                    end
                  end
                  regs[dst_r] = reclaimed
                when 186 # StringStrip
                  s_val = regs[base_r]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  stripped = raw.strip
                  strings << stripped unless strings.includes?(stripped)
                  c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == stripped } ||
                          (constants << CVal.new(6_u8, 0_u32, stripped); constants.size - 1)
                  regs[dst_r] = c_idx.to_i64
                when 187 # StringDowncase
                  s_val = regs[base_r]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  down = raw.downcase
                  strings << down unless strings.includes?(down)
                  c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == down } ||
                          (constants << CVal.new(6_u8, 0_u32, down); constants.size - 1)
                  regs[dst_r] = c_idx.to_i64
                when 188 # StringUpcase
                  s_val = regs[base_r]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  up = raw.upcase
                  strings << up unless strings.includes?(up)
                  c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == up } ||
                          (constants << CVal.new(6_u8, 0_u32, up); constants.size - 1)
                  regs[dst_r] = c_idx.to_i64
                when 189 # StringIncludes
                  s_val = regs[base_r]
                  sub_val = regs[base_r + 1]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  sub = if sub_val < constants.size && constants[sub_val.to_i]?.try(&.type) == 6_u8
                          constants[sub_val.to_i].str_val
                        else
                          strings[sub_val.to_i]? || ""
                        end
                  regs[dst_r] = raw.includes?(sub) ? 1_i64 : 0_i64
                when 190 # RegexNew
                  s_val = regs[base_r]
                  pat = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  rid = next_regex_id
                  next_regex_id += 1
                  compiled_regexes[rid] = SimpleRegex.new(pat)
                  regs[dst_r] = rid
                when 191 # RegexMatch
                  arg0 = regs[base_r]
                  arg1 = regs[base_r + 1]
                  target_str = ""
                  re : SimpleRegex? = nil

                  if compiled_regexes.has_key?(arg1)
                    re = compiled_regexes[arg1]
                    target_str = if arg0 < constants.size && constants[arg0.to_i]?.try(&.type) == 6_u8
                                   constants[arg0.to_i].str_val
                                 else
                                   strings[arg0.to_i]? || ""
                                 end
                  elsif compiled_regexes.has_key?(arg0)
                    re = compiled_regexes[arg0]
                    target_str = if arg1 < constants.size && constants[arg1.to_i]?.try(&.type) == 6_u8
                                   constants[arg1.to_i].str_val
                                 else
                                   strings[arg1.to_i]? || ""
                                 end
                  else
                    pat = if arg1 < constants.size && constants[arg1.to_i]?.try(&.type) == 6_u8
                            constants[arg1.to_i].str_val
                          else
                            strings[arg1.to_i]? || ""
                          end
                    re = SimpleRegex.new(pat)
                    target_str = if arg0 < constants.size && constants[arg0.to_i]?.try(&.type) == 6_u8
                                   constants[arg0.to_i].str_val
                                 else
                                   strings[arg0.to_i]? || ""
                                 end
                  end

                  m_pos = re.try(&.match(target_str))
                  regs[dst_r] = m_pos ? m_pos.to_i64 : -1_i64
                when 192 # StringStartsWith
                  s_val = regs[base_r]
                  sub_val = regs[base_r + 1]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  sub = if sub_val < constants.size && constants[sub_val.to_i]?.try(&.type) == 6_u8
                          constants[sub_val.to_i].str_val
                        else
                          strings[sub_val.to_i]? || ""
                        end
                  regs[dst_r] = raw.starts_with?(sub) ? 1_i64 : 0_i64
                when 193 # StringEndsWith
                  s_val = regs[base_r]
                  sub_val = regs[base_r + 1]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  sub = if sub_val < constants.size && constants[sub_val.to_i]?.try(&.type) == 6_u8
                          constants[sub_val.to_i].str_val
                        else
                          strings[sub_val.to_i]? || ""
                        end
                  regs[dst_r] = raw.ends_with?(sub) ? 1_i64 : 0_i64
                when 194 # StringSplit
                  s_val = regs[base_r]
                  delim_val = regs[base_r + 1]
                  raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                          constants[s_val.to_i].str_val
                        else
                          strings[s_val.to_i]? || ""
                        end
                  delim = if delim_val < constants.size && constants[delim_val.to_i]?.try(&.type) == 6_u8
                            constants[delim_val.to_i].str_val
                          else
                            strings[delim_val.to_i]? || " "
                          end
                  parts = raw.split(delim)
                  arr_id = next_arr_id
                  next_arr_id += 1
                  arr_elems = [] of Int64
                  parts.each do |part|
                    strings << part unless strings.includes?(part)
                    c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == part } ||
                            (constants << CVal.new(6_u8, 0_u32, part); constants.size - 1)
                    arr_elems << c_idx.to_i64
                  end
                  arrays[arr_id] = arr_elems
                  regs[dst_r] = arr_id
                when 195 # StringConcat
                  s1_val = regs[base_r]
                  s2_val = regs[base_r + 1]
                  raw1 = if s1_val >= 0 && s1_val < constants.size && constants[s1_val.to_i]?.try(&.type) == 6_u8
                           constants[s1_val.to_i].str_val
                         elsif strings[s1_val.to_i]?
                           strings[s1_val.to_i]
                         else
                           s1_val.to_s
                         end
                  raw2 = if s2_val >= 0 && s2_val < constants.size && constants[s2_val.to_i]?.try(&.type) == 6_u8
                           constants[s2_val.to_i].str_val
                         elsif strings[s2_val.to_i]?
                           strings[s2_val.to_i]
                         else
                           s2_val.to_s
                         end
                  joined = raw1 + raw2
                  strings << joined unless strings.includes?(joined)
                  c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == joined } ||
                          (constants << CVal.new(6_u8, 0_u32, joined); constants.size - 1)
                  regs[dst_r] = c_idx.to_i64
                when 196 # ToString
                  val = regs[base_r]
                  hint = (base_r + 1 < regs.size) ? regs[base_r + 1] : 0_i64
                  val_str = case hint
                            when 2 # Bool
                              val != 0_i64 ? "true" : "false"
                            when 3 # String
                              if val >= 0 && val < constants.size && constants[val.to_i]?.try(&.type) == 6_u8
                                constants[val.to_i].str_val
                              elsif strings[val.to_i]?
                                strings[val.to_i]
                              else
                                val.to_s
                              end
                            else # 0 (Int), 1 (Float), default
                              val.to_s
                            end
                  strings << val_str unless strings.includes?(val_str)
                  c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == val_str } ||
                          (constants << CVal.new(6_u8, 0_u32, val_str); constants.size - 1)
                  regs[dst_r] = c_idx.to_i64
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
              phases << Phase.new(current_commands.dup, 0_u32, current_loop_message)
            end

            if is_dvd_screensaver
              return {[] of Phase, boot_messages, 0, false, true}
            end

            loop_start = (phases.size > 1 && phases[0].message.nil? && !has_button_checks && !is_animated) ? 1 : 0
            return {phases, boot_messages, loop_start, is_animated, false}
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
      {fallback_phases, boot_messages, 0, false, false}
    end
  end
end
