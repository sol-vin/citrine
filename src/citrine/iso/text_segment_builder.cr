require "../mips/mips_emitter"
require "./phase_extractor"
require "./rodata_segment_builder"
require "./runtime_subroutines"
require "./pad_runtime_payload"
require "./mips_compiler"

module Citrine
  module ISO
    # Builds the general-purpose PlayStation 2 MIPS R5900 .text segment.
    # Handles system startup, hardware initialization, main frame loop,
    # controller polling, audio transport, and phase sequencing.
    class TextSegmentBuilder
      alias MipsEmitter = Citrine::MIPS::MipsEmitter
      include Citrine::MIPS

      TEXT_SIZE = 16384_u32

      getter profile : ProgramProfile
      getter rodata : RodataResult
      getter mips_compiler : MipsCompiler? = nil

      def self.build(profile : ProgramProfile, rodata : RodataResult) : Tuple(Bytes, MipsEmitter)
        builder = new(profile, rodata)
        bytes, emitter = builder.build
        {bytes, emitter}
      end

      def self.build(profile : ProgramProfile, rodata : RodataResult, cbc_bytes : Bytes?) : Tuple(Bytes, MipsEmitter, MipsCompiler?)
        builder = new(profile, rodata, cbc_bytes)
        bytes, emitter = builder.build
        {bytes, emitter, builder.mips_compiler}
      end

      def initialize(@profile : ProgramProfile, @rodata : RodataResult, @cbc_bytes : Bytes? = nil)
        if bytes = @cbc_bytes
          compiler = MipsCompiler.new
          compiler.load_cbc(bytes)
          @mips_compiler = compiler
        end
      end

      def build : Tuple(Bytes, MipsEmitter)
        emitter = MipsEmitter.new

        # -------------------------------------------------------------
        # 1. Entry Point: _start
        # -------------------------------------------------------------
        emitter.label("_start")
        emitter.lui(SP, 0x01FF)
        emitter.ori(SP, SP, 0xFFF0) # Stack top: 0x01FFFFF0

        emitter.lui(T0, 0x7000) # SPRAM base: 0x70000000

        # Fast 128-bit Quadword SPRAM Zeroing (16 KB = 256 iterations x 64 bytes)
        emitter.ori(T1, ZERO, 256)
        emitter.label("spram_clear_loop")
        emitter.sq(ZERO, 0, T0)
        emitter.sq(ZERO, 16, T0)
        emitter.sq(ZERO, 32, T0)
        emitter.sq(ZERO, 48, T0)
        emitter.addiu(T0, T0, 64)
        emitter.addiu(T1, T1, -1)
        emitter.bnez(T1, "spram_clear_loop")
        emitter.nop

        emitter.lui(T0, 0x7000)

        # Write SPRAM Canary Word at 0x70000000: 0xDEADBEEF
        emitter.lui(T1, 0xDEAD)
        emitter.ori(T1, T1, 0xBEEF)
        emitter.sw(T1, 0, T0)

        # Pin $fp (Register Base) to 0x70000100 in zero-wait-state SPRAM
        emitter.lui(FP, 0x7000)
        emitter.ori(FP, FP, 0x0100)

        # Reset Per-Frame Zero-GC Scratch Bump Arena at 0x70003100
        emitter.sw(ZERO, 0x3100, T0)

        # Neutral analog sticks: RX=128, RY=128, LX=128, LY=128 (0x80808080) at 0x70000020
        emitter.lui(T1, 0x8080)
        emitter.ori(T1, T1, 0x8080)
        emitter.sw(T1, 32, T0)

        # Initial phase delay frames at 0x7000000C
        if @profile.phases.size > 0
          init_delay = @profile.phases[0].delay_frames
          emitter.li(T1, init_delay)
          emitter.sw(T1, 12, T0)
        end

        # Initialize DualShock 2 Pad Driver & Sound Driver in IOP
        emitter.li(T9, PadRuntimePayload::INIT_ENTRY)
        emitter.jalr(T9)
        emitter.nop

        # Audio state initialization
        if @profile.has_audio
          emitter.lui(T0, 0x7000)
          emitter.ori(T1, ZERO, 1)
          emitter.sw(T1, 60, T0) # 0x7000003C: audio playing flag = 1
          emitter.ori(T1, ZERO, 240)
          emitter.sw(T1, 0x70, T0) # 0x70000070: master_vol = 240
          emitter.ori(T1, ZERO, 1)
          emitter.sw(T1, 0x74, T0) # 0x70000074: is_looping = 1 (ON)
          total_trk = Math.max(@profile.phases.size, @profile.num_tracks)
          emitter.li(T1, total_trk)
          emitter.sw(T1, 0x7C, T0)   # 0x7000007C: total_tracks = total_trk
          emitter.sw(ZERO, 0x80, T0) # 0x70000080: elapsed_sec = 0

          # Start audio playback via SPU2 (cmd 1 = Play)
          emitter.li(A0, 1)
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop

          # Set initial volume (0x1000 | 240)
          emitter.li(A0, 0x10F0)
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
        end

        # Reset DMAC
        emitter.call("dma_reset")

        # -------------------------------------------------------------
        # 2. Main Entry Point: main & Hardware Graphics Initialization
        # -------------------------------------------------------------
        emitter.label("main")

        # GS CSR Reset: write 0x0100 to GS CSR (0x12001000)
        emitter.lui(T0, 0x1200)
        emitter.ori(T0, T0, 0x1000)
        emitter.ori(T1, ZERO, 0x0100)
        emitter.sd(T1, 0, T0)

        # Syscall 0x71: _GsPutIMR(0xFF00)
        emitter.lui(A0, 0x0000)
        emitter.ori(A0, A0, 0xFF00)
        emitter.ori(V1, ZERO, 0x71)
        emitter.syscall_inst
        emitter.nop

        # Syscall 0x02: _SetGsCrt(interlace=1, mode=2 [NTSC], frame=0 [FIELD])
        emitter.ori(A0, ZERO, 1)
        emitter.ori(A1, ZERO, 2)
        emitter.move(A2, ZERO)
        emitter.ori(V1, ZERO, 2)
        emitter.syscall_inst
        emitter.nop

        # GS PMODE (0x12000000) = 0xFF65 (Circuit 1 enable, CRTMD=1, MMOD=1, AMOD=1, ALP=0xFF)
        emitter.lui(T0, 0x1200)
        emitter.lui(T1, 0x0000)
        emitter.ori(T1, T1, 0xFF65)
        emitter.sd(T1, 0, T0)

        # GS DISPFB1 (0x12000070) & GS DISPFB2 (0x12000090): 0x1400 (FBP=0, FBW=10 [640px], PSM=0 [PSMCT32])
        emitter.ori(T1, ZERO, 0x1400)
        emitter.sd(T1, 0x70, T0)
        emitter.sd(T1, 0x90, T0)

        # GS DISPLAY1 (0x12000080) & GS DISPLAY2 (0x120000A0): 0x001bf9ff01832290 (NTSC Field mode dy=50 centered)
        emitter.lui(T1, 0x001b)
        emitter.ori(T1, T1, 0xf9ff)
        emitter.dsll32(T1, T1, 0)
        emitter.lui(T2, 0x0183)
        emitter.ori(T2, T2, 0x2290)
        emitter.or_(T1, T1, T2)
        emitter.sd(T1, 0x80, T0)
        emitter.sd(T1, 0xa0, T0)

        # GS BGCOLOR (0x120000e0): Black (R=0, G=0, B=0)
        emitter.sd(ZERO, 0xe0, T0)

        # Send GS Environment Setup Packet via DMAC Channel 2
        emitter.dma02_kick(@rodata.env_packet_addr, @rodata.env_packet_qwc)

        # Print Boot Banner and Messages to Console
        emitter.li(A0, @rodata.banner_addr)
        emitter.call("debug_puts")

        @rodata.boot_msg_addrs.each do |msg_addr|
          emitter.li(A0, msg_addr)
          emitter.call("debug_puts")
        end

        # Launch User Program if __main__ is present in compiled bytecode
        if compiler = @mips_compiler
          if main_fn_idx = compiler.main_fn_idx
            # Pin $fp (Register Base) to 0x70000400 for __main__
            emitter.lui(FP, 0x7000)
            emitter.ori(FP, FP, 0x0400)

            # Initialize heap pointer at 0x7000008C (heap starts at 0x00220000, safe above pad buffers at 0x00210000..0x002101FF)
            emitter.lui(T0, 0x7000)
            emitter.lui(T1, 0x0022)
            emitter.sw(T1, 0x8C, T0)

            # Initialize fiber state in SPRAM
            emitter.lui(T0, 0x7000)
            emitter.sw(ZERO, 0x88, T0) # fiber_count = 0
            emitter.li(T1, -1)
            emitter.sw(T1, 0x84, T0)   # current_fiber_idx = -1

            # Call __main__!
            emitter.jump("after_dbg_main")
            emitter.nop
            emitter.label("dbg_str_main")
            emitter.emit_string("[CITRINE] Entering __main__\n")
            emitter.label("after_dbg_main")
            emitter.la(A0, "dbg_str_main")
            emitter.call("debug_puts")

            emitter.jal("fn_#{main_fn_idx}")
            emitter.nop

            # Once __main__ returns, loop in frame_loop
            emitter.jump("frame_loop")
            emitter.nop
          end
        end

        # -------------------------------------------------------------
        # 3. Main Frame Loop
        # -------------------------------------------------------------
        emitter.label("frame_loop")

        # Wait for VSync
        emitter.vsync_wait("fl")

        # Increment frame counter at 0x70000004
        emitter.lui(T0, 0x7000)
        emitter.lw(T1, 4, T0)
        emitter.addiu(T1, T1, 1)
        emitter.sw(T1, 4, T0)

        # Reset per-frame Zero-GC Scratch Bump Arena at 0x70003100
        emitter.sw(ZERO, 0x3100, T0)

        # Render Primary Phase Draw Packet
        if @rodata.phase_addrs.empty?
          # No draw packets
        else
          if @rodata.phase_table_addr > 0
            emitter.lw(T2, 8, T0) # phase index
            if @rodata.phase_addrs.size > 1
              emitter.ori(T3, ZERO, @rodata.phase_addrs.size)
              emitter.divu(T2, T3)
              emitter.mfhi(T2) # T2 = phase_index % phases.size
            end
            # S7 = phase_table_addr + (phase_index * 128)
            emitter.sll(T3, T2, 7) # T2 * 128
            emitter.li(S7, @rodata.phase_table_addr)
            emitter.addu(S7, S7, T3) # S7 = PhaseDescriptor*
            emitter.lw(T7, 0, S7)    # MADR
            emitter.lw(T6, 4, S7)    # QWC
          elsif @rodata.phase_addrs.size == 1
            emitter.li(T7, @rodata.phase_addrs[0])
            emitter.ori(T6, ZERO, @rodata.phase_qwcs[0].to_i32)
          else
            # Multi-phase branch lookup fallback
            emitter.lw(T2, 8, T0) # phase index
            @rodata.phase_addrs.each_with_index do |addr, i|
              if i < @rodata.phase_addrs.size - 1
                emitter.ori(T3, ZERO, i)
                emitter.bne(T2, T3, "check_phase_#{i + 1}")
                emitter.nop
              end
              emitter.li(T7, addr)
              emitter.ori(T6, ZERO, @rodata.phase_qwcs[i].to_i32)
              if i < @rodata.phase_addrs.size - 1
                emitter.jump("primary_phase_selected")
                emitter.label("check_phase_#{i + 1}")
              end
            end
            emitter.label("primary_phase_selected")
          end

          if @profile.has_audio
            # Update elapsed frames if playing (0x7000003C == 1)
            emitter.lw(T5, 60, T0)
            emitter.ori(T4, ZERO, 1)
            emitter.bne(T5, T4, "skip_elapsed_inc")
            emitter.nop

            # Check if fast-forwarding (R2 held) or rewinding (L2 held)
            emitter.lw(T4, 16, T0)       # port 0 current buttons
            emitter.andi(T1, T4, 0x0200) # R2
            emitter.bnez(T1, "elapsed_fast_fwd")
            emitter.nop
            emitter.andi(T1, T4, 0x0100) # L2
            emitter.bnez(T1, "elapsed_rewind")
            emitter.nop

            # Normal 1x playback: +1 frame
            emitter.lw(T5, 0x80, T0)
            emitter.addiu(T5, T5, 1)
            emitter.sw(T5, 0x80, T0)
            emitter.jump("skip_elapsed_inc")

            emitter.label("elapsed_fast_fwd")
            emitter.lw(T5, 0x80, T0)
            emitter.addiu(T5, T5, 4) # 4x speed
            emitter.sw(T5, 0x80, T0)
            emitter.jump("skip_elapsed_inc")

            emitter.label("elapsed_rewind")
            emitter.lw(T5, 0x80, T0)
            emitter.addiu(T5, T5, -4)
            emitter.bgez(T5, "rewind_ok")
            emitter.nop
            emitter.move(T5, ZERO)
            emitter.label("rewind_ok")
            emitter.sw(T5, 0x80, T0)

            emitter.label("skip_elapsed_inc")

            # Auto-advance track if dur_frames > 0 and elapsed >= dur_frames
            if (@profile.phases.size > 1 || @profile.num_tracks > 1) && @rodata.phase_table_addr > 0
              emitter.lw(T6, 88, S7) # dur_frames from active phase descriptor
              emitter.beqz(T6, "skip_track_auto_advance")
              emitter.nop
              emitter.lw(T5, 0x80, T0) # elapsed_frames
              emitter.sltu(T1, T5, T6)
              emitter.bnez(T1, "skip_track_auto_advance")
              emitter.nop

              # Track finished: check loop mode (0x70000074)
              emitter.lw(T1, 0x74, T0)
              emitter.beqz(T1, "track_auto_stop")
              emitter.nop

              # Auto-advance to Next Track
              emitter.lw(T5, 0x78, T0) # track_idx
              emitter.addiu(T5, T5, 1)
              emitter.lw(T6, 0x7C, T0) # total_tracks
              emitter.sltu(T1, T5, T6)
              emitter.bnez(T1, "auto_adv_ok")
              emitter.nop
              emitter.move(T5, ZERO)
              emitter.label("auto_adv_ok")
              emitter.sw(T5, 0x78, T0)
              emitter.ori(T6, ZERO, @profile.phases.size)
              emitter.divu(T5, T6)
              emitter.mfhi(T1)
              emitter.sw(T1, 8, T0)
              emitter.sw(ZERO, 0x80, T0) # reset elapsed_sec
              emitter.ori(T6, ZERO, 1)
              emitter.sw(T6, 60, T0)
              emitter.andi(A0, T5, 0xFF)
              emitter.ori(A0, A0, 0x0100) # cmd = 0x0100 | track_idx
              emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
              emitter.jalr(T9)
              emitter.nop
              emitter.lui(T0, 0x7000)
              emitter.jump("skip_track_auto_advance")

              emitter.label("track_auto_stop")
              emitter.sw(ZERO, 60, T0) # audio_status = 0 (stopped)
              emitter.li(T9, PadRuntimePayload::SOUND_STOP_ENTRY)
              emitter.jalr(T9)
              emitter.nop
              emitter.lui(T0, 0x7000)

              emitter.label("skip_track_auto_advance")
            end
          end

          if @rodata.phase_table_addr > 0
            # S7 = PhaseDescriptor* (preserved across RPC calls)
            emitter.lw(T7, 0, S7) # MADR
            emitter.lw(T6, 4, S7) # QWC

            # S6 = uncached GIF packet base (0x20000000 | T7)
            emitter.lui(S6, 0x2000)
            emitter.or_(S6, T7, S6)

            # Check flags in S7 + 92
            emitter.lw(T9, 92, S7) # flags

            # -----------------------------------------------------------
            # 4. Live Dynamic Time Digits (MM:SS) (Flag bit 3)
            # -----------------------------------------------------------
            emitter.andi(T1, T9, 8)
            emitter.beqz(T1, "skip_time_update")
            emitter.nop

            emitter.lw(T5, 0x80, T0) # elapsed_frames

            # total_sec = elapsed_frames / 60
            emitter.ori(T1, ZERO, 60)
            emitter.divu(T5, T1)
            emitter.mflo(T2) # T2 = total_sec

            # min = total_sec / 60, sec = total_sec % 60
            emitter.divu(T2, T1)
            emitter.mflo(T3) # T3 = min
            emitter.mfhi(T4) # T4 = sec

            # m1 = min / 10, m2 = min % 10
            emitter.ori(T1, ZERO, 10)
            emitter.divu(T3, T1)
            emitter.mflo(S2) # S2 = min_tens
            emitter.mfhi(S3) # S3 = min_ones

            # s1 = sec / 10, s2 = sec % 10
            emitter.divu(T4, T1)
            emitter.mflo(S4) # S4 = sec_tens
            emitter.mfhi(S5) # S5 = sec_ones

            emitter.lw(A3, 92, S7) # flags
            emitter.srl(A3, A3, 8)
            emitter.andi(A3, A3, 0xFF) # time_text_scale
            emitter.ori(T1, ZERO, 2)
            emitter.beq(A3, T1, "scale_is_2")
            emitter.nop
            emitter.move(A3, ZERO)
            emitter.jump("scale_set")
            emitter.nop
            emitter.label("scale_is_2")
            emitter.ori(A3, ZERO, 1)
            emitter.label("scale_set")

            # Digit 0: Minute tens
            emitter.move(A0, S2)
            emitter.lw(A1, 36, S7) # min_tens_pos
            emitter.lw(T1, 20, S7) # min_tens_offset
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 1: Minute ones
            emitter.move(A0, S3)
            emitter.lw(A1, 40, S7) # min_ones_pos
            emitter.lw(T1, 24, S7) # min_ones_offset
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 2: Second tens
            emitter.move(A0, S4)
            emitter.lw(A1, 44, S7) # sec_tens_pos
            emitter.lw(T1, 28, S7) # sec_tens_offset
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 3: Second ones
            emitter.move(A0, S5)
            emitter.lw(A1, 48, S7) # sec_ones_pos
            emitter.lw(T1, 32, S7) # sec_ones_offset
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            emitter.lui(T0, 0x7000)
            emitter.label("skip_time_update")
          end

          # Live Dynamic Frame Counter Digits in uncached GIF packet RAM
          if @rodata.frame_text_present && @rodata.frame_digit_offsets.size >= 5
            emitter.lui(T0, 0x7000)
            emitter.lw(T5, 4, T0) # T5 = real hardware frame counter from 0x70000004!

            # S6 = uncached GIF packet base (0x20000000 | T7)
            emitter.lui(S6, 0x2000)
            emitter.or_(S6, T7, S6)

            # Decompose T5 into 5 decimal digits: S1..S5
            # S1 = T5 / 10000, rem = T5 % 10000
            emitter.li(T1, 10000)
            emitter.divu(T5, T1)
            emitter.mflo(S1)
            emitter.mfhi(T2)

            # S2 = rem / 1000, rem = rem % 1000
            emitter.li(T1, 1000)
            emitter.divu(T2, T1)
            emitter.mflo(S2)
            emitter.mfhi(T3)

            # S3 = rem / 100, rem = rem % 100
            emitter.ori(T1, ZERO, 100)
            emitter.divu(T3, T1)
            emitter.mflo(S3)
            emitter.mfhi(T4)

            # S4 = rem / 10, S5 = rem % 10
            emitter.ori(T1, ZERO, 10)
            emitter.divu(T4, T1)
            emitter.mflo(S4)
            emitter.mfhi(S5)

            # Left-aligned digit assignment:
            # Check T5 < 10 (1 digit)
            emitter.ori(T1, ZERO, 10)
            emitter.sltu(T2, T5, T1)
            emitter.bnez(T2, "fr_len_1")
            emitter.nop

            # Check T5 < 100 (2 digits)
            emitter.ori(T1, ZERO, 100)
            emitter.sltu(T2, T5, T1)
            emitter.bnez(T2, "fr_len_2")
            emitter.nop

            # Check T5 < 1000 (3 digits)
            emitter.li(T1, 1000)
            emitter.sltu(T2, T5, T1)
            emitter.bnez(T2, "fr_len_3")
            emitter.nop

            # Check T5 < 10000 (4 digits)
            emitter.li(T1, 10000)
            emitter.sltu(T2, T5, T1)
            emitter.bnez(T2, "fr_len_4")
            emitter.nop

            # 5 digits: S1..S5 remain as D0..D4
            emitter.jump("fr_digits_ready")
            emitter.nop

            # 1 digit: Slot 0 = S5 (1s), Slots 1..4 = 10 (blank)
            emitter.label("fr_len_1")
            emitter.move(S1, S5)
            emitter.ori(S2, ZERO, 10)
            emitter.ori(S3, ZERO, 10)
            emitter.ori(S4, ZERO, 10)
            emitter.ori(S5, ZERO, 10)
            emitter.jump("fr_digits_ready")
            emitter.nop

            # 2 digits: Slot 0 = S4 (10s), Slot 1 = S5 (1s), Slots 2..4 = 10 (blank)
            emitter.label("fr_len_2")
            emitter.move(S1, S4)
            emitter.move(S2, S5)
            emitter.ori(S3, ZERO, 10)
            emitter.ori(S4, ZERO, 10)
            emitter.ori(S5, ZERO, 10)
            emitter.jump("fr_digits_ready")
            emitter.nop

            # 3 digits: Slot 0 = S3 (100s), Slot 1 = S4 (10s), Slot 2 = S5 (1s), Slots 3..4 = 10 (blank)
            emitter.label("fr_len_3")
            emitter.move(S1, S3)
            emitter.move(S2, S4)
            emitter.move(S3, S5)
            emitter.ori(S4, ZERO, 10)
            emitter.ori(S5, ZERO, 10)
            emitter.jump("fr_digits_ready")
            emitter.nop

            # 4 digits: Slot 0 = S2 (1000s), Slot 1 = S3 (100s), Slot 2 = S4 (10s), Slot 3 = S5 (1s), Slot 4 = 10 (blank)
            emitter.label("fr_len_4")
            emitter.move(S1, S2)
            emitter.move(S2, S3)
            emitter.move(S3, S4)
            emitter.move(S4, S5)
            emitter.ori(S5, ZERO, 10)

            emitter.label("fr_digits_ready")

            # Pass scale_shift in A3: 1 for scale=2, 0 for scale=1
            emitter.ori(A3, ZERO, @rodata.frame_text_scale == 2 ? 1 : 0)

            # Digit 0: Leftmost active slot
            emitter.move(A0, S1)
            emitter.li(A1, @rodata.frame_digit_positions[0])
            emitter.li(T1, @rodata.frame_digit_offsets[0])
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 1
            emitter.move(A0, S2)
            emitter.li(A1, @rodata.frame_digit_positions[1])
            emitter.li(T1, @rodata.frame_digit_offsets[1])
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 2
            emitter.move(A0, S3)
            emitter.li(A1, @rodata.frame_digit_positions[2])
            emitter.li(T1, @rodata.frame_digit_offsets[2])
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 3
            emitter.move(A0, S4)
            emitter.li(A1, @rodata.frame_digit_positions[3])
            emitter.li(T1, @rodata.frame_digit_offsets[3])
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 4
            emitter.move(A0, S5)
            emitter.li(A1, @rodata.frame_digit_positions[4])
            emitter.li(T1, @rodata.frame_digit_offsets[4])
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            emitter.lui(T0, 0x7000)
          end

          if @rodata.phase_table_addr > 0
            emitter.lw(T7, 0, S7) # MADR
            emitter.lw(T6, 4, S7) # QWC
          elsif @rodata.phase_addrs.size == 1
            emitter.li(T7, @rodata.phase_addrs[0])
            emitter.ori(T6, ZERO, @rodata.phase_qwcs[0].to_i32)
          end

          emitter.dma02_kick_reg(T7, T6)
        end

        # Reset current buttons for Port 0 and Port 1
        emitter.lui(T0, 0x7000)
        emitter.sw(ZERO, 16, T0)
        emitter.sw(ZERO, 36, T0)

        # Check Virtual Input Schedule
        emitter.lw(T1, 4, T0) # T1 = current frame
        emitter.li(T8, @rodata.sched_addr)

        emitter.label("sched_loop")
        emitter.lw(T6, 0, T8) # entry.start_frame
        emitter.li(T5, 0xFFFFFFFF_u32)
        emitter.beq(T6, T5, "sched_done")
        emitter.nop
        emitter.sltu(T7, T1, T6)
        emitter.bnez(T7, "sched_next")
        emitter.nop
        emitter.lhu(T4, 6, T8) # duration_frames
        emitter.addu(T6, T6, T4)
        emitter.sltu(T7, T1, T6)
        emitter.beqz(T7, "sched_next")
        emitter.nop

        # Apply schedule button mask
        emitter.lhu(T4, 4, T8) # button_mask
        emitter.lbu(T3, 8, T8) # port
        emitter.bnez(T3, "sched_apply_p1")
        emitter.nop
        emitter.lw(T5, 16, T0)
        emitter.or_(T5, T5, T4)
        emitter.sw(T5, 16, T0)
        emitter.jump("sched_next")

        emitter.label("sched_apply_p1")
        emitter.lw(T5, 36, T0)
        emitter.or_(T5, T5, T4)
        emitter.sw(T5, 36, T0)

        emitter.label("sched_next")
        emitter.addiu(T8, T8, 16)
        emitter.jump("sched_loop")

        emitter.label("sched_done")

        # Poll Native DualShock 2 Hardware Controllers
        emitter.li(T9, PadRuntimePayload::POLL_ENTRY)
        emitter.jalr(T9)
        emitter.nop
        emitter.lui(T0, 0x7000)

        # Poll EE SIO UART Rx (TTY characters)
        emitter.lui(T8, 0x1000)
        emitter.ori(T8, T8, 0xf100)
        emitter.lbu(T6, 0x10, T8) # SIO_LSR at 0x1000f110
        emitter.andi(T6, T6, 0x01)
        emitter.beqz(T6, "sio_rx_done")
        emitter.nop
        emitter.lbu(T7, 0xc0, T8) # SIO_RXFIFO at 0x1000f1c0
        emitter.beqz(T7, "sio_rx_done")
        emitter.nop

        # SIO Button Mapping:
        # Cross: 'x', 'X', Enter, Space
        emitter.ori(T6, ZERO, 0x78); emitter.beq(T7, T6, "sio_set_cross"); emitter.nop
        emitter.ori(T6, ZERO, 0x58); emitter.beq(T7, T6, "sio_set_cross"); emitter.nop
        emitter.ori(T6, ZERO, 0x0d); emitter.beq(T7, T6, "sio_set_cross"); emitter.nop
        emitter.ori(T6, ZERO, 0x20); emitter.beq(T7, T6, "sio_set_cross"); emitter.nop

        # Triangle: 't', 'T', 'v', 'V'
        emitter.ori(T6, ZERO, 0x74); emitter.beq(T7, T6, "sio_set_triangle"); emitter.nop
        emitter.ori(T6, ZERO, 0x54); emitter.beq(T7, T6, "sio_set_triangle"); emitter.nop
        emitter.ori(T6, ZERO, 0x76); emitter.beq(T7, T6, "sio_set_triangle"); emitter.nop
        emitter.ori(T6, ZERO, 0x56); emitter.beq(T7, T6, "sio_set_triangle"); emitter.nop

        # Circle: 'c', 'C'
        emitter.ori(T6, ZERO, 0x63); emitter.beq(T7, T6, "sio_set_circle"); emitter.nop
        emitter.ori(T6, ZERO, 0x43); emitter.beq(T7, T6, "sio_set_circle"); emitter.nop

        # Square: 's', 'S', 'z', 'Z'
        emitter.ori(T6, ZERO, 0x73); emitter.beq(T7, T6, "sio_set_square"); emitter.nop
        emitter.ori(T6, ZERO, 0x53); emitter.beq(T7, T6, "sio_set_square"); emitter.nop
        emitter.ori(T6, ZERO, 0x7a); emitter.beq(T7, T6, "sio_set_square"); emitter.nop
        emitter.ori(T6, ZERO, 0x5a); emitter.beq(T7, T6, "sio_set_square"); emitter.nop

        # R1: 'r', 'R', 'e', 'E'
        emitter.ori(T6, ZERO, 0x72); emitter.beq(T7, T6, "sio_set_r1"); emitter.nop
        emitter.ori(T6, ZERO, 0x52); emitter.beq(T7, T6, "sio_set_r1"); emitter.nop
        emitter.ori(T6, ZERO, 0x65); emitter.beq(T7, T6, "sio_set_r1"); emitter.nop
        emitter.ori(T6, ZERO, 0x45); emitter.beq(T7, T6, "sio_set_r1"); emitter.nop

        # L1: 'q', 'Q'
        emitter.ori(T6, ZERO, 0x71); emitter.beq(T7, T6, "sio_set_l1"); emitter.nop
        emitter.ori(T6, ZERO, 0x51); emitter.beq(T7, T6, "sio_set_l1"); emitter.nop

        # R2: 'f', 'F'
        emitter.ori(T6, ZERO, 0x66); emitter.beq(T7, T6, "sio_set_r2"); emitter.nop
        emitter.ori(T6, ZERO, 0x46); emitter.beq(T7, T6, "sio_set_r2"); emitter.nop

        # L2: 'b', 'B'
        emitter.ori(T6, ZERO, 0x62); emitter.beq(T7, T6, "sio_set_l2"); emitter.nop
        emitter.ori(T6, ZERO, 0x42); emitter.beq(T7, T6, "sio_set_l2"); emitter.nop

        # D-pad Up, Down, Left, Right
        emitter.ori(T6, ZERO, 0x75); emitter.beq(T7, T6, "sio_set_up"); emitter.nop
        emitter.ori(T6, ZERO, 0x55); emitter.beq(T7, T6, "sio_set_up"); emitter.nop
        emitter.ori(T6, ZERO, 0x2b); emitter.beq(T7, T6, "sio_set_up"); emitter.nop
        emitter.ori(T6, ZERO, 0x3d); emitter.beq(T7, T6, "sio_set_up"); emitter.nop

        emitter.ori(T6, ZERO, 0x64); emitter.beq(T7, T6, "sio_set_down"); emitter.nop
        emitter.ori(T6, ZERO, 0x44); emitter.beq(T7, T6, "sio_set_down"); emitter.nop
        emitter.ori(T6, ZERO, 0x2d); emitter.beq(T7, T6, "sio_set_down"); emitter.nop

        emitter.ori(T6, ZERO, 0x70); emitter.beq(T7, T6, "sio_set_left"); emitter.nop
        emitter.ori(T6, ZERO, 0x50); emitter.beq(T7, T6, "sio_set_left"); emitter.nop
        emitter.ori(T6, ZERO, 0x5b); emitter.beq(T7, T6, "sio_set_left"); emitter.nop

        emitter.ori(T6, ZERO, 0x6e); emitter.beq(T7, T6, "sio_set_right"); emitter.nop
        emitter.ori(T6, ZERO, 0x4e); emitter.beq(T7, T6, "sio_set_right"); emitter.nop
        emitter.ori(T6, ZERO, 0x5d); emitter.beq(T7, T6, "sio_set_right"); emitter.nop

        emitter.jump("sio_rx_done")

        # SIO Set Handlers
        emitter.label("sio_set_cross")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x4000); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_triangle")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x1000); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_circle")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x2000); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_square")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x8000); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_r1")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0800); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_l1")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0400); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_r2")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0200); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_l2")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0100); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_up")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0010); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_down")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0040); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_left")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0080); emitter.sw(T5, 16, T0); emitter.jump("sio_rx_done")

        emitter.label("sio_set_right")
        emitter.lw(T5, 16, T0); emitter.ori(T5, T5, 0x0020); emitter.sw(T5, 16, T0)

        emitter.label("sio_rx_done")

        # Compute Edge Transitions for Port 0:
        emitter.lw(T5, 16, T0)    # current buttons (0x70000010)
        emitter.lw(T6, 20, T0)    # previous buttons (0x70000014)
        emitter.sw(T5, 20, T0)    # update previous = current
        emitter.nor(T7, T6, ZERO) # ~prev
        emitter.and_(T8, T5, T7)  # newly pressed edges (curr & ~prev)
        emitter.sw(T8, 24, T0)    # store at 0x70000018
        emitter.nor(T7, T5, ZERO) # ~curr
        emitter.and_(T7, T6, T7)  # newly released edges (prev & ~curr)
        emitter.sw(T7, 28, T0)    # store at 0x7000001C

        # Compute Edge Transitions for Port 1:
        emitter.lw(T5, 36, T0) # current buttons (0x70000024)
        emitter.lw(T6, 40, T0) # previous buttons (0x70000028)
        emitter.sw(T5, 40, T0) # update previous = current
        emitter.nor(T7, T6, ZERO)
        emitter.and_(T9, T5, T7)
        emitter.sw(T9, 44, T0) # store at 0x7000002C
        emitter.nor(T7, T5, ZERO)
        emitter.and_(T7, T6, T7)
        emitter.sw(T7, 48, T0) # store at 0x70000030

        # Combine Pressed Edges across both ports for Logging and Actions
        emitter.lw(T8, 24, T0)
        emitter.lw(T6, 44, T0)
        emitter.or_(T8, T8, T6)

        # Check Cross (0x4000)
        emitter.andi(T7, T8, 0x4000)
        emitter.beqz(T7, "chk_btn_triangle")
        emitter.nop
        if !@profile.inline_asm_words.empty?
          emitter.call("Citrine_InlineAsm_Block")
        end
        if @profile.has_audio
          # Toggle audio playback with true pause (2), resume (3), and play (1)
          emitter.lui(T0, 0x7000)
          emitter.lw(T5, 60, T0) # 0x7000003C: 1=playing, 2=paused, 0=stopped
          emitter.ori(T6, ZERO, 1)
          emitter.beq(T5, T6, "audio_pause")
          emitter.nop

          # If paused (2): resume playback from current position
          emitter.ori(T6, ZERO, 2)
          emitter.beq(T5, T6, "audio_resume")
          emitter.nop

          # If stopped (0): start playback from start
          emitter.lui(T0, 0x7000)
          emitter.ori(T5, ZERO, 1)
          emitter.sw(T5, 60, T0)
          emitter.li(A0, 1) # cmd 1 = Play
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.jump("audio_done")

          emitter.label("audio_resume")
          emitter.lui(T0, 0x7000)
          emitter.ori(T5, ZERO, 1)
          emitter.sw(T5, 60, T0)
          emitter.li(A0, 3) # cmd 3 = Resume
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.jump("audio_done")

          emitter.label("audio_pause")
          emitter.lui(T0, 0x7000)
          emitter.ori(T5, ZERO, 2)
          emitter.sw(T5, 60, T0)
          emitter.li(A0, 2) # cmd 2 = Pause
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop

          emitter.label("audio_done")
          emitter.lui(T0, 0x7000)
        end

        if addr = @rodata.button_msg_addrs["cross"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Triangle (0x1000)
        emitter.label("chk_btn_triangle")
        emitter.andi(T7, T8, 0x1000)
        emitter.beqz(T7, "chk_btn_circle")
        emitter.nop
        if addr = @rodata.button_msg_addrs["triangle"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Circle (0x2000)
        emitter.label("chk_btn_circle")
        emitter.andi(T7, T8, 0x2000)
        emitter.beqz(T7, "chk_btn_square")
        emitter.nop
        if @profile.has_audio
          emitter.lui(T0, 0x7000)
          emitter.sw(ZERO, 60, T0)
          emitter.sw(ZERO, 0x80, T0)
          emitter.li(T9, PadRuntimePayload::SOUND_STOP_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["circle"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Square (0x8000)
        emitter.label("chk_btn_square")
        emitter.andi(T7, T8, 0x8000)
        emitter.beqz(T7, "chk_btn_r1")
        emitter.nop
        if @profile.has_audio
          # Toggle loop mode (0x70000074)
          emitter.lw(T5, 0x74, T0)
          emitter.xori(T5, T5, 1)
          emitter.sw(T5, 0x74, T0)
        end
        if addr = @rodata.button_msg_addrs["square"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check R1 (0x0800)
        emitter.label("chk_btn_r1")
        emitter.andi(T7, T8, 0x0800)
        emitter.beqz(T7, "chk_btn_l1")
        emitter.nop
        if @profile.has_audio
          # Jump forward 10 seconds (+600 frames)
          emitter.lw(T5, 0x80, T0)
          emitter.addiu(T5, T5, 600)
          emitter.sw(T5, 0x80, T0)

          # Send seek command to S.IRX: target_bank = T5 / frames_per_bank
          emitter.ori(T6, ZERO, @profile.frames_per_bank.to_i)
          emitter.divu(T5, T6)
          emitter.mflo(T1)
          emitter.andi(T1, T1, 0xFFFF)
          emitter.lui(A0, 0x0002)
          emitter.or_(A0, A0, T1)
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["r1"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check L1 (0x0400)
        emitter.label("chk_btn_l1")
        emitter.andi(T7, T8, 0x0400)
        emitter.beqz(T7, "chk_btn_r2")
        emitter.nop
        if @profile.has_audio
          # Jump backward 10 seconds (-600 frames)
          emitter.lw(T5, 0x80, T0)
          emitter.addiu(T5, T5, -600)
          emitter.bgez(T5, "l1_sub_ok")
          emitter.nop
          emitter.move(T5, ZERO)
          emitter.label("l1_sub_ok")
          emitter.sw(T5, 0x80, T0)

          # Send seek command to S.IRX: target_bank = T5 / frames_per_bank
          emitter.ori(T6, ZERO, @profile.frames_per_bank.to_i)
          emitter.divu(T5, T6)
          emitter.mflo(T1)
          emitter.andi(T1, T1, 0xFFFF)
          emitter.lui(A0, 0x0002)
          emitter.or_(A0, A0, T1)
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["l1"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check R2 (0x0200)
        emitter.label("chk_btn_r2")
        emitter.andi(T7, T8, 0x0200)
        emitter.beqz(T7, "chk_btn_l2")
        emitter.nop
        if @profile.has_audio
          # Scrub forward 4 seconds (+240 frames)
          emitter.lw(T5, 0x80, T0)
          emitter.addiu(T5, T5, 240)
          emitter.sw(T5, 0x80, T0)

          # Send seek command to S.IRX: target_bank = T5 / frames_per_bank
          emitter.ori(T6, ZERO, @profile.frames_per_bank.to_i)
          emitter.divu(T5, T6)
          emitter.mflo(T1)
          emitter.andi(T1, T1, 0xFFFF)
          emitter.lui(A0, 0x0002)
          emitter.or_(A0, A0, T1)
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["r2"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check L2 (0x0100)
        emitter.label("chk_btn_l2")
        emitter.andi(T7, T8, 0x0100)
        emitter.beqz(T7, "chk_btn_start")
        emitter.nop
        if @profile.has_audio
          # Scrub backward 4 seconds (-240 frames)
          emitter.lw(T5, 0x80, T0)
          emitter.addiu(T5, T5, -240)
          emitter.bgez(T5, "l2_sub_ok")
          emitter.nop
          emitter.move(T5, ZERO)
          emitter.label("l2_sub_ok")
          emitter.sw(T5, 0x80, T0)

          # Send seek command to S.IRX: target_bank = T5 / frames_per_bank
          emitter.ori(T6, ZERO, @profile.frames_per_bank.to_i)
          emitter.divu(T5, T6)
          emitter.mflo(T1)
          emitter.andi(T1, T1, 0xFFFF)
          emitter.lui(A0, 0x0002)
          emitter.or_(A0, A0, T1)
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["l2"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Start (0x0008)
        emitter.label("chk_btn_start")
        emitter.andi(T7, T8, 0x0008)
        emitter.beqz(T7, "chk_btn_select")
        emitter.nop
        if addr = @rodata.button_msg_addrs["start"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Select (0x0001)
        emitter.label("chk_btn_select")
        emitter.andi(T7, T8, 0x0001)
        emitter.beqz(T7, "chk_btn_up")
        emitter.nop
        if addr = @rodata.button_msg_addrs["select"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Up (0x0010)
        emitter.label("chk_btn_up")
        emitter.andi(T7, T8, 0x0010)
        emitter.beqz(T7, "chk_btn_right")
        emitter.nop
        if @profile.has_audio
          # Volume +16
          emitter.lw(T5, 0x70, T0)
          emitter.addiu(T5, T5, 16)
          emitter.ori(T6, ZERO, 255)
          emitter.sltu(T7, T6, T5)
          emitter.beqz(T7, "vol_up_store")
          emitter.nop
          emitter.ori(T5, ZERO, 255)
          emitter.label("vol_up_store")
          emitter.sw(T5, 0x70, T0)
          emitter.andi(A0, T5, 0xFF)
          emitter.ori(A0, A0, 0x1000) # cmd 0x1000 | vol
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["up"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Right (0x0020)
        emitter.label("chk_btn_right")
        emitter.andi(T7, T8, 0x0020)
        emitter.beqz(T7, "chk_btn_down")
        emitter.nop
        if @profile.has_audio
          # Next Track
          emitter.lw(T5, 0x78, T0) # track_idx
          emitter.addiu(T5, T5, 1)
          emitter.lw(T6, 0x7C, T0) # total_tracks
          emitter.sltu(T7, T5, T6)
          emitter.bnez(T7, "next_trk_ok")
          emitter.nop
          emitter.move(T5, ZERO)
          emitter.label("next_trk_ok")
          emitter.sw(T5, 0x78, T0)
          if @profile.phases.size > 1
            emitter.ori(T6, ZERO, @profile.phases.size)
            emitter.divu(T5, T6)
            emitter.mfhi(T7)
            emitter.sw(T7, 8, T0)
          end
          emitter.sw(ZERO, 0x80, T0) # reset elapsed_sec
          emitter.ori(T6, ZERO, 1)
          emitter.sw(T6, 60, T0)   # audio_status = 1 (playing)
          emitter.lw(A0, 0x78, T0) # track_idx
          emitter.andi(A0, A0, 0xFF)
          emitter.ori(A0, A0, 0x0100) # cmd = 0x0100 | track_idx
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["right"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Down (0x0040)
        emitter.label("chk_btn_down")
        emitter.andi(T7, T8, 0x0040)
        emitter.beqz(T7, "chk_btn_left")
        emitter.nop
        if @profile.has_audio
          # Volume -16
          emitter.lw(T5, 0x70, T0)
          emitter.addiu(T5, T5, -16)
          emitter.bgez(T5, "vol_down_store")
          emitter.nop
          emitter.move(T5, ZERO)
          emitter.label("vol_down_store")
          emitter.sw(T5, 0x70, T0)
          emitter.andi(A0, T5, 0xFF)
          emitter.ori(A0, A0, 0x1000) # cmd 0x1000 | vol
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["down"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check Left (0x0080)
        emitter.label("chk_btn_left")
        emitter.andi(T7, T8, 0x0080)
        emitter.beqz(T7, "chk_btn_l3")
        emitter.nop
        if @profile.has_audio
          # Previous Track
          emitter.lw(T5, 0x78, T0) # track_idx
          emitter.lw(T6, 0x7C, T0) # total_tracks
          emitter.bnez(T5, "prev_trk_dec")
          emitter.nop
          emitter.move(T5, T6)
          emitter.label("prev_trk_dec")
          emitter.addiu(T5, T5, -1)
          emitter.sw(T5, 0x78, T0)
          if @profile.phases.size > 1
            emitter.ori(T6, ZERO, @profile.phases.size)
            emitter.divu(T5, T6)
            emitter.mfhi(T7)
            emitter.sw(T7, 8, T0)
          end
          emitter.sw(ZERO, 0x80, T0) # reset elapsed_sec
          emitter.ori(T6, ZERO, 1)
          emitter.sw(T6, 60, T0)   # audio_status = 1 (playing)
          emitter.lw(A0, 0x78, T0) # track_idx
          emitter.andi(A0, A0, 0xFF)
          emitter.ori(A0, A0, 0x0100) # cmd = 0x0100 | track_idx
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end
        if addr = @rodata.button_msg_addrs["left"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check L3 (0x0002)
        emitter.label("chk_btn_l3")
        emitter.andi(T7, T8, 0x0002)
        emitter.beqz(T7, "chk_btn_r3")
        emitter.nop
        if addr = @rodata.button_msg_addrs["l3"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end
        emitter.lw(T8, 24, T0); emitter.lw(T6, 44, T0); emitter.or_(T8, T8, T6)

        # Check R3 (0x0004)
        emitter.label("chk_btn_r3")
        emitter.andi(T7, T8, 0x0004)
        emitter.beqz(T7, "btn_chk_done")
        emitter.nop
        if addr = @rodata.button_msg_addrs["r3"]?
          emitter.li(A0, addr)
          emitter.call("debug_puts")
          emitter.lui(T0, 0x7000)
        end

        emitter.label("btn_chk_done")
        emitter.lui(T0, 0x7000)

        # -------------------------------------------------------------
        # 4. General Phase Sequencing
        # -------------------------------------------------------------
        phases = @profile.phases
        if @profile.is_animated
          if @profile.has_audio
            emitter.lw(T5, 60, T0)
            emitter.beqz(T5, "skip_phase_advance")
            emitter.nop
          end
          emitter.lw(T2, 8, T0) # phase_index
          emitter.addiu(T2, T2, 1)
          emitter.ori(T3, ZERO, phases.size)
          emitter.sltu(T4, T2, T3)
          emitter.bnez(T4, "store_phase_index")
          emitter.nop
          emitter.move(T2, ZERO)
          emitter.label("store_phase_index")
          emitter.sw(T2, 8, T0)
          if @profile.has_audio
            emitter.label("skip_phase_advance")
          end
        elsif phases.size > 1 && !@profile.has_audio
          # Check Triangle (0x1000): reset to phase 0
          emitter.lw(T5, 24, T0)
          emitter.lw(T6, 44, T0)
          emitter.or_(T5, T5, T6)
          emitter.andi(T7, T5, 0x1000)
          emitter.beqz(T7, "chk_sq_retreat")
          emitter.nop
          emitter.sw(ZERO, 8, T0)
          emitter.ori(T2, ZERO, 0)
          emitter.jump("apply_phase_update")

          emitter.label("chk_sq_retreat")
          # Check Square (0x8000): retreat / cycle backward
          emitter.andi(T7, T5, 0x8000)
          emitter.beqz(T7, "chk_r1_advance")
          emitter.nop
          emitter.lw(T2, 8, T0)
          emitter.beqz(T2, "sq_wrap_max")
          emitter.nop
          emitter.addiu(T2, T2, -1)
          emitter.jump("phase_in_range")
          emitter.label("sq_wrap_max")
          emitter.ori(T2, ZERO, phases.size - 1)
          emitter.jump("phase_in_range")

          emitter.label("chk_r1_advance")
          # Check R1 (0x0800): stress test (phase 2) if available
          emitter.andi(T7, T5, 0x0800)
          emitter.beqz(T7, "chk_cross_advance")
          emitter.nop
          if phases.size > 2
            emitter.ori(T2, ZERO, 2)
            emitter.sw(T2, 8, T0)
            emitter.jump("apply_phase_update")
          else
            emitter.jump("advance_phase")
          end

          emitter.label("chk_cross_advance")
          # Check Cross (0x4000): advance
          emitter.andi(T7, T5, 0x4000)
          emitter.bnez(T7, "advance_phase")
          emitter.nop

          # Delay timer countdown
          emitter.lw(T4, 12, T0)
          emitter.beqz(T4, "loop_continue")
          emitter.nop
          emitter.addiu(T4, T4, -1)
          emitter.sw(T4, 12, T0)
          emitter.bnez(T4, "loop_continue")
          emitter.nop

          # Advance phase
          emitter.label("advance_phase")
          emitter.lw(T2, 8, T0)
          emitter.addiu(T2, T2, 1)
          emitter.ori(T3, ZERO, phases.size)
          emitter.bne(T2, T3, "phase_in_range")
          emitter.nop
          emitter.ori(T2, ZERO, @profile.loop_start_phase)

          emitter.label("phase_in_range")
          emitter.sw(T2, 8, T0)

          emitter.label("apply_phase_update")
          phases.each_with_index do |phase, i|
            if i < phases.size - 1
              emitter.ori(T3, ZERO, i)
              emitter.bne(T2, T3, "check_delay_#{i + 1}")
              emitter.nop
            end
            if msg_addr = @rodata.phase_msg_addrs[i]?
              emitter.li(A0, msg_addr)
              emitter.call("debug_puts")
              emitter.lui(T0, 0x7000)
            end
            emitter.li(T4, phase.delay_frames)
            emitter.sw(T4, 12, T0)
            if i < phases.size - 1
              emitter.jump("loop_continue")
              emitter.label("check_delay_#{i + 1}")
            end
          end

          emitter.label("loop_continue")
        end

        # Loop
        emitter.jump("frame_loop")

        # -------------------------------------------------------------
        # 5. Runtime Subroutines & Native Stubs
        # -------------------------------------------------------------
        RuntimeSubroutines.emit_dma02_wait(emitter)
        RuntimeSubroutines.emit_dma_reset(emitter)
        RuntimeSubroutines.emit_debug_puts(emitter)
        RuntimeSubroutines.emit_native_stubs(emitter, @profile, @rodata.digit_table_addr)
        RuntimeSubroutines.emit_inline_asm(emitter, @profile.inline_asm_words)
        RuntimeSubroutines.emit_digit_quad_updater(emitter, @rodata.digit_table_addr)

        # -------------------------------------------------------------
        # 6. Compiled Bytecode Functions (if CBC provided)
        # -------------------------------------------------------------
        if compiler = @mips_compiler
          compiler.compile_all(emitter, @rodata)
        end

        # Ensure citrine_func_table label exists
        unless emitter.labels.has_key?("citrine_func_table")
          emitter.label("citrine_func_table")
          emitter.jr(RA)
          emitter.nop
        end

        # Optimize branch delay slots across the entire EE .text segment (DISABLED: corrupts embedded strings and table alignment)
        # emitter.optimize_delay_slots!

        # Pad .text to 16-byte boundary (at least TEXT_SIZE)
        curr_bytes = emitter.words.size * 4
        target_size = {TEXT_SIZE.to_i32, ((curr_bytes + 15) & ~15)}.max
        emitter.pad_to(target_size)
        emitter.resolve!
        {emitter.to_slice, emitter}
      end
    end
  end
end
