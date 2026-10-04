require "../gs/gif_packet_builder"
require "./phase_extractor"

module Citrine
  module ISO
    record VirtualInput, start_frame : UInt32, duration_frames : UInt16, button_mask : UInt16, port : UInt8 = 0_u8

    # Encapsulates the assembled .rodata segment and symbol addresses
    struct RodataResult
      property data : Bytes
      property env_packet_addr : UInt32
      property env_packet_qwc : UInt16
      property phase_addrs : Array(UInt32)
      property phase_qwcs : Array(UInt16)
      property phase_table_addr : UInt32
      property sched_addr : UInt32
      property banner_addr : UInt32
      property boot_msg_addrs : Array(UInt32)
      property button_msg_addrs : Hash(String, UInt32)
      property phase_msg_addrs : Hash(Int32, UInt32)

      def initialize(
        @data = Bytes.empty,
        @env_packet_addr = 0_u32,
        @env_packet_qwc = 0_u16,
        @phase_addrs = [] of UInt32,
        @phase_qwcs = [] of UInt16,
        @phase_table_addr = 0_u32,
        @sched_addr = 0_u32,
        @banner_addr = 0_u32,
        @boot_msg_addrs = [] of UInt32,
        @button_msg_addrs = Hash(String, UInt32).new,
        @phase_msg_addrs = Hash(Int32, UInt32).new
      )
      end
    end

    # Builds the standard PlayStation 2 .rodata segment containing GS packets,
    # virtual input schedules, and string tables.
    class RodataSegmentBuilder
      alias GifPacketBuilder = Citrine::GS::GifPacketBuilder
      alias Phase = Citrine::GS::Phase

      RODATA_VADDR = 0x00500000_u32

      def self.build(profile : ProgramProfile, input_schedule : Array(VirtualInput) = [] of VirtualInput) : RodataResult
        builder = new(profile, input_schedule)
        builder.build
      end

      getter profile : ProgramProfile
      getter input_schedule : Array(VirtualInput)

      def initialize(@profile : ProgramProfile, @input_schedule : Array(VirtualInput) = [] of VirtualInput)
      end

      def build : RodataResult
        out_mem = IO::Memory.new
        curr_addr = RODATA_VADDR

        # 1. GS Environment Setup Packet
        env_packet = GifPacketBuilder.build_env_packet
        env_packet_addr = curr_addr
        env_packet_qwc = (env_packet.size // 16).to_u16
        out_mem.write(env_packet)
        curr_addr += env_packet.size.to_u32

        # 2. Primary Phase Draw Packets
        phase_addrs = [] of UInt32
        phase_qwcs = [] of UInt16

        @profile.phases.each do |phase|
          pkt = GifPacketBuilder.build_draw_packet(phase.commands)
          phase_addrs << curr_addr
          phase_qwcs << (pkt.size // 16).to_u16
          out_mem.write(pkt)
          curr_addr += pkt.size.to_u32
        end

        # 3. Phase Lookup Table (for multi-phase and animated programs)
        phase_table_addr = 0_u32
        if @profile.phases.size > 1
          phase_table_addr = curr_addr
          pt_mem = IO::Memory.new
          phase_addrs.each_with_index do |addr, i|
            pt_mem.write_bytes(addr, IO::ByteFormat::LittleEndian)
            pt_mem.write_bytes(phase_qwcs[i].to_u32, IO::ByteFormat::LittleEndian)
          end
          pt_pad = (16 - (pt_mem.size % 16)) % 16
          pt_pad.times { pt_mem.write_byte(0_u8) }
          pt_slice = pt_mem.to_slice
          out_mem.write(pt_slice)
          curr_addr += pt_slice.size.to_u32
        end

        # 4. Virtual Input Schedule
        sched_addr = curr_addr
        sched_mem = IO::Memory.new
        @input_schedule.each do |entry|
          sched_mem.write_bytes(entry.start_frame, IO::ByteFormat::LittleEndian)
          sched_mem.write_bytes(entry.button_mask, IO::ByteFormat::LittleEndian)
          sched_mem.write_bytes(entry.duration_frames, IO::ByteFormat::LittleEndian)
          sched_mem.write_byte(entry.port)
          7.times { sched_mem.write_byte(0_u8) }
        end
        # Terminator: start_frame = 0xFFFFFFFF
        sched_mem.write_bytes(0xFFFFFFFF_u32, IO::ByteFormat::LittleEndian)
        12.times { sched_mem.write_byte(0_u8) }
        sched_slice = sched_mem.to_slice
        out_mem.write(sched_slice)
        curr_addr += sched_slice.size.to_u32

        # 5. String Constants
        banner_str = "[CITRINE] PS2 EE Engine Initialized\n\0"
        banner_addr = curr_addr
        out_mem.write(banner_str.to_slice)
        curr_addr += banner_str.bytesize.to_u32

        boot_msg_addrs = [] of UInt32
        @profile.boot_messages.each do |msg|
          boot_msg_addrs << curr_addr
          str = "#{msg}\n\0"
          out_mem.write(str.to_slice)
          curr_addr += str.bytesize.to_u32
        end

        phase_msg_addrs = Hash(Int32, UInt32).new
        @profile.phases.each_with_index do |phase, i|
          if msg = phase.message
            phase_msg_addrs[i] = curr_addr
            str = "#{msg}\n\0"
            out_mem.write(str.to_slice)
            curr_addr += str.bytesize.to_u32
          end
        end

        button_msg_addrs = Hash(String, UInt32).new
        button_defs = [
          {"cross", "[CITRINE] Button Cross (X) pressed!\n\0"},
          {"triangle", "[CITRINE] Button Triangle pressed!\n\0"},
          {"circle", "[CITRINE] Button Circle pressed!\n\0"},
          {"square", "[CITRINE] Button Square pressed!\n\0"},
          {"r1", "[CITRINE] Button R1 pressed!\n\0"},
          {"l1", "[CITRINE] Button L1 pressed!\n\0"},
          {"r2", "[CITRINE] Button R2 pressed!\n\0"},
          {"l2", "[CITRINE] Button L2 pressed!\n\0"},
          {"start", "[CITRINE] Button Start pressed!\n\0"},
          {"select", "[CITRINE] Button Select pressed!\n\0"},
          {"up", "[CITRINE] Button Up pressed!\n\0"},
          {"right", "[CITRINE] Button Right pressed!\n\0"},
          {"down", "[CITRINE] Button Down pressed!\n\0"},
          {"left", "[CITRINE] Button Left pressed!\n\0"},
          {"l3", "[CITRINE] Button L3 pressed!\n\0"},
          {"r3", "[CITRINE] Button R3 pressed!\n\0"},
        ]

        button_defs.each do |name, msg|
          button_msg_addrs[name] = curr_addr
          out_mem.write(msg.to_slice)
          curr_addr += msg.bytesize.to_u32
        end

        out_mem.write("Citrine PS2 Virtual Machine runtime v0.1.0\0".to_slice)
        out_mem.write("Emotion Engine R5900 / Graphic Synthesizer\0".to_slice)

        RodataResult.new(
          data: out_mem.to_slice,
          env_packet_addr: env_packet_addr,
          env_packet_qwc: env_packet_qwc,
          phase_addrs: phase_addrs,
          phase_qwcs: phase_qwcs,
          phase_table_addr: phase_table_addr,
          sched_addr: sched_addr,
          banner_addr: banner_addr,
          boot_msg_addrs: boot_msg_addrs,
          button_msg_addrs: button_msg_addrs,
          phase_msg_addrs: phase_msg_addrs
        )
      end
    end
  end
end
