require "../mips/mips_emitter"
require "./phase_extractor"
require "./rodata_segment_builder"
require "./runtime_subroutines"
require "./pad_runtime_payload"

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

      def self.build(profile : ProgramProfile, rodata : RodataResult) : Tuple(Bytes, MipsEmitter)
        builder = new(profile, rodata)
        builder.build
      end

      def initialize(@profile : ProgramProfile, @rodata : RodataResult)
      end

      def build : Tuple(Bytes, MipsEmitter)
        emitter = MipsEmitter.new

        # -------------------------------------------------------------
        # 1. Entry Point: _start
        # -------------------------------------------------------------
        emitter.label("_start")
        emitter.lui(SP, 0x01FF)
        emitter.ori(SP, SP, 0xFFF0) # Stack top: 0x01FFFFF0

        emitter.lui(T0, 0x7000)      # SPRAM base: 0x70000000

        # Zero out 16KB SPRAM (0x70000000 .. 0x70003FFF)
        emitter.move(T1, ZERO)
        emitter.ori(T2, ZERO, 4096)  # 4096 words = 16384 bytes
        emitter.label("spram_clear_loop")
        emitter.sw(ZERO, 0, T0)
        emitter.addiu(T0, T0, 4)
        emitter.addiu(T1, T1, 1)
        emitter.bne(T1, T2, "spram_clear_loop")
        emitter.nop

        emitter.lui(T0, 0x7000)

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

        # DVD Screensaver state initialization
        if @profile.is_dvd_screensaver
          emitter.ori(T1, ZERO, 1)
          emitter.sw(T1, 0x90, T0)      # logo_count = 1 at 0x70000090
          emitter.sw(ZERO, 0x94, T0)    # debounce = 0   at 0x70000094
          emitter.ori(T1, ZERO, 42)
          emitter.sw(T1, 0x98, T0)      # rng_seed = 42  at 0x70000098

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
        end

        # Initialize DualShock 2 Pad Driver & Sound Driver in IOP
        emitter.li(T9, PadRuntimePayload::INIT_ENTRY)
        emitter.jalr(T9)
        emitter.nop

        # Audio state initialization
        if @profile.has_audio
          emitter.lui(T0, 0x7000)
          emitter.ori(T1, ZERO, 1)
          emitter.sw(T1, 60, T0)      # 0x7000003C: audio playing flag = 1
          emitter.ori(T1, ZERO, 240)
          emitter.sw(T1, 0x70, T0)    # 0x70000070: master_vol = 240
          emitter.ori(T1, ZERO, 1)
          emitter.sw(T1, 0x74, T0)    # 0x70000074: is_looping = 1 (ON)
          emitter.sw(ZERO, 0x78, T0)  # 0x70000078: track_idx = 0
          emitter.ori(T1, ZERO, 13)
          emitter.sw(T1, 0x7C, T0)    # 0x7000007C: total_tracks = 13
          emitter.sw(ZERO, 0x80, T0)  # 0x70000080: elapsed_sec = 0

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

        # Debounce counter decrement for dynamic apps (DVD screensaver)
        if @profile.is_dvd_screensaver
          emitter.lw(T3, 0x94, T0)
          emitter.beqz(T3, "dvd_debounce_ok")
          emitter.nop
          emitter.addiu(T3, T3, -1)
          emitter.sw(T3, 0x94, T0)
          emitter.label("dvd_debounce_ok")
        end

        # Render Primary Phase Draw Packet
        if @profile.is_dvd_screensaver
          emitter.dma02_kick(@rodata.static_dvd_addr, @rodata.static_dvd_qwc)
        elsif @rodata.phase_addrs.empty?
          # No draw packets
        elsif @rodata.phase_addrs.size == 1
          emitter.dma02_kick(@rodata.phase_addrs[0], @rodata.phase_qwcs[0])
        elsif @profile.is_animated && @rodata.phase_table_addr > 0
          emitter.lw(T2, 8, T0) # phase index
          emitter.sll(T3, T2, 3) # phase_index * 8
          emitter.li(T8, @rodata.phase_table_addr)
          emitter.addu(T8, T8, T3)
          emitter.lw(T7, 0, T8) # MADR
          emitter.lw(T6, 4, T8) # QWC

          if @profile.has_audio
            # Update elapsed frames if playing (0x7000003C == 1)
            emitter.lw(T5, 60, T0)
            emitter.ori(T4, ZERO, 1)
            emitter.bne(T5, T4, "skip_elapsed_inc")
            emitter.nop

            # Check if fast-forwarding (R2 held) or rewinding (L2 held)
            emitter.lw(T4, 16, T0) # port 0 current buttons
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
          end

          if @rodata.scrubber_present
            # Update progress scrubber quad XYZ2 at uncached MADR + scrub_quad_offset + 48
            emitter.lui(T4, 0x2000)
            emitter.or_(T4, T7, T4)
            emitter.li(T3, @rodata.scrub_quad_offset + 48_u32)
            emitter.addu(T4, T4, T3)
            emitter.lw(T1, 0, T4)
            emitter.srl(T2, T1, 16)
            emitter.ori(T3, ZERO, (@rodata.scrub_y2.to_i32 << 4))
            emitter.bne(T2, T3, "skip_scrub_update")
            emitter.nop
            # scrub_x = min_x + (elapsed_frames / 16), clamped to max_x
            emitter.lw(T5, 0x80, T0)
            emitter.srl(T2, T5, 4)
            emitter.addiu(T2, T2, @rodata.scrub_min_x.to_i32)
            emitter.ori(T3, ZERO, @rodata.scrub_max_x.to_i32)
            emitter.sltu(T1, T3, T2)
            emitter.beqz(T1, "scrub_clamp_ok")
            emitter.nop
            emitter.ori(T2, ZERO, @rodata.scrub_max_x.to_i32)
            emitter.label("scrub_clamp_ok")
            emitter.sll(T2, T2, 4)
            emitter.lui(T3, (@rodata.scrub_y2.to_i32 << 4))
            emitter.or_(T3, T3, T2)
            emitter.sw(T3, 0, T4)
            emitter.label("skip_scrub_update")
          end

          # Live Dynamic Time Digits (MM:SS) in uncached GIF packet RAM
          if @rodata.time_text_present
            emitter.lui(T0, 0x7000)
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

            # S6 = uncached GIF packet base (0x20000000 | T7)
            emitter.lui(S6, 0x2000)
            emitter.or_(S6, T7, S6)
            emitter.ori(A3, ZERO, @rodata.time_text_scale == 2 ? 1 : 0)

            # Digit 0: Minute tens
            emitter.move(A0, S2)
            emitter.li(A1, @rodata.min_tens_pos)
            emitter.li(T1, @rodata.min_tens_offset)
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 1: Minute ones
            emitter.move(A0, S3)
            emitter.li(A1, @rodata.min_ones_pos)
            emitter.li(T1, @rodata.min_ones_offset)
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 2: Second tens
            emitter.move(A0, S4)
            emitter.li(A1, @rodata.sec_tens_pos)
            emitter.li(T1, @rodata.sec_tens_offset)
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            # Digit 3: Second ones
            emitter.move(A0, S5)
            emitter.li(A1, @rodata.sec_ones_pos)
            emitter.li(T1, @rodata.sec_ones_offset)
            emitter.addu(A2, S6, T1)
            emitter.call("update_digit_quads")

            emitter.lui(T0, 0x7000)
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

          emitter.dma02_kick_reg(T7, T6)
        else
          # Multi-phase branch lookup
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
              emitter.jump("send_primary_dma")
              emitter.label("check_phase_#{i + 1}")
            end
          end
          emitter.label("send_primary_dma")
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
        emitter.lw(T5, 16, T0)       # current buttons (0x70000010)
        emitter.lw(T6, 20, T0)       # previous buttons (0x70000014)
        emitter.sw(T5, 20, T0)       # update previous = current
        emitter.nor(T7, T6, ZERO)    # ~prev
        emitter.and_(T8, T5, T7)     # newly pressed edges (curr & ~prev)
        emitter.sw(T8, 24, T0)       # store at 0x70000018
        emitter.nor(T7, T5, ZERO)    # ~curr
        emitter.and_(T7, T6, T7)     # newly released edges (prev & ~curr)
        emitter.sw(T7, 28, T0)       # store at 0x7000001C

        # Compute Edge Transitions for Port 1:
        emitter.lw(T5, 36, T0)       # current buttons (0x70000024)
        emitter.lw(T6, 40, T0)       # previous buttons (0x70000028)
        emitter.sw(T5, 40, T0)       # update previous = current
        emitter.nor(T7, T6, ZERO)
        emitter.and_(T9, T5, T7)
        emitter.sw(T9, 44, T0)       # store at 0x7000002C
        emitter.nor(T7, T5, ZERO)
        emitter.and_(T7, T6, T7)
        emitter.sw(T7, 48, T0)       # store at 0x70000030

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
          emitter.lw(T5, 0x78, T0)    # track_idx
          emitter.addiu(T5, T5, 1)
          emitter.lw(T6, 0x7C, T0)    # total_tracks
          emitter.sltu(T7, T5, T6)
          emitter.bnez(T7, "next_trk_ok")
          emitter.nop
          emitter.move(T5, ZERO)
          emitter.label("next_trk_ok")
          emitter.sw(T5, 0x78, T0)
          emitter.sw(ZERO, 0x80, T0)  # reset elapsed_sec
          emitter.ori(T5, ZERO, 1)
          emitter.sw(T5, 60, T0)
          emitter.li(A0, 1)           # restart audio playback
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
          emitter.lw(T5, 0x78, T0)    # track_idx
          emitter.lw(T6, 0x7C, T0)    # total_tracks
          emitter.bnez(T5, "prev_trk_dec")
          emitter.nop
          emitter.move(T5, T6)
          emitter.label("prev_trk_dec")
          emitter.addiu(T5, T5, -1)
          emitter.sw(T5, 0x78, T0)
          emitter.sw(ZERO, 0x80, T0)  # reset elapsed_sec
          emitter.ori(T5, ZERO, 1)
          emitter.sw(T5, 60, T0)
          emitter.li(A0, 1)           # restart audio playback
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
        if @profile.is_dvd_screensaver
          # --- DVD BUTTONS & LOGO MANAGEMENT ---
          emitter.lw(T5, 24, T0) # T5 = pressed edges (0x70000018)
          emitter.lw(T6, 44, T0) # port 1 pressed edges
          emitter.or_(T5, T5, T6)
          emitter.lw(T4, 0x90, T0) # T4 = logo_count    (0x70000090)
          emitter.lw(T3, 0x94, T0) # T3 = debounce      (0x70000094)

          # 1. Triangle (0x1000): reset to 1 logo
          emitter.andi(T7, T5, 0x1000)
          emitter.beqz(T7, "dvd_chk_r1")
          emitter.nop
          emitter.bnez(T3, "dvd_buttons_done")
          emitter.nop
          emitter.ori(T4, ZERO, 1)
          emitter.sw(T4, 0x90, T0) # logo_count = 1
          emitter.ori(T3, ZERO, 12)
          emitter.sw(T3, 0x94, T0) # debounce = 12
          emitter.j("dvd_buttons_done")
          emitter.nop

          emitter.label("dvd_chk_r1")
          # 2. R1 (0x0800): stress test - spawn 10 logos
          emitter.andi(T7, T5, 0x0800)
          emitter.beqz(T7, "dvd_chk_cross")
          emitter.nop
          emitter.bnez(T3, "dvd_buttons_done")
          emitter.nop
          emitter.ori(S4, ZERO, 10)
          emitter.j("dvd_spawn_batch")
          emitter.nop

          emitter.label("dvd_chk_cross")
          # 3. Cross (0x4000): spawn 1 logo
          emitter.andi(T7, T5, 0x4000)
          emitter.beqz(T7, "dvd_buttons_done")
          emitter.nop
          emitter.bnez(T3, "dvd_buttons_done")
          emitter.nop
          emitter.ori(S4, ZERO, 1)

          emitter.label("dvd_spawn_batch")
          emitter.ori(T3, ZERO, 12)
          emitter.sw(T3, 0x94, T0) # debounce = 12

          emitter.label("dvd_spawn_one")
          emitter.lui(T0, 0x7000)
          emitter.lw(T4, 0x90, T0) # logo_count
          emitter.sltiu(T7, T4, 16)
          emitter.beqz(T7, "dvd_buttons_done")
          emitter.nop

          # Calculate slot address in SPRAM: 0x70000100 + (logo_count * 24)
          emitter.sll(S1, T4, 4) # T4 * 16
          emitter.sll(S2, T4, 3) # T4 * 8
          emitter.addu(S1, S1, S2)
          emitter.addiu(S1, S1, 0x0100)
          emitter.addu(S0, T0, S1) # S0 = new logo SPRAM address

          # rx = rng.next_int(40, 400)
          emitter.ori(A0, ZERO, 40)
          emitter.ori(A1, ZERO, 400)
          emitter.call("rng_next_int")
          emitter.sw(V0, 0, S0)

          # ry = rng.next_int(40, 320)
          emitter.ori(A0, ZERO, 40)
          emitter.ori(A1, ZERO, 320)
          emitter.call("rng_next_int")
          emitter.sw(V0, 4, S0)

          # dir_x: rng_next_int(0, 1) == 0 ? -3 : 3
          emitter.ori(A0, ZERO, 0)
          emitter.ori(A1, ZERO, 1)
          emitter.call("rng_next_int")
          emitter.ori(T6, ZERO, 3)
          emitter.bnez(V0, "dvd_dir_x_set")
          emitter.nop
          emitter.subu(T6, ZERO, T6) # T6 = -3
          emitter.label("dvd_dir_x_set")
          emitter.sw(T6, 8, S0)

          # dir_y: rng_next_int(0, 1) == 0 ? -2 : 2
          emitter.ori(A0, ZERO, 0)
          emitter.ori(A1, ZERO, 1)
          emitter.call("rng_next_int")
          emitter.ori(T6, ZERO, 2)
          emitter.bnez(V0, "dvd_dir_y_set")
          emitter.nop
          emitter.subu(T6, ZERO, T6) # T6 = -2
          emitter.label("dvd_dir_y_set")
          emitter.sw(T6, 12, S0)

          # rt_col = rng_next_int(0, 5)
          emitter.ori(A0, ZERO, 0)
          emitter.ori(A1, ZERO, 5)
          emitter.call("rng_next_int")
          emitter.move(S2, V0)
          emitter.sw(S2, 16, S0) # text_color_idx

          # bg_step = rng_next_int(1, 5) -> rbg_col = (rt_col + bg_step) % 6
          emitter.ori(A0, ZERO, 1)
          emitter.ori(A1, ZERO, 5)
          emitter.call("rng_next_int")
          emitter.addu(S2, S2, V0)
          emitter.ori(T6, ZERO, 6)
          emitter.divu(S2, T6)
          emitter.mfhi(S2)
          emitter.sw(S2, 20, S0) # bg_color_idx

          # logo_count++
          emitter.lui(T0, 0x7000)
          emitter.lw(T4, 0x90, T0)
          emitter.addiu(T4, T4, 1)
          emitter.sw(T4, 0x90, T0)

          emitter.addiu(S4, S4, -1)
          emitter.bnez(S4, "dvd_spawn_one")
          emitter.nop

          emitter.label("dvd_buttons_done")

          # --- DVD PHYSICS UPDATE FOR ALL LOGOS ---
          emitter.lui(T0, 0x7000)
          emitter.lw(S6, 0x90, T0) # S6 = logo_count
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
          emitter.call("rng_next_int")
          emitter.lui(T0, 0x7000)
          emitter.lw(T5, 16, S0) # old text_color_idx
          emitter.addu(T5, T5, V0)
          emitter.ori(T6, ZERO, 6)
          emitter.divu(T5, T6)
          emitter.mfhi(T5)
          emitter.sw(T5, 16, S0) # new text_color_idx

          emitter.ori(A0, ZERO, 1)
          emitter.ori(A1, ZERO, 5)
          emitter.call("rng_next_int")
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
          emitter.lw(S6, 0x90, T0) # S6 = logo_count
          emitter.move(S7, ZERO)   # S7 = logo index (0 .. logo_count - 1)

          emitter.label("dvd_draw_logo_loop")
          emitter.sll(S1, S7, 4)
          emitter.sll(S2, S7, 3)
          emitter.addu(S1, S1, S2)
          emitter.addiu(S1, S1, 0x0100)
          emitter.addu(A1, T0, S1) # A1 = logo struct address

          emitter.lw(T1, 0, A1)  # px
          emitter.lw(T2, 4, A1)  # py
          emitter.lw(T3, 16, A1) # txt_col
          emitter.lw(T4, 20, A1) # bg_col

          # Load bg_rgba into S2
          emitter.li(A2, @rodata.color_palette_addr)
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
          emitter.call("emit_quad_s0")

          # 2. Inner border: (px + 2, py + 2, px + 188, py + 42), color = black_rgba (S4)
          emitter.addiu(A0, T1, 2)
          emitter.addiu(A1, T2, 2)
          emitter.addiu(A2, T1, 188)
          emitter.addiu(A3, T2, 42)
          emitter.move(T4, S4)
          emitter.call("emit_quad_s0")

          # 3. Inner rect: (px + 4, py + 4, px + 186, py + 40), color = bg_rgba (S2)
          emitter.addiu(A0, T1, 4)
          emitter.addiu(A1, T2, 4)
          emitter.addiu(A2, T1, 186)
          emitter.addiu(A3, T2, 40)
          emitter.move(T4, S2)
          emitter.call("emit_quad_s0")

          # 4. Text Quads (111 quads)
          # S1 = px + 16 (Origin X)
          # FP = py + 12 (Origin Y)
          emitter.addiu(S1, T1, 16)
          emitter.addiu(FP, T2, 12)

          # Store font_quad_addr in SPRAM at 0x7000009C
          emitter.li(T5, @rodata.font_quad_addr)
          emitter.lui(T0, 0x7000)
          emitter.sw(T5, 0x9C, T0)

          emitter.ori(S5, ZERO, @rodata.font_quad_count.to_i32) # loop counter

          emitter.label("dvd_glyph_loop")
          emitter.lui(T0, 0x7000)
          emitter.lw(T5, 0x9C, T0)
          emitter.lbu(T6, 0, T5) # dx1
          emitter.lbu(T7, 1, T5) # dy1
          emitter.lbu(T8, 2, T5) # dx2
          emitter.lbu(T9, 3, T5) # dy2
          emitter.addiu(T5, T5, 4)
          emitter.sw(T5, 0x9C, T0)

          emitter.addu(A0, S1, T6) # x1
          emitter.addu(A1, FP, T7) # y1
          emitter.addu(A2, S1, T8) # x2
          emitter.addu(A3, FP, T9) # y2
          emitter.move(T4, S3)     # txt_rgba

          emitter.call("emit_quad_s0")

          emitter.addiu(S5, S5, -1)
          emitter.bnez(S5, "dvd_glyph_loop")
          emitter.nop

          # Next logo
          emitter.lui(T0, 0x7000)
          emitter.lw(S6, 0x90, T0)
          emitter.addiu(S7, S7, 1)
          emitter.bne(S7, S6, "dvd_draw_logo_loop")
          emitter.nop

          # --- WRITE GIFTAG AND KICK DMA CHANNEL 2 ---
          # total_items = logo_count * (@rodata.font_quad_count + 3) * 4
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x90, T0)
          emitter.ori(T2, ZERO, ((@rodata.font_quad_count.to_i32 + 3) * 4))
          emitter.multu(T1, T2)
          emitter.mflo(T1) # T1 = total_items

          # GIFTag at 0x20210000:
          emitter.lui(T0, 0x2021)
          emitter.lui(T2, 0x1000)
          emitter.dsll32(T2, T2, 0)     # bit 60 PRE = 1
          emitter.ori(T3, ZERO, 0x8000) # bit 15 EOP = 1
          emitter.or_(T2, T2, T3)
          emitter.andi(T3, T1, 0x7FFF)
          emitter.or_(T2, T2, T3)
          emitter.sd(T2, 0, T0)
          emitter.ori(T3, ZERO, 0x0E)
          emitter.sd(T3, 8, T0)

          # Kick DMA channel 2:
          emitter.call("dma02_wait")
          emitter.lui(T8, 0x1000)
          emitter.ori(T8, T8, 0xa000)
          emitter.lui(T7, 0x0021)
          emitter.sw(T7, 0x10, T8) # D2_MADR = 0x00210000
          emitter.addiu(T6, T1, 1) # D2_QWC = total_items + 1
          emitter.sw(T6, 0x20, T8)
          emitter.ori(T5, ZERO, 0x101)
          emitter.sw(T5, 0x00, T8)
          emitter.call("dma02_wait")

          # Clear current buttons at 0x70000010:
          emitter.lui(T0, 0x7000)
          emitter.sw(ZERO, 16, T0)

          emitter.jump("frame_loop")
        elsif @profile.is_animated
          if @profile.has_audio
            emitter.lw(T5, 60, T0)
            emitter.beqz(T5, "skip_phase_advance")
            emitter.nop
          end
          emitter.lw(T2, 8, T0)    # phase_index
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
        elsif phases.size > 1
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
        RuntimeSubroutines.emit_native_stubs(emitter)
        RuntimeSubroutines.emit_inline_asm(emitter, @profile.inline_asm_words)
        RuntimeSubroutines.emit_digit_quad_updater(emitter, @rodata.digit_table_addr)
        if @profile.is_dvd_screensaver
          RuntimeSubroutines.emit_rng_next_int(emitter)
          RuntimeSubroutines.emit_quad_s0(emitter)
        end

        # Pad .text to 16,384 bytes
        emitter.pad_to(TEXT_SIZE.to_i32)
        emitter.resolve!
        {emitter.to_slice, emitter}
      end
    end
  end
end
