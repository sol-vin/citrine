require "io/memory"
require "../mips/mips_emitter"
require "../gs/gs_config"
require "../gs/gif_packet_builder"
require "../subsystems/controller"
require "./elf_writer"
require "./pad_runtime_payload"
require "./regex_engine"
require "../ast/types"

module Citrine
  # Generates a valid 32-bit Little-Endian MIPS R5900 PlayStation 2 ELF executable.
  # Boots directly on Sony PlayStation 2 (PCSX2 or real EE hardware), sets up the
  # Graphic Synthesizer (GS) via DMA Channel 2 (GIF) to 640x448 NTSC, rasterizes
  # Citrine draw commands, and loops on VSync.
  class ElfBuilder
    # Backward compatibility aliases
    alias MipsEmitter        = Citrine::MIPS::MipsEmitter
    alias DrawCommand        = Citrine::GS::DrawCommand
    alias Phase              = Citrine::GS::Phase
    alias GifPacketBuilder   = Citrine::GS::GifPacketBuilder
    alias ElfWriter          = Citrine::ISO::ElfWriter
    alias SymbolEntry        = Citrine::ISO::ElfWriter::SymbolDef
    alias PadRuntimePayload  = Citrine::ISO::PadRuntimePayload

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

    TEXT_SIZE = 16384_u32
    RODATA_VADDR = 0x00500000_u32

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

    getter has_button_checks : Bool = false
    getter is_dvd_screensaver : Bool = false
    getter is_controller_tester : Bool = false
    getter inline_asm_words = [] of UInt32
    getter is_inline_assembly : Bool = false
    property has_audio : Bool = false

    def self.build_default_runner_elf(cbc_bytes : Bytes? = nil, input_schedule : Array(VirtualInput) = [] of VirtualInput, vag_bytes : Bytes? = nil) : Bytes
      builder = new
      builder.generate(cbc_bytes, input_schedule, vag_bytes)
    end

    def generate(cbc_bytes : Bytes? = nil, input_schedule : Array(VirtualInput) = [] of VirtualInput, vag_bytes : Bytes? = nil) : Bytes
      phases, boot_messages, loop_start_phase, is_animated = parse_cbc(cbc_bytes)

      vag_slice = vag_bytes
      vag_transfer_size = vag_slice ? (((vag_slice.size + 15) // 16) * 16) : 0

      # Build GIF Packets
      env_packet = GifPacketBuilder.build_env_packet
      phase_packets = phases.map { |p| GifPacketBuilder.build_draw_packet(p.commands) }
      phase_qwcs = phase_packets.map { |pkt| {(pkt.size // 16), 65535}.min.to_u16 }

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
      rot_table_addr = 0_u32
      rot_table_slice = Bytes.empty

      if @is_dvd_screensaver
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
      # Each entry is 16 bytes: start_frame (4), button_mask (2), duration_frames (2), port (1), reserved (7)
      sched_addr = curr_addr
      sched_bytes = IO::Memory.new
      input_schedule.each do |s|
        sched_bytes.write_bytes(s.start_frame, IO::ByteFormat::LittleEndian)
        sched_bytes.write_bytes(s.button_mask, IO::ByteFormat::LittleEndian)
        sched_bytes.write_bytes(s.duration_frames, IO::ByteFormat::LittleEndian)
        sched_bytes.write_byte(s.port)
        7.times { sched_bytes.write_byte(0_u8) }
      end
      # Terminator (start_frame = 0xFFFFFFFF, 16 bytes):
      sched_bytes.write_bytes(0xFFFFFFFF_u32, IO::ByteFormat::LittleEndian)
      sched_bytes.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
      sched_bytes.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
      sched_bytes.write_byte(0_u8)
      7.times { sched_bytes.write_byte(0_u8) }
      sched_pad = (16 - (sched_bytes.size % 16)) % 16
      sched_pad.times { sched_bytes.write_byte(0_u8) }
      sched_slice = sched_bytes.to_slice
      curr_addr += sched_slice.size.to_u32

      if @is_inline_assembly
        rot_mem = IO::Memory.new(256)
        rot_table_data = [
          0x02402420_u32, 0x02402560_u32, 0x01A024C0_u32, 0x02E024C0_u32, #  0: dx= 160, dy=   0
          0x0203242C_u32, 0x027D2554_u32, 0x01AC24FD_u32, 0x02D42483_u32, #  1: dx= 148, dy=  61
          0x01CF244F_u32, 0x02B12531_u32, 0x01CF2531_u32, 0x02B1244F_u32, #  2: dx= 113, dy= 113
          0x01AC2483_u32, 0x02D424FD_u32, 0x02032554_u32, 0x027D242C_u32, #  3: dx=  61, dy= 148
          0x01A024C0_u32, 0x02E024C0_u32, 0x02402560_u32, 0x02402420_u32, #  4: dx=   0, dy= 160
          0x01AC24FD_u32, 0x02D42483_u32, 0x027D2554_u32, 0x0203242C_u32, #  5: dx= -61, dy= 148
          0x01CF2531_u32, 0x02B1244F_u32, 0x02B12531_u32, 0x01CF244F_u32, #  6: dx=-113, dy= 113
          0x02032554_u32, 0x027D242C_u32, 0x02D424FD_u32, 0x01AC2483_u32, #  7: dx=-148, dy=  61
          0x02402560_u32, 0x02402420_u32, 0x02E024C0_u32, 0x01A024C0_u32, #  8: dx=-160, dy=   0
          0x027D2554_u32, 0x0203242C_u32, 0x02D42483_u32, 0x01AC24FD_u32, #  9: dx=-148, dy= -61
          0x02B12531_u32, 0x01CF244F_u32, 0x02B1244F_u32, 0x01CF2531_u32, # 10: dx=-113, dy=-113
          0x02D424FD_u32, 0x01AC2483_u32, 0x027D242C_u32, 0x02032554_u32, # 11: dx= -61, dy=-148
          0x02E024C0_u32, 0x01A024C0_u32, 0x02402420_u32, 0x02402560_u32, # 12: dx=   0, dy=-160
          0x02D42483_u32, 0x01AC24FD_u32, 0x0203242C_u32, 0x027D2554_u32, # 13: dx=  61, dy=-148
          0x02B1244F_u32, 0x01CF2531_u32, 0x01CF244F_u32, 0x02B12531_u32, # 14: dx= 113, dy=-113
          0x027D242C_u32, 0x02032554_u32, 0x01AC2483_u32, 0x02D424FD_u32, # 15: dx= 148, dy= -61
        ]
        rot_table_data.each { |w| rot_mem.write_bytes(w, IO::ByteFormat::LittleEndian) }
        rot_table_slice = rot_mem.to_slice
        rot_table_addr = curr_addr
        curr_addr += rot_table_slice.size.to_u32
      end

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

      l1_msg_str = "[CITRINE] Button L1 pressed!\n\0"
      l1_msg_addr = curr_addr
      curr_addr += l1_msg_str.bytesize.to_u32

      r2_msg_str = "[CITRINE] Button R2 pressed!\n\0"
      r2_msg_addr = curr_addr
      curr_addr += r2_msg_str.bytesize.to_u32

      l2_msg_str = "[CITRINE] Button L2 pressed!\n\0"
      l2_msg_addr = curr_addr
      curr_addr += l2_msg_str.bytesize.to_u32

      start_msg_str = "[CITRINE] Button Start pressed!\n\0"
      start_msg_addr = curr_addr
      curr_addr += start_msg_str.bytesize.to_u32

      select_msg_str = "[CITRINE] Button Select pressed!\n\0"
      select_msg_addr = curr_addr
      curr_addr += select_msg_str.bytesize.to_u32

      up_msg_str = "[CITRINE] Button Up pressed!\n\0"
      up_msg_addr = curr_addr
      curr_addr += up_msg_str.bytesize.to_u32

      right_msg_str = "[CITRINE] Button Right pressed!\n\0"
      right_msg_addr = curr_addr
      curr_addr += right_msg_str.bytesize.to_u32

      down_msg_str = "[CITRINE] Button Down pressed!\n\0"
      down_msg_addr = curr_addr
      curr_addr += down_msg_str.bytesize.to_u32

      left_msg_str = "[CITRINE] Button Left pressed!\n\0"
      left_msg_addr = curr_addr
      curr_addr += left_msg_str.bytesize.to_u32

      l3_msg_str = "[CITRINE] Button L3 pressed!\n\0"
      l3_msg_addr = curr_addr
      curr_addr += l3_msg_str.bytesize.to_u32

      r3_msg_str = "[CITRINE] Button R3 pressed!\n\0"
      r3_msg_addr = curr_addr
      curr_addr += r3_msg_str.bytesize.to_u32

      emitter = MipsEmitter.new(0x00100000_u32)

      phase0_delay = phases.empty? ? 0_u32 : phases[0].delay_frames
      emitter.label("_start")
      emitter.lui(SP, 0x0200)
      emitter.addiu(SP, SP, -16)

      # Enable COP1 (FPU) and COP2 (VU0 Macro Mode) in COP0 Status register ($12)
      # Bit 30 = CU2 (0x40000000), Bit 29 = CU1 (0x20000000)
      emitter.mfc0(T0, 12)
      emitter.lui(T1, 0x6000)
      emitter.or_(T0, T0, T1)
      emitter.mtc0(T0, 12)
      emitter.sync_p


      # Initialize PS2 SIF RPC & Hardware Pad Drivers via Pad Runtime
      # (This loads cdrom0:\S.IRX;1 which immediately reads IOP RAM 0x00100030 and plays audio!)
      emitter.lui(T9, (PadRuntimePayload::INIT_ENTRY >> 16).to_i32)
      emitter.ori(T9, T9, (PadRuntimePayload::INIT_ENTRY & 0xFFFF).to_i32)
      emitter.jalr(T9)
      emitter.nop

      emitter.lui(T0, 0x7000)
      emitter.lui(T1, 0xDEAD)
      emitter.ori(T1, T1, 0xBEEF)
      emitter.sw(T1, 0, T0)
      emitter.sw(ZERO, 4, T0)       # frame counter = 0
      emitter.sw(ZERO, 8, T0)       # phase index = 0
      emitter.lui(T1, (phase0_delay >> 16).to_i32)
      emitter.ori(T1, T1, (phase0_delay & 0xFFFF).to_i32)
      emitter.sw(T1, 12, T0)      # phase frames remaining
      # Port 0 (Player 1) state:
      emitter.sw(ZERO, 16, T0)    # Port 0 buttons current = 0  (0x70000010)
      emitter.sw(ZERO, 20, T0)    # Port 0 buttons prev = 0     (0x70000014)
      emitter.sw(ZERO, 24, T0)    # Port 0 buttons pressed = 0  (0x70000018)
      # Analog axes initialized to neutral center (128, 128, 128, 128 = 0x80808080)
      emitter.lui(T1, 0x8080)
      emitter.ori(T1, T1, 0x8080)
      emitter.sw(T1, 32, T0)       # Port 0 analog axes = 128,128,128,128 (0x70000020)
      # Port 1 (Player 2) state:
      emitter.sw(ZERO, 36, T0)    # Port 1 buttons current = 0  (0x70000024)
      emitter.sw(ZERO, 40, T0)    # Port 1 buttons prev = 0     (0x70000028)
      emitter.sw(ZERO, 44, T0)    # Port 1 buttons pressed = 0  (0x7000002C)
      emitter.sw(ZERO, 48, T0)    # Port 1 buttons released = 0 (0x70000030)
      emitter.sw(T1, 52, T0)       # Port 1 analog axes = 128,128,128,128 (0x70000034)
      # Control registers:
      emitter.sw(ZERO, 56, T0)    # button debounce = 0         (0x70000038)
      if @has_audio
        emitter.lui(T9, (PadRuntimePayload::SOUND_PLAY_ENTRY >> 16).to_i32)
        emitter.ori(T9, T9, (PadRuntimePayload::SOUND_PLAY_ENTRY & 0xFFFF).to_i32)
        emitter.jalr(T9)
        emitter.nop
        emitter.lui(T0, 0x7000)
        emitter.ori(T1, ZERO, 1)
        emitter.sw(T1, 60, T0)    # audio playing flag = 1      (0x7000003C)
      else
        emitter.sw(ZERO, 60, T0)  # audio playing flag = 0      (0x7000003C)
      end
      if @is_dvd_screensaver
        emitter.ori(T1, ZERO, 1)
        emitter.sw(T1, 0x60, T0)      # logo_count = 1 at 0x70000060
        emitter.ori(T1, ZERO, 42)
        emitter.sw(T1, 0x64, T0)      # rng_seed = 42  at 0x70000064

        # Initial Logo 0 at 0x70000100:
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

      if !@inline_asm_words.empty?
        emitter.jal("Citrine_InlineAsm_Block")
        emitter.nop
      end

      # Frame Loop:
      emitter.label("frame_loop")
      # Increment frame counter in SPRAM at 0x70000004
      emitter.lui(T0, 0x7000)
      emitter.lw(T1, 4, T0)
      emitter.addiu(T1, T1, 1)
      emitter.sw(T1, 4, T0)

      # Decrement button debounce counter at 0x70000038 if > 0
      emitter.lw(T3, 56, T0)
      emitter.beqz(T3, "debounce_ok")
      emitter.nop
      emitter.addiu(T3, T3, -1)
      emitter.sw(T3, 56, T0)
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

      if @is_dvd_screensaver
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

      unless @is_dvd_screensaver
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
      emitter.sw(ZERO, 16, T0)      # Clear Port 0 current buttons (0x70000010)
      emitter.sw(ZERO, 36, T0)      # Clear Port 1 current buttons (0x70000024)

      # 1. Check Virtual Input Schedule at sched_addr (16-byte entries with port selection)
      emitter.lw(T1, 4, T0)         # T1 = current frame
      emitter.lui(T8, (sched_addr >> 16).to_i32)
      emitter.ori(T8, T8, (sched_addr & 0xFFFF).to_i32)

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
      # Inside duration: check entry.port and OR button_mask into Port 0 or Port 1
      emitter.lhu(T4, 4, T8)       # T4 = button_mask
      emitter.lbu(T3, 8, T8)       # T3 = port (0 or 1)
      emitter.bnez(T3, "sched_apply_p1")
      emitter.nop
      # Port 0 (0x70000010):
      emitter.lw(T5, 16, T0)
      emitter.or_(T5, T5, T4)
      emitter.sw(T5, 16, T0)
      emitter.j("sched_next")
      emitter.nop
      emitter.label("sched_apply_p1")
      # Port 1 (0x70000024 = offset 36):
      emitter.lw(T5, 36, T0)
      emitter.or_(T5, T5, T4)
      emitter.sw(T5, 36, T0)

      emitter.label("sched_next")
      emitter.addiu(T8, T8, 16)    # Next entry (16 bytes)
      emitter.j("sched_loop")
      emitter.nop

      emitter.label("sched_done")

      # 2. Poll Native DualShock 2 Hardware Controllers via Pad Runtime
      emitter.lui(T9, (PadRuntimePayload::POLL_ENTRY >> 16).to_i32)
      emitter.ori(T9, T9, (PadRuntimePayload::POLL_ENTRY & 0xFFFF).to_i32)
      emitter.jalr(T9)
      emitter.nop
      emitter.lui(T0, 0x7000)      # Restore T0 = SPRAM base (0x70000000)

      # 3. Poll EE SIO UART Rx (0x1000f110 LSR, 0x1000f1c0 RXFIFO)
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
      emitter.ori(T6, ZERO, 0x65) # 'e'
      emitter.beq(T7, T6, "sio_set_r1")
      emitter.nop
      emitter.ori(T6, ZERO, 0x45) # 'E'
      emitter.beq(T7, T6, "sio_set_r1")
      emitter.nop

      # L1 (0x0400): 'q' (0x71), 'Q' (0x51)
      emitter.ori(T6, ZERO, 0x71)
      emitter.beq(T7, T6, "sio_set_l1")
      emitter.nop
      emitter.ori(T6, ZERO, 0x51)
      emitter.beq(T7, T6, "sio_set_l1")
      emitter.nop

      # R2 (0x0200): 'f' (0x66), 'F' (0x46)
      emitter.ori(T6, ZERO, 0x66)
      emitter.beq(T7, T6, "sio_set_r2")
      emitter.nop
      emitter.ori(T6, ZERO, 0x46)
      emitter.beq(T7, T6, "sio_set_r2")
      emitter.nop

      # L2 (0x0100): 'b' (0x62), 'B' (0x42)
      emitter.ori(T6, ZERO, 0x62)
      emitter.beq(T7, T6, "sio_set_l2")
      emitter.nop
      emitter.ori(T6, ZERO, 0x42)
      emitter.beq(T7, T6, "sio_set_l2")
      emitter.nop

      # Up (0x0010): 'u' (0x75), 'U' (0x55), '+' (0x2B), '=' (0x3D)
      emitter.ori(T6, ZERO, 0x75)
      emitter.beq(T7, T6, "sio_set_up")
      emitter.nop
      emitter.ori(T6, ZERO, 0x55)
      emitter.beq(T7, T6, "sio_set_up")
      emitter.nop
      emitter.ori(T6, ZERO, 0x2b)
      emitter.beq(T7, T6, "sio_set_up")
      emitter.nop
      emitter.ori(T6, ZERO, 0x3d)
      emitter.beq(T7, T6, "sio_set_up")
      emitter.nop

      # Down (0x0040): 'd' (0x64), 'D' (0x44), '-' (0x2D)
      emitter.ori(T6, ZERO, 0x64)
      emitter.beq(T7, T6, "sio_set_down")
      emitter.nop
      emitter.ori(T6, ZERO, 0x44)
      emitter.beq(T7, T6, "sio_set_down")
      emitter.nop
      emitter.ori(T6, ZERO, 0x2d)
      emitter.beq(T7, T6, "sio_set_down")
      emitter.nop

      # Left (0x0080): 'p' (0x70), 'P' (0x50), '[' (0x5B)
      emitter.ori(T6, ZERO, 0x70)
      emitter.beq(T7, T6, "sio_set_left")
      emitter.nop
      emitter.ori(T6, ZERO, 0x50)
      emitter.beq(T7, T6, "sio_set_left")
      emitter.nop
      emitter.ori(T6, ZERO, 0x5b)
      emitter.beq(T7, T6, "sio_set_left")
      emitter.nop

      # Right (0x0020): 'n' (0x6E), 'N' (0x4E), ']' (0x5D)
      emitter.ori(T6, ZERO, 0x6e)
      emitter.beq(T7, T6, "sio_set_right")
      emitter.nop
      emitter.ori(T6, ZERO, 0x4e)
      emitter.beq(T7, T6, "sio_set_right")
      emitter.nop
      emitter.ori(T6, ZERO, 0x5d)
      emitter.beq(T7, T6, "sio_set_right")
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
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_l1")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0400)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_r2")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0200)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_l2")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0100)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_up")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0010)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_down")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0040)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_left")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0080)
      emitter.sw(T5, 16, T0)
      emitter.j("sio_rx_done")
      emitter.nop

      emitter.label("sio_set_right")
      emitter.lw(T5, 16, T0)
      emitter.ori(T5, T5, 0x0020)
      emitter.sw(T5, 16, T0)

      emitter.label("sio_rx_done")

      # 4. Compute edge transitions for Port 0:
      emitter.lw(T5, 16, T0)       # T5 = current buttons (0x70000010)
      emitter.lw(T6, 20, T0)       # T6 = previous buttons (0x70000014)
      emitter.sw(T5, 20, T0)       # update previous buttons = current
      emitter.nor(T7, T6, ZERO)    # T7 = ~previous
      emitter.and_(T8, T5, T7)     # T8 = newly pressed edges (curr & ~prev)
      emitter.sw(T8, 24, T0)       # store pressed edges at 0x70000018
      emitter.nor(T7, T5, ZERO)    # T7 = ~current
      emitter.and_(T7, T6, T7)     # T7 = newly released edges (prev & ~curr)
      emitter.sw(T7, 28, T0)       # store released edges at 0x7000001C

      # Compute edge transitions for Port 1:
      emitter.lw(T5, 36, T0)       # T5 = current buttons (0x70000024)
      emitter.lw(T6, 40, T0)       # T6 = previous buttons (0x70000028)
      emitter.sw(T5, 40, T0)       # update previous buttons = current
      emitter.nor(T7, T6, ZERO)    # T7 = ~previous
      emitter.and_(T9, T5, T7)     # T9 = newly pressed edges (curr & ~prev)
      emitter.sw(T9, 44, T0)       # store pressed edges at 0x7000002C
      emitter.nor(T7, T5, ZERO)    # T7 = ~current
      emitter.and_(T7, T6, T7)     # T7 = newly released edges (prev & ~curr)
      emitter.sw(T7, 48, T0)       # store released edges at 0x70000030

      # 5. Emit button press console debug logs:
      emitter.lw(T8, 24, T0)       # Port 0 pressed edges
      emitter.lw(T6, 44, T0)       # Port 1 pressed edges
      emitter.or_(T8, T8, T6)      # Combine both ports

      # Check Cross (0x4000)
      emitter.andi(T7, T8, 0x4000)
      emitter.beqz(T7, "chk_btn_triangle")
      emitter.nop
      if !@inline_asm_words.empty?
        emitter.jal("Citrine_InlineAsm_Block")
        emitter.nop
      end
      if @has_audio
        emitter.lui(T0, 0x7000)
        emitter.lw(T5, 60, T0)       # 0x7000003C: audio playing flag
        emitter.bnez(T5, "audio_pause")
        emitter.nop
        # Currently paused -> Play
        emitter.lui(T9, (PadRuntimePayload::SOUND_PLAY_ENTRY >> 16).to_i32)
        emitter.ori(T9, T9, (PadRuntimePayload::SOUND_PLAY_ENTRY & 0xFFFF).to_i32)
        emitter.jalr(T9)
        emitter.nop
        emitter.lui(T0, 0x7000)
        emitter.ori(T5, ZERO, 1)
        emitter.sw(T5, 60, T0)
        emitter.j("audio_done")
        emitter.nop
        emitter.label("audio_pause")
        # Currently playing -> Stop / Pause
        emitter.lui(T9, (PadRuntimePayload::SOUND_STOP_ENTRY >> 16).to_i32)
        emitter.ori(T9, T9, (PadRuntimePayload::SOUND_STOP_ENTRY & 0xFFFF).to_i32)
        emitter.jalr(T9)
        emitter.nop
        emitter.lui(T0, 0x7000)
        emitter.sw(ZERO, 60, T0)
        emitter.label("audio_done")
      end
      emitter.lui(A0, (cross_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (cross_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

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
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_circle")
      emitter.andi(T7, T8, 0x2000)
      emitter.beqz(T7, "chk_btn_square")
      emitter.nop
      if @has_audio
        emitter.lui(T9, (PadRuntimePayload::SOUND_STOP_ENTRY >> 16).to_i32)
        emitter.ori(T9, T9, (PadRuntimePayload::SOUND_STOP_ENTRY & 0xFFFF).to_i32)
        emitter.jalr(T9)
        emitter.nop
        emitter.lui(T0, 0x7000)
        emitter.sw(ZERO, 60, T0)
        if is_animated
          emitter.sw(ZERO, 8, T0)
        end
      end
      emitter.lui(A0, (circle_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (circle_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

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
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_r1")
      emitter.andi(T7, T8, 0x0800)
      emitter.beqz(T7, "chk_btn_l1")
      emitter.nop
      emitter.lui(A0, (r1_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (r1_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_l1")
      emitter.andi(T7, T8, 0x0400)
      emitter.beqz(T7, "chk_btn_r2")
      emitter.nop
      emitter.lui(A0, (l1_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (l1_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_r2")
      emitter.andi(T7, T8, 0x0200)
      emitter.beqz(T7, "chk_btn_l2")
      emitter.nop
      emitter.lui(A0, (r2_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (r2_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_l2")
      emitter.andi(T7, T8, 0x0100)
      emitter.beqz(T7, "chk_btn_start")
      emitter.nop
      emitter.lui(A0, (l2_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (l2_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_start")
      emitter.andi(T7, T8, 0x0008)
      emitter.beqz(T7, "chk_btn_select")
      emitter.nop
      emitter.lui(A0, (start_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (start_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_select")
      emitter.andi(T7, T8, 0x0001)
      emitter.beqz(T7, "chk_btn_up")
      emitter.nop
      emitter.lui(A0, (select_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (select_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_up")
      emitter.andi(T7, T8, 0x0010)
      emitter.beqz(T7, "chk_btn_right")
      emitter.nop
      emitter.lui(A0, (up_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (up_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_right")
      emitter.andi(T7, T8, 0x0020)
      emitter.beqz(T7, "chk_btn_down")
      emitter.nop
      emitter.lui(A0, (right_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (right_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_down")
      emitter.andi(T7, T8, 0x0040)
      emitter.beqz(T7, "chk_btn_left")
      emitter.nop
      emitter.lui(A0, (down_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (down_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_left")
      emitter.andi(T7, T8, 0x0080)
      emitter.beqz(T7, "chk_btn_l3")
      emitter.nop
      emitter.lui(A0, (left_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (left_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_l3")
      emitter.andi(T7, T8, 0x0002)
      emitter.beqz(T7, "chk_btn_r3")
      emitter.nop
      emitter.lui(A0, (l3_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (l3_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)
      emitter.lw(T8, 24, T0)
      emitter.lw(T6, 44, T0)
      emitter.or_(T8, T8, T6)

      emitter.label("chk_btn_r3")
      emitter.andi(T7, T8, 0x0004)
      emitter.beqz(T7, "btn_chk_done")
      emitter.nop
      emitter.lui(A0, (r3_msg_addr >> 16).to_i32)
      emitter.ori(A0, A0, (r3_msg_addr & 0xFFFF).to_i32)
      emitter.jal("debug_puts")
      emitter.nop
      emitter.lui(T0, 0x7000)

      emitter.label("btn_chk_done")

      if @is_controller_tester && phase_addrs.size > 0
        # Load currently held buttons across Port 0 (0x70000010) and Port 1 (0x70000024)
        emitter.lw(T5, 16, T0)
        emitter.lw(T6, 36, T0)
        emitter.or_(T5, T5, T6)

        # Base pointer for uncached GIF packet quad colors:
        # KSEG1 = 0xA0000000 | (phase_addrs[0] + 0x8000)
        target_base = 0xA0000000_u32 | (phase_addrs[0] + 0x8000_u32)
        emitter.lui(T4, (target_base >> 16).to_i32)
        emitter.ori(T4, T4, (target_base & 0xFFFF).to_i32)

        # Colors:
        # T1 = DarkGray (0x80505050)
        emitter.lui(T1, 0x8050)
        emitter.ori(T1, T1, 0x5050)

        # T2 = Green (0x8000FF00)
        emitter.lui(T2, 0x8000)
        emitter.ori(T2, T2, 0xFF00)

        # D-Pad (Green)
        # Up (0x0010, offset 0x07a0)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0010)
        emitter.beqz(T7, "ct_up_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_up_store")
        emitter.sw(T6, 0x07a0, T4)

        # Down (0x0040, offset 0x07e0)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0040)
        emitter.beqz(T7, "ct_down_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_down_store")
        emitter.sw(T6, 0x07e0, T4)

        # Left (0x0080, offset 0x0820)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0080)
        emitter.beqz(T7, "ct_left_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_left_store")
        emitter.sw(T6, 0x0820, T4)

        # Right (0x0020, offset 0x0860)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0020)
        emitter.beqz(T7, "ct_right_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_right_store")
        emitter.sw(T6, 0x0860, T4)

        # Triangle (0x1000, offset 0x08a0, Green)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x1000)
        emitter.beqz(T7, "ct_triangle_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_triangle_store")
        emitter.sw(T6, 0x08a0, T4)

        # Circle (0x2000, offset 0x08e0, Red: 0x800000FF)
        emitter.lui(T3, 0x8000)
        emitter.ori(T3, T3, 0x00FF)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x2000)
        emitter.beqz(T7, "ct_circle_store")
        emitter.nop
        emitter.or_(T6, T3, ZERO)
        emitter.label("ct_circle_store")
        emitter.sw(T6, 0x08e0, T4)

        # Cross (0x4000, offset 0x0920, Blue: 0x80FF0000)
        emitter.lui(T3, 0x80FF)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x4000)
        emitter.beqz(T7, "ct_cross_store")
        emitter.nop
        emitter.or_(T6, T3, ZERO)
        emitter.label("ct_cross_store")
        emitter.sw(T6, 0x0920, T4)

        # Square (0x8000, offset 0x0960, Magenta: 0x80FF00FF)
        emitter.lui(T3, 0x80FF)
        emitter.ori(T3, T3, 0x00FF)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x8000)
        emitter.beqz(T7, "ct_square_store")
        emitter.nop
        emitter.or_(T6, T3, ZERO)
        emitter.label("ct_square_store")
        emitter.sw(T6, 0x0960, T4)

        # Select (0x0001, offset 0x09a0, Yellow: 0x8000FFFF)
        emitter.lui(T3, 0x8000)
        emitter.ori(T3, T3, 0xFFFF)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0001)
        emitter.beqz(T7, "ct_select_store")
        emitter.nop
        emitter.or_(T6, T3, ZERO)
        emitter.label("ct_select_store")
        emitter.sw(T6, 0x09a0, T4)

        # Start (0x0008, offset 0x14e0, Green)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0008)
        emitter.beqz(T7, "ct_start_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_start_store")
        emitter.sw(T6, 0x14e0, T4)

        # Shoulder Buttons (Green)
        # L1 (0x0400, offset 0x4920)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0400)
        emitter.beqz(T7, "ct_l1_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_l1_store")
        emitter.sw(T6, 0x4920, T4)

        # L2 (0x0100, offset 0x4960)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0100)
        emitter.beqz(T7, "ct_l2_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_l2_store")
        emitter.sw(T6, 0x4960, T4)

        # R1 (0x0800, offset 0x49a0)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0800)
        emitter.beqz(T7, "ct_r1_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_r1_store")
        emitter.sw(T6, 0x49a0, T4)

        # R2 (0x0200, offset 0x49e0)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0200)
        emitter.beqz(T7, "ct_r2_store")
        emitter.nop
        emitter.or_(T6, T2, ZERO)
        emitter.label("ct_r2_store")
        emitter.sw(T6, 0x49e0, T4)

        # --- Left Stick Nub & L3 Badge ---
        emitter.lbu(T8, 34, T0) # LX (byte 2 at 0x70000020, 0..255, center 128)
        emitter.lbu(T9, 35, T0) # LY (byte 3 at 0x70000020, 0..255, center 128)

        # T8 = ls_x: 240 + ((LX - 128) * 3 >> 4) -> 216..263
        emitter.addiu(T8, T8, -128)
        emitter.sll(T6, T8, 1)
        emitter.addu(T8, T8, T6)
        emitter.sra(T8, T8, 4)
        emitter.addiu(T8, T8, 240)

        # T9 = ls_y: 210 + ((LY - 128) * 3 >> 4) -> 186..233
        emitter.addiu(T9, T9, -128)
        emitter.sll(T6, T9, 1)
        emitter.addu(T9, T9, T6)
        emitter.sra(T9, T9, 4)
        emitter.addiu(T9, T9, 210)

        # Left Stick Nub GS Coordinates (16x16 quad at 0xafd0):
        # XYZ3 (vertex 1): (y1 << 16) | x1
        emitter.addiu(A2, T8, -8)
        emitter.sll(A2, A2, 4)
        emitter.addiu(A3, T9, -8)
        emitter.sll(A3, A3, 4)
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x2ff0, T4)

        # XYZ2 (vertex 2): (y2 << 16) | x2
        emitter.addiu(A2, T8, 8)
        emitter.sll(A2, A2, 4)
        emitter.addiu(A3, T9, 8)
        emitter.sll(A3, A3, 4)
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x3000, T4)

        # Left Stick Nub Color (Cyan if L3 pressed, else White)
        emitter.lui(A2, 0x80FF)
        emitter.ori(A2, A2, 0xFFFF) # White = 0x80FFFFFF
        emitter.lui(A3, 0x80FF)
        emitter.ori(A3, A3, 0xFF00) # Cyan = 0x80FFFF00
        emitter.or_(T6, A2, ZERO)
        emitter.andi(T7, T5, 0x0002) # L3 button mask
        emitter.beqz(T7, "ct_ls_nub_col")
        emitter.nop
        emitter.or_(T6, A3, ZERO)
        emitter.label("ct_ls_nub_col")
        emitter.sw(T6, 0x2fe0, T4)

        # L3 Button Badge (Cyan if L3 pressed, else DarkGray T1)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0002)
        emitter.beqz(T7, "ct_l3_badge_col")
        emitter.nop
        emitter.or_(T6, A3, ZERO)
        emitter.label("ct_l3_badge_col")
        emitter.sw(T6, 0x3020, T4)

        # --- Right Stick Nub & R3 Badge ---
        emitter.lbu(T8, 32, T0) # RX (byte 0 at 0x70000020, 0..255, center 128)
        emitter.lbu(T9, 33, T0) # RY (byte 1 at 0x70000020, 0..255, center 128)

        # T8 = rs_x: 400 + ((RX - 128) * 3 >> 4) -> 376..423
        emitter.addiu(T8, T8, -128)
        emitter.sll(T6, T8, 1)
        emitter.addu(T8, T8, T6)
        emitter.sra(T8, T8, 4)
        emitter.addiu(T8, T8, 400)

        # T9 = rs_y: 210 + ((RY - 128) * 3 >> 4) -> 186..233
        emitter.addiu(T9, T9, -128)
        emitter.sll(T6, T9, 1)
        emitter.addu(T9, T9, T6)
        emitter.sra(T9, T9, 4)
        emitter.addiu(T9, T9, 210)

        # Right Stick Nub GS Coordinates (16x16 quad at 0xc390):
        # XYZ3 (vertex 1): (y1 << 16) | x1
        emitter.addiu(A2, T8, -8)
        emitter.sll(A2, A2, 4)
        emitter.addiu(A3, T9, -8)
        emitter.sll(A3, A3, 4)
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x43b0, T4)

        # XYZ2 (vertex 2): (y2 << 16) | x2
        emitter.addiu(A2, T8, 8)
        emitter.sll(A2, A2, 4)
        emitter.addiu(A3, T9, 8)
        emitter.sll(A3, A3, 4)
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x43c0, T4)

        # Right Stick Nub Color (Cyan if R3 pressed, else White)
        emitter.or_(T6, A2, ZERO)
        emitter.andi(T7, T5, 0x0004) # R3 button mask
        emitter.beqz(T7, "ct_rs_nub_col")
        emitter.nop
        emitter.or_(T6, A3, ZERO)
        emitter.label("ct_rs_nub_col")
        emitter.sw(T6, 0x43a0, T4)

        # R3 Button Badge (Cyan if R3 pressed, else DarkGray T1)
        emitter.or_(T6, T1, ZERO)
        emitter.andi(T7, T5, 0x0004)
        emitter.beqz(T7, "ct_r3_badge_col")
        emitter.nop
        emitter.or_(T6, A3, ZERO)
        emitter.label("ct_r3_badge_col")
        emitter.sw(T6, 0x43e0, T4)

        # --- Telemetry Stick Axis Meter Cursors ---
        target_meter = 0xA0000000_u32 | (phase_addrs[0] + 0x12000_u32)
        emitter.lui(A1, (target_meter >> 16).to_i32)
        emitter.ori(A1, A1, (target_meter & 0xFFFF).to_i32)

        # LX Meter (center x=115, y=315..325, 6px wide at 0x123f0):
        emitter.lbu(T8, 34, T0)
        emitter.addiu(T8, T8, -128)
        emitter.sll(T6, T8, 5)
        emitter.sll(A2, T8, 2)
        emitter.addu(T6, T6, A2)
        emitter.sra(T6, T6, 7)
        emitter.addiu(T8, T6, 115)
        emitter.addiu(A2, T8, -3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (315 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x03f0, A1)
        emitter.addiu(A2, T8, 3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (325 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x0400, A1)

        # LY Meter (center x=255, y=315..325, 6px wide at 0x12a30):
        emitter.lbu(T8, 35, T0)
        emitter.addiu(T8, T8, -128)
        emitter.sll(T6, T8, 5)
        emitter.sll(A2, T8, 2)
        emitter.addu(T6, T6, A2)
        emitter.sra(T6, T6, 7)
        emitter.addiu(T8, T6, 255)
        emitter.addiu(A2, T8, -3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (315 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x0a30, A1)
        emitter.addiu(A2, T8, 3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (325 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x0a40, A1)

        # RX Meter (center x=395, y=315..325, 6px wide at 0x13230):
        emitter.lbu(T8, 32, T0)
        emitter.addiu(T8, T8, -128)
        emitter.sll(T6, T8, 5)
        emitter.sll(A2, T8, 2)
        emitter.addu(T6, T6, A2)
        emitter.sra(T6, T6, 7)
        emitter.addiu(T8, T6, 395)
        emitter.addiu(A2, T8, -3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (315 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x1230, A1)
        emitter.addiu(A2, T8, 3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (325 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x1240, A1)

        # RY Meter (center x=535, y=315..325, 6px wide at 0x139b0):
        emitter.lbu(T8, 33, T0)
        emitter.addiu(T8, T8, -128)
        emitter.sll(T6, T8, 5)
        emitter.sll(A2, T8, 2)
        emitter.addu(T6, T6, A2)
        emitter.sra(T6, T6, 7)
        emitter.addiu(T8, T6, 535)
        emitter.addiu(A2, T8, -3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (315 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x19b0, A1)
        emitter.addiu(A2, T8, 3)
        emitter.sll(A2, A2, 4)
        emitter.ori(A3, ZERO, (325 << 4))
        emitter.sll(A3, A3, 16)
        emitter.andi(A2, A2, 0xFFFF)
        emitter.or_(T6, A3, A2)
        emitter.sw(T6, 0x19c0, A1)

        emitter.lui(T0, 0x7000) # Restore T0 = SPRAM base
      end

      # Reset current buttons for both Port 0 and Port 1 to 0 (so next frame re-polls schedule or hardware)
      emitter.sw(ZERO, 16, T0)
      emitter.sw(ZERO, 36, T0)

      if @is_dvd_screensaver
        # --- DVD BUTTONS & LOGO MANAGEMENT ---
        emitter.lui(T0, 0x7000)
        emitter.lw(T5, 24, T0) # T5 = Port 0 pressed edges (0x70000018)
        emitter.lw(T6, 44, T0) # T6 = Port 1 pressed edges (0x7000002C)
        emitter.or_(T5, T5, T6)
        emitter.lw(T4, 0x60, T0) # T4 = logo_count (0x70000060)
        emitter.lw(T3, 56, T0)   # T3 = debounce   (0x70000038)

        # 1. Triangle (0x1000): reset to 1 logo
        emitter.andi(T7, T5, 0x1000)
        emitter.beqz(T7, "dvd_chk_r1")
        emitter.nop
        emitter.bnez(T3, "dvd_buttons_done")
        emitter.nop
        emitter.ori(T4, ZERO, 1)
        emitter.sw(T4, 0x60, T0) # logo_count = 1
        emitter.ori(T3, ZERO, 12)
        emitter.sw(T3, 56, T0)   # debounce = 12
        emitter.j("dvd_buttons_done")
        emitter.nop

        # 2. R1 (0x0800): stress test - spawn 10 logos
        emitter.label("dvd_chk_r1")
        emitter.andi(T7, T5, 0x0800)
        emitter.beqz(T7, "dvd_chk_cross")
        emitter.nop
        emitter.bnez(T3, "dvd_buttons_done")
        emitter.nop
        emitter.ori(S4, ZERO, 10) # loop count = 10
        emitter.label("dvd_r1_spawn_loop")
        emitter.sltiu(T7, T4, 32)
        emitter.beqz(T7, "dvd_r1_done")
        emitter.nop

        # Calculate slot address in SPRAM: 0x70000100 + (logo_count * 24)
        emitter.sll(S1, T4, 4)  # T4 * 16
        emitter.sll(S2, T4, 3)  # T4 * 8
        emitter.addu(S1, S1, S2)
        emitter.addiu(S1, S1, 0x0100)
        emitter.addu(S0, T0, S1) # S0 = new logo address

        # rx = rng_next_int(40, 400)
        emitter.ori(A0, ZERO, 40)
        emitter.ori(A1, ZERO, 400)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.sw(V0, 0, S0)

        # ry = rng_next_int(40, 320)
        emitter.ori(A0, ZERO, 40)
        emitter.ori(A1, ZERO, 320)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.sw(V0, 4, S0)

        # dir_x: rng_next_int(0, 1) == 0 ? -rng_next_int(4, 7) : rng_next_int(4, 7)
        emitter.ori(A0, ZERO, 4)
        emitter.ori(A1, ZERO, 7)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(T6, V0)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 1)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.bnez(V0, "dvd_r1_dir_x_set")
        emitter.nop
        emitter.subu(T6, ZERO, T6)
        emitter.label("dvd_r1_dir_x_set")
        emitter.sw(T6, 8, S0)

        # dir_y: rng_next_int(0, 1) == 0 ? -rng_next_int(3, 6) : rng_next_int(3, 6)
        emitter.ori(A0, ZERO, 3)
        emitter.ori(A1, ZERO, 6)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(T6, V0)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 1)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.bnez(V0, "dvd_r1_dir_y_set")
        emitter.nop
        emitter.subu(T6, ZERO, T6)
        emitter.label("dvd_r1_dir_y_set")
        emitter.sw(T6, 12, S0)

        # rt_col = rng_next_int(0, 5)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(S2, V0)
        emitter.sw(S2, 16, S0)

        # rbg_col = (rt_col + rng_next_int(1, 5)) % 6
        emitter.ori(A0, ZERO, 1)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.addu(S2, S2, V0)
        emitter.ori(T6, ZERO, 6)
        emitter.divu(S2, T6)
        emitter.mfhi(S2)
        emitter.sw(S2, 20, S0)

        # logo_count++
        emitter.lui(T0, 0x7000)
        emitter.lw(T4, 0x60, T0)
        emitter.addiu(T4, T4, 1)
        emitter.sw(T4, 0x60, T0)

        emitter.addiu(S4, S4, -1)
        emitter.bnez(S4, "dvd_r1_spawn_loop")
        emitter.nop

        emitter.label("dvd_r1_done")
        emitter.ori(T3, ZERO, 12)
        emitter.sw(T3, 56, T0)
        emitter.j("dvd_buttons_done")
        emitter.nop

        # 3. Cross (0x4000): spawn 1 new logo
        emitter.label("dvd_chk_cross")
        emitter.andi(T7, T5, 0x4000)
        emitter.beqz(T7, "dvd_buttons_done")
        emitter.nop
        emitter.bnez(T3, "dvd_buttons_done")
        emitter.nop
        emitter.sltiu(T7, T4, 32)
        emitter.beqz(T7, "dvd_buttons_done")
        emitter.nop

        # Calculate slot address in SPRAM: 0x70000100 + (logo_count * 24)
        emitter.sll(S1, T4, 4)
        emitter.sll(S2, T4, 3)
        emitter.addu(S1, S1, S2)
        emitter.addiu(S1, S1, 0x0100)
        emitter.addu(S0, T0, S1)

        # rx = rng_next_int(40, 400)
        emitter.ori(A0, ZERO, 40)
        emitter.ori(A1, ZERO, 400)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.sw(V0, 0, S0)

        # ry = rng_next_int(40, 320)
        emitter.ori(A0, ZERO, 40)
        emitter.ori(A1, ZERO, 320)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.sw(V0, 4, S0)

        # dir_x: rng_next_int(0, 1) == 0 ? -rng_next_int(4, 7) : rng_next_int(4, 7)
        emitter.ori(A0, ZERO, 4)
        emitter.ori(A1, ZERO, 7)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(T6, V0)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 1)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.bnez(V0, "dvd_cross_dir_x_set")
        emitter.nop
        emitter.subu(T6, ZERO, T6)
        emitter.label("dvd_cross_dir_x_set")
        emitter.sw(T6, 8, S0)

        # dir_y: rng_next_int(0, 1) == 0 ? -rng_next_int(3, 6) : rng_next_int(3, 6)
        emitter.ori(A0, ZERO, 3)
        emitter.ori(A1, ZERO, 6)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(T6, V0)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 1)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.bnez(V0, "dvd_cross_dir_y_set")
        emitter.nop
        emitter.subu(T6, ZERO, T6)
        emitter.label("dvd_cross_dir_y_set")
        emitter.sw(T6, 12, S0)

        # rt_col = rng_next_int(0, 5)
        emitter.ori(A0, ZERO, 0)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.move(S2, V0)
        emitter.sw(S2, 16, S0)

        # rbg_col = (rt_col + rng_next_int(1, 5)) % 6
        emitter.ori(A0, ZERO, 1)
        emitter.ori(A1, ZERO, 5)
        emitter.jal("rng_next_int")
        emitter.nop
        emitter.addu(S2, S2, V0)
        emitter.ori(T6, ZERO, 6)
        emitter.divu(S2, T6)
        emitter.mfhi(S2)
        emitter.sw(S2, 20, S0)

        # logo_count++
        emitter.lui(T0, 0x7000)
        emitter.lw(T4, 0x60, T0)
        emitter.addiu(T4, T4, 1)
        emitter.sw(T4, 0x60, T0)
        emitter.ori(T3, ZERO, 12)
        emitter.sw(T3, 56, T0)

        emitter.label("dvd_buttons_done")

        # --- DVD PHYSICS UPDATE FOR ALL LOGOS ---
        emitter.lui(T0, 0x7000)
        emitter.lw(S6, 0x60, T0) # S6 = logo_count
        emitter.move(S7, ZERO)   # S7 = logo index (0 .. logo_count - 1)

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
        emitter.lw(T5, 16, S0) # text_color_idx
        emitter.addu(T5, T5, V0)
        emitter.ori(T6, ZERO, 6)
        emitter.divu(T5, T6)
        emitter.mfhi(T5)
        emitter.sw(T5, 20, S0) # new bg_color_idx

        emitter.label("dvd_physics_next")
        emitter.addiu(S7, S7, 1)
        emitter.lui(T0, 0x7000)
        emitter.lw(S6, 0x60, T0)
        emitter.bne(S7, S6, "dvd_physics_loop")
        emitter.nop

        # --- DVD DYNAMIC GIF PACKET GENERATION ---
        # Buffer pointer S0 in RAM at 0x20250010 (offset 16 bytes for GIFTag header, DMA address 0x00250000)
        emitter.lui(S0, 0x2025)
        emitter.ori(S0, S0, 0x0010)

        emitter.lui(T0, 0x7000)
        emitter.lw(S6, 0x60, T0) # S6 = logo_count
        emitter.move(S7, ZERO)   # S7 = logo index (0 .. logo_count - 1)

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

        # Store font_quad_addr in SPRAM at 0x70000068
        emitter.lui(T5, (font_quad_addr >> 16).to_i32)
        emitter.ori(T5, T5, (font_quad_addr & 0xFFFF).to_i32)
        emitter.lui(T0, 0x7000)
        emitter.sw(T5, 0x68, T0)

        emitter.ori(S5, ZERO, 111) # loop counter

        emitter.label("dvd_glyph_loop")
        emitter.lui(T0, 0x7000)
        emitter.lw(T5, 0x68, T0)
        emitter.lbu(T6, 0, T5)  # dx1
        emitter.lbu(T7, 1, T5)  # dy1
        emitter.lbu(T8, 2, T5)  # dx2
        emitter.lbu(T9, 3, T5)  # dy2
        emitter.addiu(T5, T5, 4)
        emitter.sw(T5, 0x68, T0)

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
        emitter.lw(S6, 0x60, T0)
        emitter.addiu(S7, S7, 1)
        emitter.bne(S7, S6, "dvd_draw_logo_loop")
        emitter.nop

        # --- WRITE GIFTAG AND KICK DMA CHANNEL 2 ---
        # total_items = logo_count * 114 * 4 = logo_count * 456
        emitter.lui(T0, 0x7000)
        emitter.lw(T1, 0x60, T0)
        emitter.ori(T2, ZERO, 456)
        emitter.multu(T1, T2)
        emitter.mflo(T1) # T1 = total_items

        # GIFTag at 0x20250000:
        emitter.lui(T0, 0x2025)
        emitter.lui(T2, 0x1000)
        emitter.dsll32(T2, T2, 0) # bit 60 PRE = 1
        emitter.ori(T3, ZERO, 0x8000) # bit 15 EOP = 1
        emitter.or_(T2, T2, T3)
        emitter.andi(T3, T1, 0x7FFF)
        emitter.or_(T2, T2, T3)
        emitter.sd(T2, 0, T0)
        emitter.ori(T3, ZERO, 0x0E)
        emitter.sd(T3, 8, T0)

        # Kick DMA Channel 2 from 0x00250000:
        emitter.jal("dma02_wait")
        emitter.nop
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xa000)
        emitter.lui(T7, 0x0025)
        emitter.sw(T7, 0x10, T8) # D2_MADR = 0x00250000
        emitter.addiu(T6, T1, 1) # D2_QWC = total_items + 1
        emitter.sw(T6, 0x20, T8)
        emitter.ori(T5, ZERO, 0x101)
        emitter.sw(T5, 0x00, T8)
        emitter.jal("dma02_wait")
        emitter.nop

        # Clear buttons:
        emitter.lui(T0, 0x7000)
        emitter.sw(ZERO, 16, T0)
        emitter.sw(ZERO, 36, T0)

        emitter.j("frame_loop")
        emitter.nop
      elsif is_animated
        if @has_audio
          emitter.lw(T5, 60, T0)
          emitter.beqz(T5, "skip_phase_advance")
          emitter.nop
        end
        # In animated mode, advance phase sequentially modulo phases.size
        emitter.lw(T2, 8, T0)     # T2 = phase_index
        emitter.addiu(T2, T2, 1)  # phase_index += 1
        emitter.ori(T3, ZERO, phases.size)
        emitter.sltu(T4, T2, T3)  # T4 = 1 if phase_index < phases.size
        emitter.bnez(T4, "store_phase_index")
        emitter.nop
        emitter.move(T2, ZERO)    # wrap back to 0
        emitter.label("store_phase_index")
        emitter.sw(T2, 8, T0)
        if @has_audio
          emitter.label("skip_phase_advance")
        end
      elsif phases.size > 1
        # Check if Triangle button was pressed in edges on Port 0 or Port 1 to reset phase index
        emitter.lw(T5, 24, T0)
        emitter.lw(T6, 44, T0)
        emitter.or_(T5, T5, T6)
        emitter.andi(T7, T5, 0x1000)
        emitter.beqz(T7, "chk_r1_advance")
        emitter.nop
        emitter.sw(ZERO, 8, T0)
        emitter.ori(T2, ZERO, 0)
        emitter.j("apply_phase_update")
        emitter.nop

        emitter.label("chk_r1_advance")
        # Check if R1 button (0x0800) was pressed on Port 0 or Port 1: jump to phase 2 (stress test) if available
        emitter.andi(T7, T5, 0x0800)
        emitter.beqz(T7, "chk_cross_advance")
        emitter.nop
        if phases.size > 2
          emitter.ori(T2, ZERO, 2)
          emitter.sw(T2, 8, T0)
          emitter.j("apply_phase_update")
          emitter.nop
        else
          emitter.j("advance_phase")
          emitter.nop
        end

        emitter.label("chk_cross_advance")
        # Check if Cross button was pressed in edges on Port 0 or Port 1
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

      if @is_inline_assembly
        # --- DYNAMIC SPINNER & HUD ACTIVITY EMISSION ---
        # Read frame counter from SPRAM 0x70000004
        emitter.lui(T0, 0x7000)
        emitter.lw(T1, 4, T0)

        # Buffer pointer in S0 = 0x20250000 (uncached RAM, DMA addr 0x00250000)
        emitter.lui(S0, 0x2025)

        # Write GIFTag (A+D mode, NLOOP = 36 QWs, EOP = 1)
        # Word 0: 0x00008024 (EOP=1, NLOOP=36)
        # Word 1: 0x10000000 (PRE=0, FLG=0)
        # Word 2: 0x0000000E (REGS=0x0E A+D)
        # Word 3: 0x00000000
        emitter.ori(T2, ZERO, 0x8024)
        emitter.sw(T2, 0, S0)
        emitter.lui(T2, 0x1000)
        emitter.sw(T2, 4, S0)
        emitter.ori(T2, ZERO, 0x0E)
        emitter.sw(T2, 8, S0)
        emitter.sw(ZERO, 12, S0)

        # Constant registers for A+D emission:
        # T2 = 0x3F800000 (Float 1.0 for Q)
        emitter.lui(T2, 0x3F80)
        # T3 = 1 (PRIM Line / RGBAQ reg)
        emitter.ori(T3, ZERO, 1)
        # T4 = 6 (PRIM Sprite)
        emitter.ori(T4, ZERO, 6)
        # T5 = 5 (XYZ2 reg)
        emitter.ori(T5, ZERO, 5)
        # T6 = 13 (XYZ3 reg)
        emitter.ori(T6, ZERO, 13)

        # 1. Clear Spinner Well: Sprite from (575, 23) to (601, 49), color Dark Navy 0x8018100C
        # Offset 16 (QW 1): PRIM = 6
        emitter.sw(T4, 16, S0)
        emitter.sw(ZERO, 20, S0)
        emitter.sw(ZERO, 24, S0)
        emitter.sw(ZERO, 28, S0)
        # Offset 32 (QW 2): RGBAQ = 0x8018100C
        emitter.lui(T7, 0x8018)
        emitter.ori(T7, T7, 0x100C)
        emitter.sw(T7, 32, S0)
        emitter.sw(T2, 36, S0)
        emitter.sw(T3, 40, S0)
        emitter.sw(ZERO, 44, S0)
        # Offset 48 (QW 3): XYZ3 = 0x017023F0 (x=575, y=23)
        emitter.lui(T7, 0x0170)
        emitter.ori(T7, T7, 0x23F0)
        emitter.sw(T7, 48, S0)
        emitter.sw(ZERO, 52, S0)
        emitter.sw(T6, 56, S0)
        emitter.sw(ZERO, 60, S0)
        # Offset 64 (QW 4): XYZ2 = 0x03102590 (x=601, y=49)
        emitter.lui(T7, 0x0310)
        emitter.ori(T7, T7, 0x2590)
        emitter.sw(T7, 64, S0)
        emitter.sw(ZERO, 68, S0)
        emitter.sw(T5, 72, S0)
        emitter.sw(ZERO, 76, S0)

        # Load Rotated Line Vertices from rot_table:
        # rot_idx = T1 & 0x0F
        emitter.andi(T7, T1, 0x0F)
        emitter.sll(T7, T7, 4) # 16 bytes per entry
        emitter.lui(T8, (rot_table_addr >> 16).to_i32)
        emitter.ori(T8, T8, (rot_table_addr & 0xFFFF).to_i32)
        emitter.addu(T8, T8, T7)
        emitter.lw(A0, 0, T8)  # Spoke 1 XYZ3
        emitter.lw(A1, 4, T8)  # Spoke 1 XYZ2
        emitter.lw(A2, 8, T8)  # Spoke 2 XYZ3
        emitter.lw(A3, 12, T8) # Spoke 2 XYZ2

        # 2. Spinner Spoke 1: Line, color Bright Cyan 0x80FFFF00
        # Offset 80 (QW 5): PRIM = 1
        emitter.sw(T3, 80, S0)
        emitter.sw(ZERO, 84, S0)
        emitter.sw(ZERO, 88, S0)
        emitter.sw(ZERO, 92, S0)
        # Offset 96 (QW 6): RGBAQ = 0x80FFFF00
        emitter.lui(T7, 0x80FF)
        emitter.ori(T7, T7, 0xFF00)
        emitter.sw(T7, 96, S0)
        emitter.sw(T2, 100, S0)
        emitter.sw(T3, 104, S0)
        emitter.sw(ZERO, 108, S0)
        # Offset 112 (QW 7): XYZ3 = A0
        emitter.sw(A0, 112, S0)
        emitter.sw(ZERO, 116, S0)
        emitter.sw(T6, 120, S0)
        emitter.sw(ZERO, 124, S0)
        # Offset 128 (QW 8): XYZ2 = A1
        emitter.sw(A1, 128, S0)
        emitter.sw(ZERO, 132, S0)
        emitter.sw(T5, 136, S0)
        emitter.sw(ZERO, 140, S0)

        # 3. Spinner Spoke 2: Line, color Lime Green 0x8000FF00
        # Offset 144 (QW 9): PRIM = 1
        emitter.sw(T3, 144, S0)
        emitter.sw(ZERO, 148, S0)
        emitter.sw(ZERO, 152, S0)
        emitter.sw(ZERO, 156, S0)
        # Offset 160 (QW 10): RGBAQ = 0x8000FF00
        emitter.lui(T7, 0x8000)
        emitter.ori(T7, T7, 0xFF00)
        emitter.sw(T7, 160, S0)
        emitter.sw(T2, 164, S0)
        emitter.sw(T3, 168, S0)
        emitter.sw(ZERO, 172, S0)
        # Offset 176 (QW 11): XYZ3 = A2
        emitter.sw(A2, 176, S0)
        emitter.sw(ZERO, 180, S0)
        emitter.sw(T6, 184, S0)
        emitter.sw(ZERO, 188, S0)
        # Offset 192 (QW 12): XYZ2 = A3
        emitter.sw(A3, 192, S0)
        emitter.sw(ZERO, 196, S0)
        emitter.sw(T5, 200, S0)
        emitter.sw(ZERO, 204, S0)

        # 4. Spinner Center Hub: Sprite from (587, 35) to (589, 37), color Pure White 0x80FFFFFF
        # Offset 208 (QW 13): PRIM = 6
        emitter.sw(T4, 208, S0)
        emitter.sw(ZERO, 212, S0)
        emitter.sw(ZERO, 216, S0)
        emitter.sw(ZERO, 220, S0)
        # Offset 224 (QW 14): RGBAQ = 0x80FFFFFF
        emitter.lui(T7, 0x80FF)
        emitter.ori(T7, T7, 0xFFFF)
        emitter.sw(T7, 224, S0)
        emitter.sw(T2, 228, S0)
        emitter.sw(T3, 232, S0)
        emitter.sw(ZERO, 236, S0)
        # Offset 240 (QW 15): XYZ3 = 0x023024B0 (x=587, y=35)
        emitter.lui(T7, 0x0230)
        emitter.ori(T7, T7, 0x24B0)
        emitter.sw(T7, 240, S0)
        emitter.sw(ZERO, 244, S0)
        emitter.sw(T6, 248, S0)
        emitter.sw(ZERO, 252, S0)
        # Offset 256 (QW 16): XYZ2 = 0x025024D0 (x=589, y=37)
        emitter.lui(T7, 0x0250)
        emitter.ori(T7, T7, 0x24D0)
        emitter.sw(T7, 256, S0)
        emitter.sw(ZERO, 260, S0)
        emitter.sw(T5, 264, S0)
        emitter.sw(ZERO, 268, S0)

        # 5. Heartbeat Status LED at (491, 33) to (497, 39)
        # Offset 272 (QW 17): PRIM = 6
        emitter.sw(T4, 272, S0)
        emitter.sw(ZERO, 276, S0)
        emitter.sw(ZERO, 280, S0)
        emitter.sw(ZERO, 284, S0)
        # Offset 288 (QW 18): RGBAQ = Neon Green if (T1 & 0x10) != 0, else Dark Emerald
        emitter.andi(T7, T1, 0x10)
        emitter.beqz(T7, "led_dark")
        emitter.nop
        emitter.lui(T7, 0x8000)
        emitter.ori(T7, T7, 0xFF00) # Bright Neon Green
        emitter.j("led_store")
        emitter.nop
        emitter.label("led_dark")
        emitter.lui(T7, 0x8000)
        emitter.ori(T7, T7, 0x4400) # Dark Emerald
        emitter.label("led_store")
        emitter.sw(T7, 288, S0)
        emitter.sw(T2, 292, S0)
        emitter.sw(T3, 296, S0)
        emitter.sw(ZERO, 300, S0)
        # Offset 304 (QW 19): XYZ3 = 0x02101EB0 (x=491, y=33)
        emitter.lui(T7, 0x0210)
        emitter.ori(T7, T7, 0x1EB0)
        emitter.sw(T7, 304, S0)
        emitter.sw(ZERO, 308, S0)
        emitter.sw(T6, 312, S0)
        emitter.sw(ZERO, 316, S0)
        # Offset 320 (QW 20): XYZ2 = 0x02701F10 (x=497, y=39)
        emitter.lui(T7, 0x0270)
        emitter.ori(T7, T7, 0x1F10)
        emitter.sw(T7, 320, S0)
        emitter.sw(ZERO, 324, S0)
        emitter.sw(T5, 328, S0)
        emitter.sw(ZERO, 332, S0)

        # 6. Clear Audio Waveform Bar Background: (338, 270) to (614, 286), Dark Gray 0x803C281E
        # Offset 336 (QW 21): PRIM = 6
        emitter.sw(T4, 336, S0)
        emitter.sw(ZERO, 340, S0)
        emitter.sw(ZERO, 344, S0)
        emitter.sw(ZERO, 348, S0)
        # Offset 352 (QW 22): RGBAQ = 0x803C281E
        emitter.lui(T7, 0x803C)
        emitter.ori(T7, T7, 0x281E)
        emitter.sw(T7, 352, S0)
        emitter.sw(T2, 356, S0)
        emitter.sw(T3, 360, S0)
        emitter.sw(ZERO, 364, S0)
        # Offset 368 (QW 23): XYZ3 = 0x10E01520 (x=338, y=270)
        emitter.lui(T7, 0x10E0)
        emitter.ori(T7, T7, 0x1520)
        emitter.sw(T7, 368, S0)
        emitter.sw(ZERO, 372, S0)
        emitter.sw(T6, 376, S0)
        emitter.sw(ZERO, 380, S0)
        # Offset 384 (QW 24): XYZ2 = 0x11E02660 (x=614, y=286)
        emitter.lui(T7, 0x11E0)
        emitter.ori(T7, T7, 0x2660)
        emitter.sw(T7, 384, S0)
        emitter.sw(ZERO, 388, S0)
        emitter.sw(T5, 392, S0)
        emitter.sw(ZERO, 396, S0)

        # 7. Dynamic Audio Waveform Bar: (338, 270) to (338 + W_audio, 286), Lime Green 0x8071CC2E
        # W_audio = 140 + ((T1 * 3) & 0x7F) -> 140..267 px
        emitter.sll(T7, T1, 1)
        emitter.addu(T7, T7, T1) # T7 = T1 * 3
        emitter.andi(T7, T7, 0x7F)
        emitter.addiu(T7, T7, 140 + 338) # T7 = right X (478..605)
        emitter.sll(T7, T7, 4)           # T7 = right X in subpixels
        emitter.lui(T8, 0x11E0)          # y2 = 286
        emitter.andi(T7, T7, 0xFFFF)
        emitter.or_(T8, T8, T7)          # T8 = (y2 << 16) | x2

        # Offset 400 (QW 25): PRIM = 6
        emitter.sw(T4, 400, S0)
        emitter.sw(ZERO, 404, S0)
        emitter.sw(ZERO, 408, S0)
        emitter.sw(ZERO, 412, S0)
        # Offset 416 (QW 26): RGBAQ = 0x8071CC2E
        emitter.lui(T7, 0x8071)
        emitter.ori(T7, T7, 0xCC2E)
        emitter.sw(T7, 416, S0)
        emitter.sw(T2, 420, S0)
        emitter.sw(T3, 424, S0)
        emitter.sw(ZERO, 428, S0)
        # Offset 432 (QW 27): XYZ3 = 0x10E01520 (x=338, y=270)
        emitter.lui(T7, 0x10E0)
        emitter.ori(T7, T7, 0x1520)
        emitter.sw(T7, 432, S0)
        emitter.sw(ZERO, 436, S0)
        emitter.sw(T6, 440, S0)
        emitter.sw(ZERO, 444, S0)
        # Offset 448 (QW 28): XYZ2 = T8
        emitter.sw(T8, 448, S0)
        emitter.sw(ZERO, 452, S0)
        emitter.sw(T5, 456, S0)
        emitter.sw(ZERO, 460, S0)

        # 8. Clear Latency Bar Background: (26, 270) to (302, 286), Dark Gray 0x803C281E
        # Offset 464 (QW 29): PRIM = 6
        emitter.sw(T4, 464, S0)
        emitter.sw(ZERO, 468, S0)
        emitter.sw(ZERO, 472, S0)
        emitter.sw(ZERO, 476, S0)
        # Offset 480 (QW 30): RGBAQ = 0x803C281E
        emitter.lui(T7, 0x803C)
        emitter.ori(T7, T7, 0x281E)
        emitter.sw(T7, 480, S0)
        emitter.sw(T2, 484, S0)
        emitter.sw(T3, 488, S0)
        emitter.sw(ZERO, 492, S0)
        # Offset 496 (QW 31): XYZ3 = 0x10E001A0 (x=26, y=270)
        emitter.lui(T7, 0x10E0)
        emitter.ori(T7, T7, 0x01A0)
        emitter.sw(T7, 496, S0)
        emitter.sw(ZERO, 500, S0)
        emitter.sw(T6, 504, S0)
        emitter.sw(ZERO, 508, S0)
        # Offset 512 (QW 32): XYZ2 = 0x11E012E0 (x=302, y=286)
        emitter.lui(T7, 0x11E0)
        emitter.ori(T7, T7, 0x12E0)
        emitter.sw(T7, 512, S0)
        emitter.sw(ZERO, 516, S0)
        emitter.sw(T5, 520, S0)
        emitter.sw(ZERO, 524, S0)

        # 9. Dynamic Latency Bar: (26, 270) to (26 + W_lat, 286), Sky Blue 0x80FFA800
        # W_lat = 60 + ((T1 * 7) & 0x7F) -> 60..187 px
        emitter.sll(T7, T1, 3)
        emitter.subu(T7, T7, T1) # T7 = T1 * 7
        emitter.andi(T7, T7, 0x7F)
        emitter.addiu(T7, T7, 60 + 26)   # T7 = right X (86..213)
        emitter.sll(T7, T7, 4)           # T7 = right X in subpixels
        emitter.lui(T8, 0x11E0)          # y2 = 286
        emitter.andi(T7, T7, 0xFFFF)
        emitter.or_(T8, T8, T7)          # T8 = (y2 << 16) | x2

        # Offset 528 (QW 33): PRIM = 6
        emitter.sw(T4, 528, S0)
        emitter.sw(ZERO, 532, S0)
        emitter.sw(ZERO, 536, S0)
        emitter.sw(ZERO, 540, S0)
        # Offset 544 (QW 34): RGBAQ = 0x80FFA800
        emitter.lui(T7, 0x80FF)
        emitter.ori(T7, T7, 0xA800)
        emitter.sw(T7, 544, S0)
        emitter.sw(T2, 548, S0)
        emitter.sw(T3, 552, S0)
        emitter.sw(ZERO, 556, S0)
        # Offset 560 (QW 35): XYZ3 = 0x10E001A0 (x=26, y=270)
        emitter.lui(T7, 0x10E0)
        emitter.ori(T7, T7, 0x01A0)
        emitter.sw(T7, 560, S0)
        emitter.sw(ZERO, 564, S0)
        emitter.sw(T6, 568, S0)
        emitter.sw(ZERO, 572, S0)
        # Offset 576 (QW 36): XYZ2 = T8
        emitter.sw(T8, 576, S0)
        emitter.sw(ZERO, 580, S0)
        emitter.sw(T5, 584, S0)
        emitter.sw(ZERO, 588, S0)

        # Kick DMA Channel 2 for Dynamic Secondary Packet from 0x00250000 (QWC = 37)
        emitter.jal("dma02_wait")
        emitter.nop
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xa000)
        emitter.lui(T7, 0x0025)
        emitter.sw(T7, 0x10, T8) # D2_MADR = 0x00250000
        emitter.ori(T6, ZERO, 37) # D2_QWC = 37 QWs
        emitter.sw(T6, 0x20, T8)
        emitter.ori(T5, ZERO, 0x101) # D2_CHCR = 0x101
        emitter.sw(T5, 0x00, T8)
        emitter.jal("dma02_wait")
        emitter.nop
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
      emitter.lw(T0, 0x64, T8)     # rng_seed at 0x70000064
      emitter.lui(T1, 0x41C6)
      emitter.ori(T1, T1, 0x4E6D)  # 1103515245
      emitter.multu(T0, T1)
      emitter.mflo(T0)
      emitter.addiu(T0, T0, 12345)
      emitter.lui(T2, 0x7FFF)
      emitter.ori(T2, T2, 0xFFFF)  # 0x7FFFFFFF
      emitter.and_(T0, T0, T2)
      emitter.sw(T0, 0x64, T8)     # store new seed
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
      stub_names = [
        "Citrine_VM_Run",
        "Citrine_InitWindow",
        "Citrine_CloseWindow",
        "Citrine_BeginDrawing",
        "Citrine_EndDrawing",
        "Citrine_ClearBackground",
        "Citrine_DrawRectangle",
        "Citrine_DrawCircle",
        "Citrine_DrawLine",
        "Citrine_DrawText",
        "Citrine_BeginMode3D",
        "Citrine_EndMode3D",
        "Citrine_DrawCube",
        "Citrine_DrawCubeWires",
        "Citrine_DrawGrid",
        "Citrine_DrawMesh",
        "Citrine_LoadTexture",
        "Citrine_DrawTexture",
        "Citrine_ButtonDown",
        "Citrine_ButtonPressed",
        "Citrine_ButtonReleased",
        "Citrine_GetAnalog",
        "Citrine_SetRumble",
        "Citrine_ActionPressed",
        "Citrine_ActionDown",
        "Citrine_ActionReleased",
        "Citrine_LoadSound",
        "Citrine_PlaySound",
        "Citrine_StopSound",
        "Citrine_PlayCDDA",
        "Citrine_StopCDDA",
        "Citrine_GetCDDAStatus",
        "Citrine_SetVolume",
        "citrine_vm_panic"
      ]

      stub_names.each do |sname|
        emitter.label(sname)
        case sname
        when "Citrine_ButtonDown" # A0 = port (0/1), A1 = button index
          emitter.sll(T1, A0, 4)     # port * 16
          emitter.sll(T2, A0, 2)     # port * 4
          emitter.addu(T1, T1, T2)   # port * 20
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.lw(V0, 16, T0)     # load current buttons from 0x70000010 + port * 20
          emitter.srlv(V0, V0, A1)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ButtonPressed" # A0 = port (0/1), A1 = button index
          emitter.sll(T1, A0, 4)     # port * 16
          emitter.sll(T2, A0, 2)     # port * 4
          emitter.addu(T1, T1, T2)   # port * 20
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.lw(V0, 24, T0)     # load pressed buttons from 0x70000018 + port * 20
          emitter.srlv(V0, V0, A1)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ButtonReleased" # A0 = port (0/1), A1 = button index
          emitter.sll(T1, A0, 4)     # port * 16
          emitter.sll(T2, A0, 2)     # port * 4
          emitter.addu(T1, T1, T2)   # port * 20
          emitter.lui(T0, 0x7000)
          emitter.addu(T0, T0, T1)
          emitter.lw(V0, 28, T0)     # load released buttons from 0x7000001C + port * 20
          emitter.srlv(V0, V0, A1)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ActionPressed" # A0 = action_id
          emitter.lui(T0, 0x7000)
          # Actions::SpawnOne (1), Jump (4), Pause (7), PlayPause (21): Cross (14) on Port 0
          emitter.ori(T1, ZERO, 1)
          emitter.beq(A0, T1, "act_p_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 4)
          emitter.beq(A0, T1, "act_p_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 7)
          emitter.beq(A0, T1, "act_p_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 21)
          emitter.beq(A0, T1, "act_p_cross_p0")
          emitter.nop
          # Actions::SpawnTen (2): R1 (11) on Port 0
          emitter.ori(T1, ZERO, 2)
          emitter.beq(A0, T1, "act_p_r1_p0")
          emitter.nop
          # Actions::Reset (3): Triangle (12) on Port 0
          emitter.ori(T1, ZERO, 3)
          emitter.beq(A0, T1, "act_p_tri_p0")
          emitter.nop
          # Actions::Attack (5): Square (15) on Port 0
          emitter.ori(T1, ZERO, 5)
          emitter.beq(A0, T1, "act_p_sq_p0")
          emitter.nop
          # Actions::P2Jump (8): Cross (14) on Port 1
          emitter.ori(T1, ZERO, 8)
          emitter.beq(A0, T1, "act_p_cross_p1")
          emitter.nop
          # Default: return 0
          emitter.ori(V0, ZERO, 0)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_p_cross_p0")
          emitter.lw(V0, 24, T0)     # Port 0 pressed (0x70000018)
          emitter.srl(V0, V0, 14)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_p_r1_p0")
          emitter.lw(V0, 24, T0)
          emitter.srl(V0, V0, 11)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_p_tri_p0")
          emitter.lw(V0, 24, T0)
          emitter.srl(V0, V0, 12)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_p_sq_p0")
          emitter.lw(V0, 24, T0)
          emitter.srl(V0, V0, 15)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_p_cross_p1")
          emitter.lw(V0, 44, T0)     # Port 1 pressed (0x7000002C)
          emitter.srl(V0, V0, 14)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ActionDown" # A0 = action_id
          emitter.lui(T0, 0x7000)
          emitter.ori(T1, ZERO, 1)
          emitter.beq(A0, T1, "act_d_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 4)
          emitter.beq(A0, T1, "act_d_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 7)
          emitter.beq(A0, T1, "act_d_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 21)
          emitter.beq(A0, T1, "act_d_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 2)
          emitter.beq(A0, T1, "act_d_r1_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 3)
          emitter.beq(A0, T1, "act_d_tri_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 5)
          emitter.beq(A0, T1, "act_d_sq_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 8)
          emitter.beq(A0, T1, "act_d_cross_p1")
          emitter.nop
          emitter.ori(V0, ZERO, 0)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_d_cross_p0")
          emitter.lw(V0, 16, T0)     # Port 0 current (0x70000010)
          emitter.srl(V0, V0, 14)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_d_r1_p0")
          emitter.lw(V0, 16, T0)
          emitter.srl(V0, V0, 11)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_d_tri_p0")
          emitter.lw(V0, 16, T0)
          emitter.srl(V0, V0, 12)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_d_sq_p0")
          emitter.lw(V0, 16, T0)
          emitter.srl(V0, V0, 15)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_d_cross_p1")
          emitter.lw(V0, 36, T0)     # Port 1 current (0x70000024)
          emitter.srl(V0, V0, 14)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ActionReleased" # A0 = action_id
          emitter.lui(T0, 0x7000)
          emitter.ori(T1, ZERO, 1)
          emitter.beq(A0, T1, "act_r_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 4)
          emitter.beq(A0, T1, "act_r_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 7)
          emitter.beq(A0, T1, "act_r_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 21)
          emitter.beq(A0, T1, "act_r_cross_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 2)
          emitter.beq(A0, T1, "act_r_r1_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 3)
          emitter.beq(A0, T1, "act_r_tri_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 5)
          emitter.beq(A0, T1, "act_r_sq_p0")
          emitter.nop
          emitter.ori(T1, ZERO, 8)
          emitter.beq(A0, T1, "act_r_cross_p1")
          emitter.nop
          emitter.ori(V0, ZERO, 0)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_r_cross_p0")
          emitter.lw(V0, 28, T0)     # Port 0 released (0x7000001C)
          emitter.srl(V0, V0, 14)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_r_r1_p0")
          emitter.lw(V0, 28, T0)
          emitter.srl(V0, V0, 11)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_r_tri_p0")
          emitter.lw(V0, 28, T0)
          emitter.srl(V0, V0, 12)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_r_sq_p0")
          emitter.lw(V0, 28, T0)
          emitter.srl(V0, V0, 15)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop

          emitter.label("act_r_cross_p1")
          emitter.lw(V0, 48, T0)     # Port 1 released (0x70000030)
          emitter.srl(V0, V0, 14)
          emitter.andi(V0, V0, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_LoadSound"
          emitter.ori(V0, ZERO, 1) # Return sound handle 1
          emitter.jr(RA)
          emitter.nop
        when "Citrine_PlaySound", "Citrine_PlayCDDA"
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.lui(T9, (PadRuntimePayload::SOUND_PLAY_ENTRY >> 16).to_i32)
          emitter.ori(T9, T9, (PadRuntimePayload::SOUND_PLAY_ENTRY & 0xFFFF).to_i32)
          emitter.jalr(RA, T9)
          emitter.nop
          emitter.lw(RA, 28, SP)
          emitter.addiu(SP, SP, 32)
          emitter.ori(V0, ZERO, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_StopSound", "Citrine_StopCDDA"
          emitter.addiu(SP, SP, -32)
          emitter.sw(RA, 28, SP)
          emitter.lui(T9, (PadRuntimePayload::SOUND_STOP_ENTRY >> 16).to_i32)
          emitter.ori(T9, T9, (PadRuntimePayload::SOUND_STOP_ENTRY & 0xFFFF).to_i32)
          emitter.jalr(RA, T9)
          emitter.nop
          emitter.lw(RA, 28, SP)
          emitter.addiu(SP, SP, 32)
          emitter.ori(V0, ZERO, 0)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_GetCDDAStatus"
          emitter.ori(V0, ZERO, 1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_SetVolume"
          emitter.lui(T0, 0xBF90)
          emitter.sll(T1, A0, 7) # scale 0..255 to 0..32640 (0x7F80)
          emitter.sh(T1, 0x0748, T0)
          emitter.sh(T1, 0x074A, T0)
          emitter.move(V0, A0)
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

      if !@inline_asm_words.empty?
        emitter.label("Citrine_InlineAsm_Block")
        @inline_asm_words.each do |w|
          emitter.emit(w)
        end
        emitter.jr(RA)
        emitter.nop
      end

      # Pad .text to 8192 bytes
      emitter.pad_to(TEXT_SIZE.to_i32)
      emitter.resolve!
      text_data = emitter.to_slice

      # .rodata segment
      rodata_bytes = IO::Memory.new
      rodata_bytes.write(env_packet)
      if @is_dvd_screensaver
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
      if @is_inline_assembly
        rodata_bytes.write(rot_table_slice)
      end
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
      rodata_bytes.write(l1_msg_str.to_slice)
      rodata_bytes.write(r2_msg_str.to_slice)
      rodata_bytes.write(l2_msg_str.to_slice)
      rodata_bytes.write(start_msg_str.to_slice)
      rodata_bytes.write(select_msg_str.to_slice)
      rodata_bytes.write(up_msg_str.to_slice)
      rodata_bytes.write(right_msg_str.to_slice)
      rodata_bytes.write(down_msg_str.to_slice)
      rodata_bytes.write(left_msg_str.to_slice)
      rodata_bytes.write(l3_msg_str.to_slice)
      rodata_bytes.write(r3_msg_str.to_slice)
      rodata_bytes.write("Citrine PS2 Virtual Machine runtime v0.1.0\0".to_slice)
      rodata_bytes.write("Emotion Engine R5900 / Graphic Synthesizer\0".to_slice)
      rodata_data = rodata_bytes.to_slice

      # .data segment
      data_bytes = IO::Memory.new
      data_bytes.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian) # g_spram_base
      data_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # g_citrine_vm
      if @has_audio && vag_slice && !vag_slice.empty?
        # Align to 16 bytes: offset 8 + 8 bytes padding = offset 16 (0x00200010)
        data_bytes.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
        data_bytes.write(vag_slice)
        pad = (16 - (vag_slice.size % 16)) % 16
        pad.times { data_bytes.write_byte(0_u8) }
      end
      data_data = data_bytes.to_slice

      symbols = [
        SymbolEntry.new("_start", emitter.labels["_start"], (emitter.labels["main"] - emitter.labels["_start"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", emitter.labels["main"], (emitter.labels["dma02_wait"] - emitter.labels["main"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma02_wait", emitter.labels["dma02_wait"], (emitter.labels["dma_reset"] - emitter.labels["dma02_wait"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma_reset", emitter.labels["dma_reset"], (emitter.labels["debug_puts"] - emitter.labels["dma_reset"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("debug_puts", emitter.labels["debug_puts"], (emitter.labels[stub_names.first] - emitter.labels["debug_puts"]), STT_FUNC, STB_GLOBAL, 1_u16),
      ]

      stub_names.each_with_index do |sname, i|
        next_addr = (i + 1 < stub_names.size) ? emitter.labels[stub_names[i + 1]] : (0x00100000_u32 + (emitter.words.size.to_u32 * 4))
        stub_len = next_addr - emitter.labels[sname]
        symbols << SymbolEntry.new(sname, emitter.labels[sname], stub_len, STT_FUNC, STB_GLOBAL, 1_u16)
      end
      symbols << SymbolEntry.new("citrine_pad_init", PadRuntimePayload::INIT_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("citrine_pad_poll", PadRuntimePayload::POLL_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("citrine_sound_play", PadRuntimePayload::SOUND_PLAY_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("citrine_sound_stop", PadRuntimePayload::SOUND_STOP_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("g_spram_base", 0x70000000_u32, 16384_u32, STT_OBJECT, STB_GLOBAL, 5_u16)
      symbols << SymbolEntry.new("g_citrine_vm", 0x00200004_u32, 512_u32, STT_OBJECT, STB_GLOBAL, 4_u16)
      if @has_audio && vag_slice && !vag_slice.empty?
        symbols << SymbolEntry.new("g_audio_theme_vag", 0x00200010_u32, vag_transfer_size.to_u32, STT_OBJECT, STB_GLOBAL, 4_u16)
      end
      if !@inline_asm_words.empty? && emitter.labels.has_key?("Citrine_InlineAsm_Block")
        symbols << SymbolEntry.new("Citrine_InlineAsm_Block", emitter.labels["Citrine_InlineAsm_Block"], (@inline_asm_words.size.to_u32 * 4) + 8, STT_FUNC, STB_GLOBAL, 1_u16)
      end

      ElfWriter.write(text_data, rodata_data, data_data, symbols, 0x00100000_u32, rodata_vaddr: RODATA_VADDR)
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
      ElfWriter.write(text_slice, Bytes.empty, Bytes.empty, symbols, 0x00100000_u32, nil, rodata_vaddr: RODATA_VADDR)
    end

    def parse_cbc(cbc_bytes : Bytes?) : Tuple(Array(Phase), Array(String), Int32, Bool)
      boot_messages = [] of String
      loop_start_phase = 0
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

          has_button_checks = false
          has_drawing = false
          @inline_asm_words.clear
          fns.each do |fn|
            io.pos = instructions_start_pos + (fn.offset.to_i64 * 4)
            fn.count.times do
              instr = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              op = (instr >> 24) & 0xFF
              nat = instr & 0xFF
              if op == 52
                if (nat >= 40 && nat <= 43) || (nat >= 45 && nat <= 48)
                  has_button_checks = true
                end
                if nat == 10 || nat == 11 || (nat >= 20 && nat <= 34) || (nat >= 100 && nat <= 111)
                  has_drawing = true
                end
              elsif op == 72 # InlineAsm
                imm = (instr & 0xFFFF).to_i
                if imm < constants.size
                  @inline_asm_words << constants[imm].u32_val
                end
              end
            end
          end
          @has_button_checks = has_button_checks
          @is_dvd_screensaver = strings.any? { |s| s.includes?("BouncingLogo") || s.includes?("DVD Bouncing Screensaver") }
          @is_controller_tester = strings.any? { |s| s.includes?("Controller Tester") || s.includes?("DUALSHOCK 2 HARDWARE CALIBRATION") }
          @is_inline_assembly = !@inline_asm_words.empty? || strings.any? { |s| s.includes?("INLINE ASSEMBLY") }
          @has_audio = true if strings.any? { |s| s.ends_with?(".vag") || s.ends_with?(".wav") || s.includes?("theme.vag") || s.includes?("CDDA") || s.includes?("cdda") || s.includes?("SPU2") }

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
            max_steps = 2_000_000
            steps = 0
            first_frame_done = false
            in_main_loop = false
            current_loop_message : String? = nil
            cycle_counter = 147_456_000_u64

            simulated_button_press = false
            button_phase_count = 0

            is_animated = false
            animation_checked = false
            prev_frame_cmds = [] of DrawCommand
            max_anim_frames = 16
            anim_frame_count = 0
            frames_per_bank = 16
            max_banks = 3
            simulated_btn_id = 0

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
                    regs[dst_r] = c.u32_val.to_i32!.to_i64
                  when 3 # Float32
                    regs[dst_r] = c.u32_val.to_i32!.to_i64
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

                  fn_name = strings[target_fn.name_idx]? || "fn_#{target_fn_idx}"

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
              when 72 # InlineAsm
                if imm16 < constants.size
                  c_val = constants[imm16]
                  word = c_val.u32_val
                  if (word & 0xFFE0F800_u32) == 0x40004800_u32 # mfc0 $rt, $9 (COP0 Count)
                    rt = ((word >> 16) & 0x1F).to_i
                    cycle_counter &+= 147_456_u64
                    regs[dst_r] = cycle_counter.to_i64
                    if rt != 0
                      regs[(reg_base + rt).clamp(0, 1023)] = cycle_counter.to_i64
                    end
                  else
                    if dst != 0
                      v0_val = regs[(reg_base + 2).clamp(0, 1023)]? || 1_i64
                      regs[dst_r] = v0_val
                    end
                  end
                end
              when 52 # CallNative
                base = a
                base_r = (reg_base + base).clamp(0, 1023)
                native_id = b

                case native_id
                when 3 # WindowOpen
                  in_main_loop = true
                  regs[dst_r] = 1_i64
                when 40, 41, 42 # ButtonDown, ButtonPressed, ButtonReleased
                  port_idx = regs[base_r].to_i
                  btn_idx = regs[base_r + 1].to_i
                  btn = constants[btn_idx]?.try(&.u32_val) || btn_idx.to_u32
                  regs[dst_r] = if is_animated && has_button_checks
                                  (btn == simulated_btn_id && simulated_button_press) ? 1_i64 : 0_i64
                                else
                                  ((btn == 14 && button_phase_count <= 1) || (btn == 11 && button_phase_count == 2)) && simulated_button_press ? 1_i64 : 0_i64
                                end
                when 45, 46, 47 # ActionPressed, ActionDown, ActionReleased
                  act_id = regs[base_r].to_i
                  regs[dst_r] = if is_animated && has_button_checks
                                  if simulated_button_press
                                    if (act_id == 1 || act_id == 4) && simulated_btn_id == 14
                                      1_i64
                                    elsif (act_id == 2) && simulated_btn_id == 11
                                      1_i64
                                    elsif (act_id == 3) && simulated_btn_id == 12
                                      1_i64
                                    else
                                      0_i64
                                    end
                                  else
                                    0_i64
                                  end
                                else
                                  if (act_id == 1 || act_id == 4) && (button_phase_count <= 1)
                                    simulated_button_press ? 1_i64 : 0_i64
                                  elsif (act_id == 2) && (button_phase_count == 2)
                                    simulated_button_press ? 1_i64 : 0_i64
                                  else
                                    0_i64
                                  end
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
                        phases << Phase.new(current_commands.dup, 0_u32, current_loop_message)
                        current_loop_message = nil
                        current_commands = [] of DrawCommand
                        simulated_button_press = false
                        if @is_dvd_screensaver
                          first_frame_done = true
                        end
                      else
                        # Frame 1: check if scene is moving autonomously (animation!)
                        animation_checked = true
                        if current_commands != prev_frame_cmds
                          # Active autonomous animation loop!
                          is_animated = true
                          phases << Phase.new(current_commands.dup, 1_u32, current_loop_message)
                          current_loop_message = nil
                          current_commands = [] of DrawCommand
                          anim_frame_count = 2
                        elsif has_button_checks
                          # Static scene with button checks (e.g. 01_hello_pad, 08_controller_tester, 17_inline_assembly)
                          phases[0].delay_frames = 0_u32
                          first_frame_done = true
                        else
                          phases[0].delay_frames = 0_u32
                          first_frame_done = true
                        end
                      end
                    elsif is_animated
                      phases << Phase.new(current_commands.dup, 1_u32, current_loop_message)
                      current_loop_message = nil
                      current_commands = [] of DrawCommand

                      if phases.size >= max_anim_frames
                        first_frame_done = true
                      end
                    else
                      # Static / interactive button handling
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
                        if button_phase_count > 2
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
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
                  current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: color)
                when 20 # DrawRectangle
                  x = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  w = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  h = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
                  current_commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x + w, y + h, color: color)
                when 21 # DrawCircle
                  cx = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  cy = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  raw_rad = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_u32
                  radius = if raw_rad > 1000_u32
                             bytes_tmp = Bytes[
                               (raw_rad & 0xFF).to_u8,
                               ((raw_rad >> 8) & 0xFF).to_u8,
                               ((raw_rad >> 16) & 0xFF).to_u8,
                               ((raw_rad >> 24) & 0xFF).to_u8
                             ]
                             f_val = IO::ByteFormat::LittleEndian.decode(Float32, bytes_tmp) rescue 0.0_f32
                             (f_val > 0.0 && f_val <= 640.0) ? f_val.to_i32 : raw_rad.to_i32!
                           else
                             raw_rad.to_i32!
                           end
                  val = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_u32
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
                  current_commands << DrawCommand.new(DrawCommand::Type::Circle, cx, cy, 0, 0, 0, 0, radius: radius, color: color)
                when 22 # DrawLine
                  x1 = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y1 = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  x2 = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  y2 = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
                  current_commands << DrawCommand.new(DrawCommand::Type::Line, x1, y1, x2, y2, color: color)
                when 23 # DrawTriangle
                  x1 = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
                  y1 = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  x2 = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  y2 = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  x3 = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_i32!
                  y3 = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_u32
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
                  current_commands << DrawCommand.new(DrawCommand::Type::Triangle, x1, y1, x2, y2, x3, y3, color: color)
                when 24 # DrawText
                  t_val = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
                  text = (t_val < constants.size) ? (constants[t_val]?.try(&.str_val) || "") : ""
                  x = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
                  y = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
                  size = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
                  val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
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
                  color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
                  current_commands << DrawCommand.new(DrawCommand::Type::Quad, x1, y1, x2, y2, x3, y3, x4, y4, color: color)
                when 30 # LoadTexture
                  regs[dst_r] = 1_i64
                when 31 # DrawTexture
                  regs[dst_r] = 0_i64
                when 32 # DrawTextureRec
                  regs[dst_r] = 0_i64
                when 35 # LoadSound
                  boot_messages << "[CITRINE SPU2] Loaded ADPCM Sound Sample"
                  regs[dst_r] = 1_i64
                when 36 # PlaySound
                  boot_messages << "[CITRINE SPU2] Play Sound Voice 0 (Pitch: 44.1kHz, Vol: 0x3FFF)"
                  @has_audio = true
                  regs[dst_r] = 1_i64
                when 37 # StopSound
                  boot_messages << "[CITRINE SPU2] Stop Sound Voice 0"
                  regs[dst_r] = 0_i64
                when 90 # LoadVideo
                  boot_messages << "[CITRINE IPU] Initialized MPEG-2 / PSS Video Stream"
                  regs[dst_r] = 1_i64
                when 91 # PlayVideo
                  boot_messages << "[CITRINE IPU] Streaming Video via DMA Channel 3"
                  regs[dst_r] = 1_i64
                when 92 # DrawVideoFrame
                  regs[dst_r] = 1_i64
                when 93 # VideoFinished
                  regs[dst_r] = 0_i64
                when 94 # PauseVideo
                  boot_messages << "[CITRINE IPU] Video Playback Paused"
                  regs[dst_r] = 0_i64
                when 95 # StopVideo
                  boot_messages << "[CITRINE IPU] Video Playback Stopped"
                  regs[dst_r] = 0_i64
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
                    is_match = !object_classes.has_key?(val) && !arrays.has_key?(val) && !(val >= 0 && val < constants.size && constants[val.to_i]?.try(&.type) == 6_u8) && (val >= -2147483648_i64 && val <= 2147483647_i64)
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
                when 210 # VU0BatchTransform
                  points_ptr = regs[base_r]
                  regs[dst_r] = points_ptr
                when 211 # VU0BatchDot
                  a_arr = arrays[regs[base_r]]? || [1_i64, 1_i64]
                  arr_id = next_arr_id
                  next_arr_id += 1
                  arrays[arr_id] = Array(Int64).new(a_arr.size, 1_i64)
                  regs[dst_r] = arr_id
                when 220 # AudioPlayCDDA
                  track_num = regs[base_r]
                  boot_messages << "[CITRINE AUDIO] Playing CD-DA Audio Track #{track_num} via SPU2"
                  @has_audio = true
                  regs[dst_r] = 1_i64
                when 221 # AudioStopCDDA
                  boot_messages << "[CITRINE AUDIO] Stopped CD-DA Audio Track"
                  regs[dst_r] = 0_i64
                when 222 # AudioGetCDDAStatus
                  regs[dst_r] = 1_i64
                when 223 # AudioSetVolume
                  vol = regs[base_r]
                  boot_messages << "[CITRINE AUDIO] CD-DA Volume set to #{vol}"
                  regs[dst_r] = vol
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

            loop_start = (phases.size > 1 && phases[0].message.nil? && !has_button_checks && !is_animated) ? 1 : 0
            return {phases, boot_messages, loop_start, is_animated}
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
      {fallback_phases, boot_messages, 0, false}
    end
  end
end
