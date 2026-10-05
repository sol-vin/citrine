require "../gs/gif_packet_builder"
require "./phase_extractor"

require "./digit_quad_table"

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
      property digit_table_addr : UInt32
      property time_text_present : Bool
      property min_tens_offset : UInt32
      property min_ones_offset : UInt32
      property sec_tens_offset : UInt32
      property sec_ones_offset : UInt32
      property min_tens_pos : UInt32
      property min_ones_pos : UInt32
      property sec_tens_pos : UInt32
      property sec_ones_pos : UInt32
      property scrubber_present : Bool
      property scrub_quad_offset : UInt32
      property scrub_min_x : UInt16
      property scrub_max_x : UInt16
      property scrub_y2 : UInt16
      property frame_text_present : Bool
      property frame_digit_offsets : Array(UInt32)
      property frame_digit_positions : Array(UInt32)
      property frame_text_scale : Int32
      property time_text_scale : Int32
      property static_dvd_addr : UInt32
      property static_dvd_qwc : UInt16
      property font_quad_addr : UInt32
      property font_quad_count : UInt16
      property color_palette_addr : UInt32

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
        @phase_msg_addrs = Hash(Int32, UInt32).new,
        @digit_table_addr = 0_u32,
        @time_text_present = false,
        @min_tens_offset = 0_u32,
        @min_ones_offset = 0_u32,
        @sec_tens_offset = 0_u32,
        @sec_ones_offset = 0_u32,
        @min_tens_pos = 0_u32,
        @min_ones_pos = 0_u32,
        @sec_tens_pos = 0_u32,
        @sec_ones_pos = 0_u32,
        @scrubber_present = false,
        @scrub_quad_offset = 0_u32,
        @scrub_min_x = 62_u16,
        @scrub_max_x = 578_u16,
        @scrub_y2 = 214_u16,
        @frame_text_present = false,
        @frame_digit_offsets = [] of UInt32,
        @frame_digit_positions = [] of UInt32,
        @frame_text_scale = 1,
        @time_text_scale = 1,
        @static_dvd_addr = 0_u32,
        @static_dvd_qwc = 0_u16,
        @font_quad_addr = 0_u32,
        @font_quad_count = 0_u16,
        @color_palette_addr = 0_u32
      )
      end
    end

    # Builds the standard PlayStation 2 .rodata segment containing GS packets,
    # virtual input schedules, and string tables.
    class RodataSegmentBuilder
      alias GifPacketBuilder = Citrine::GS::GifPacketBuilder
      alias Phase = Citrine::GS::Phase
      alias DrawCommand = Citrine::GS::DrawCommand

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

        # 2. DVD Screensaver Static Packets & Font Quads
        static_dvd_addr = 0_u32
        static_dvd_qwc = 0_u16
        font_quad_addr = 0_u32
        font_quad_count = 0_u16
        color_palette_addr = 0_u32

        if @profile.is_dvd_screensaver
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
          out_mem.write(static_dvd_packet)
          curr_addr += static_dvd_packet.size.to_u32

          raw_fq = GifPacketBuilder.extract_text_glyph_quads("HELLO WORLD!", 2)
          fq_pad = (16 - (raw_fq.size % 16)) % 16
          font_quad_count = (raw_fq.size // 4).to_u16
          font_quad_addr = curr_addr
          out_mem.write(raw_fq)
          fq_pad.times { out_mem.write_byte(0_u8) }
          curr_addr += (raw_fq.size + fq_pad).to_u32

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
          out_mem.write(color_palette_slice)
          curr_addr += color_palette_slice.size.to_u32
        end

        # 3. Primary Phase Draw Packets
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

        s1 = "Citrine PS2 Virtual Machine runtime v0.1.0\0"
        s2 = "Emotion Engine R5900 / Graphic Synthesizer\0"
        out_mem.write(s1.to_slice)
        curr_addr += s1.bytesize.to_u32
        out_mem.write(s2.to_slice)
        curr_addr += s2.bytesize.to_u32

        # 6. Scan phase 0 commands to discover dynamic time text and scrubber rect
        digit_table_addr = 0_u32
        time_text_present = false
        min_tens_offset = 0_u32
        min_ones_offset = 0_u32
        sec_tens_offset = 0_u32
        sec_ones_offset = 0_u32
        min_tens_pos = 0_u32
        min_ones_pos = 0_u32
        sec_tens_pos = 0_u32
        sec_ones_pos = 0_u32

        frame_text_present = false
        frame_digit_offsets = [] of UInt32
        frame_digit_positions = [] of UInt32
        frame_text_scale = 1
        time_text_scale = 1

        scrubber_present = false
        scrub_quad_offset = 0_u32
        scrub_min_x = 62_u16
        scrub_max_x = 578_u16
        scrub_y2 = 214_u16

        if first_phase = @profile.phases.first?
          body_pos = 0_u32
          prev_cmd : Citrine::GS::DrawCommand? = nil

          first_phase.commands.each do |cmd|
            r = (cmd.color & 0xFF).to_u8
            g = ((cmd.color >> 8) & 0xFF).to_u8
            b = ((cmd.color >> 16) & 0xFF).to_u8
            cmd_body_start = body_pos

            case cmd.type
            when Citrine::GS::DrawCommand::Type::Clear
              body_pos += 64_u32
            when Citrine::GS::DrawCommand::Type::Rect
              if prev = prev_cmd
                if prev.type == Citrine::GS::DrawCommand::Type::Rect && cmd.y1 == prev.y1 && cmd.x1 == prev.x1 && prev.x2 > cmd.x1 + 100
                  scrubber_present = true
                  scrub_quad_offset = 16_u32 + cmd_body_start
                  scrub_min_x = cmd.x1.to_u16
                  scrub_max_x = prev.x2.to_u16
                  scrub_y2 = cmd.y2.to_u16
                end
              end
              body_pos += 64_u32
            when Citrine::GS::DrawCommand::Type::Circle
              body_pos += 24_u32 * 64_u32
            when Citrine::GS::DrawCommand::Type::Line
              body_pos += 128_u32
            when Citrine::GS::DrawCommand::Type::Triangle
              body_pos += 64_u32
            when Citrine::GS::DrawCommand::Type::Quad
              body_pos += 128_u32
            when Citrine::GS::DrawCommand::Type::Text
              scale = cmd.x2 >= 20 ? 2 : 1
              if md = cmd.text.match(/Frame:\s*(\d{5})/i)
                frame_text_present = true
                frame_text_scale = scale
                frame_pkt_offset = 16_u32 + cmd_body_start
                char_w = 5 * scale
                spacing = 2 * scale
                match_start = md.begin(1).not_nil!
                cum_quads = 0_u32
                cx = cmd.x1
                cy = cmd.y1

                cmd.text.each_char_with_index do |ch, ci|
                  if ch == '\n'
                    cx = cmd.x1
                    cy += 8 * scale
                    next
                  end

                  char_quads = 0_u32
                  if ch != ' '
                    glyph = GifPacketBuilder::FONT_5X7[ch.upcase]? || GifPacketBuilder::FONT_5X7['?']
                    7.times do |row|
                      in_run = false
                      5.times do |col|
                        pixel = ((glyph[col] >> row) & 1) == 1
                        if pixel && !in_run
                          in_run = true
                        elsif !pixel && in_run
                          in_run = false
                          char_quads += 1
                        end
                      end
                      char_quads += 1 if in_run
                    end
                  end

                  pos_fixed = ((cy.to_u32 << 4) << 16) | (cx.to_u32 << 4)

                  if ci >= match_start && ci < match_start + 5
                    frame_digit_offsets << (frame_pkt_offset + cum_quads * 64_u32)
                    frame_digit_positions << pos_fixed
                  end

                  cum_quads += char_quads
                  cx += char_w + spacing
                end
              elsif md = cmd.text.match(/(\d\d):(\d\d)/)
                time_text_present = true
                time_text_scale = scale
                time_pkt_offset = 16_u32 + cmd_body_start
                char_w = 5 * scale
                spacing = 2 * scale
                match_start = md.begin(0).not_nil!
                cum_quads = 0_u32
                cx = cmd.x1
                cy = cmd.y1

                cmd.text.each_char_with_index do |ch, ci|
                  if ch == '\n'
                    cx = cmd.x1
                    cy += 8 * scale
                    next
                  end

                  char_quads = 0_u32
                  if ch != ' '
                    glyph = GifPacketBuilder::FONT_5X7[ch.upcase]? || GifPacketBuilder::FONT_5X7['?']
                    7.times do |row|
                      in_run = false
                      5.times do |col|
                        pixel = ((glyph[col] >> row) & 1) == 1
                        if pixel && !in_run
                          in_run = true
                        elsif !pixel && in_run
                          in_run = false
                          char_quads += 1
                        end
                      end
                      char_quads += 1 if in_run
                    end
                  end

                  pos_fixed = ((cy.to_u32 << 4) << 16) | (cx.to_u32 << 4)

                  case ci
                  when match_start
                    min_tens_offset = time_pkt_offset + cum_quads * 64_u32
                    min_tens_pos = pos_fixed
                  when match_start + 1
                    min_ones_offset = time_pkt_offset + cum_quads * 64_u32
                    min_ones_pos = pos_fixed
                  when match_start + 3
                    sec_tens_offset = time_pkt_offset + cum_quads * 64_u32
                    sec_tens_pos = pos_fixed
                  when match_start + 4
                    sec_ones_offset = time_pkt_offset + cum_quads * 64_u32
                    sec_ones_pos = pos_fixed
                  end

                  cum_quads += char_quads
                  cx += char_w + spacing
                end
              end
              tmp_mem = IO::Memory.new
              quad_count = GifPacketBuilder.emit_text(tmp_mem, cmd.text, cmd.x1, cmd.y1, scale, r, g, b)
              body_pos += quad_count.to_u32 * 64_u32
            end
            prev_cmd = cmd
          end
        end

        # 7. Digit Quad Table (1040 bytes)
        if time_text_present || frame_text_present
          pad = (16 - (out_mem.size % 16)) % 16
          pad.times { out_mem.write_byte(0_u8) }
          digit_table_addr = RODATA_VADDR + out_mem.size.to_u32
          DigitQuadTable::DATA.each do |w|
            out_mem.write_bytes(w, IO::ByteFormat::LittleEndian)
          end
          curr_addr = RODATA_VADDR + out_mem.size.to_u32
        end

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
          phase_msg_addrs: phase_msg_addrs,
          digit_table_addr: digit_table_addr,
          time_text_present: time_text_present,
          min_tens_offset: min_tens_offset,
          min_ones_offset: min_ones_offset,
          sec_tens_offset: sec_tens_offset,
          sec_ones_offset: sec_ones_offset,
          min_tens_pos: min_tens_pos,
          min_ones_pos: min_ones_pos,
          sec_tens_pos: sec_tens_pos,
          sec_ones_pos: sec_ones_pos,
          scrubber_present: scrubber_present,
          scrub_quad_offset: scrub_quad_offset,
          scrub_min_x: scrub_min_x,
          scrub_max_x: scrub_max_x,
          scrub_y2: scrub_y2,
          frame_text_present: frame_text_present,
          frame_digit_offsets: frame_digit_offsets,
          frame_digit_positions: frame_digit_positions,
          frame_text_scale: frame_text_scale,
          time_text_scale: time_text_scale,
          static_dvd_addr: static_dvd_addr,
          static_dvd_qwc: static_dvd_qwc,
          font_quad_addr: font_quad_addr,
          font_quad_count: font_quad_count,
          color_palette_addr: color_palette_addr
        )
      end
    end
  end
end
