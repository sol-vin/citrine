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

        # Audio state initialization
        if @profile.has_audio
          emitter.ori(T1, ZERO, 1)
          emitter.sw(T1, 60, T0)      # 0x7000003C: audio playing flag = 1
          emitter.ori(T1, ZERO, 255)
          emitter.sw(T1, 0x70, T0)    # 0x70000070: master_vol = 255

          # Kick off audio playback via Sound IRX RPC
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.ori(A0, ZERO, 1)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
        end

        # Initial phase delay frames at 0x7000000C
        if @profile.phases.size > 0
          init_delay = @profile.phases[0].delay_frames
          emitter.li(T1, init_delay)
          emitter.sw(T1, 12, T0)
        end

        # Initialize DualShock 2 Pad Driver in IOP
        emitter.li(T9, PadRuntimePayload::INIT_ENTRY)
        emitter.jalr(T9)
        emitter.nop

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

        # Syscall 0x02: _SetGsCrt(interlace=0, mode=2 [NTSC], field=1)
        emitter.move(A0, ZERO)
        emitter.ori(A1, ZERO, 2)
        emitter.ori(A2, ZERO, 1)
        emitter.ori(V1, ZERO, 2)
        emitter.syscall_inst
        emitter.nop

        # GS PMODE (0x12000000) = 0xFF62 (EN1, EN2, MMCL=1, ALP=255)
        emitter.lui(T0, 0x1200)
        emitter.lui(T1, 0x0000)
        emitter.ori(T1, T1, 0xFF62)
        emitter.sd(T1, 0, T0)

        # GS DISPFB1 (0x12000070): FBP=0, FBW=10 (640px), PSM=0 (PSMCT32), DBX=0, DBY=0
        emitter.ori(T1, ZERO, 10)
        emitter.sll(T1, T1, 9)
        emitter.sd(T1, 0x70, T0)

        # GS DISPLAY1 (0x12000080): DX=656, DY=36, MAGH=3, MAGV=0, DW=2559, DH=447
        emitter.lui(T1, 0x01bf)
        emitter.ori(T1, T1, 0xcfff)
        emitter.dsll32(T1, T1, 0)
        emitter.lui(T2, 0x0009)
        emitter.ori(T2, T2, 0x0a90)
        emitter.or_(T1, T1, T2)
        emitter.sd(T1, 0x80, T0)

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

        # Render Primary Phase Draw Packet
        if @rodata.phase_addrs.empty?
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
          # Toggle audio playback with true pause (cmd 2), resume (cmd 3), and play (cmd 1)
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
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.ori(A0, ZERO, 1) # cmd 1 = Play
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.ori(T5, ZERO, 1)
          emitter.sw(T5, 60, T0)
          emitter.jump("audio_done")

          emitter.label("audio_resume")
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.ori(A0, ZERO, 3) # cmd 3 = Resume (preserves position, un-mutes pitch/vol)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.ori(T5, ZERO, 1)
          emitter.sw(T5, 60, T0)
          emitter.jump("audio_done")

          emitter.label("audio_pause")
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.ori(A0, ZERO, 2) # cmd 2 = Pause (preserves position, mutes pitch/vol)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.ori(T5, ZERO, 2)
          emitter.sw(T5, 60, T0)
          emitter.label("audio_done")
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
          emitter.li(T9, PadRuntimePayload::SOUND_STOP_ENTRY)
          emitter.jalr(T9)
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.sw(ZERO, 60, T0)
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
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.ori(A0, T5, 0x1000) # cmd = 0x1000 | master_vol
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
          emitter.li(T9, PadRuntimePayload::SOUND_PLAY_ENTRY)
          emitter.ori(A0, T5, 0x1000)
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
          emitter.beqz(T7, "chk_r1_advance")
          emitter.nop
          emitter.sw(ZERO, 8, T0)
          emitter.ori(T2, ZERO, 0)
          emitter.jump("apply_phase_update")

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

        # Pad .text to 16,384 bytes
        emitter.pad_to(TEXT_SIZE.to_i32)
        emitter.resolve!
        {emitter.to_slice, emitter}
      end
    end
  end
end
