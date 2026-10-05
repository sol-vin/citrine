require "../gs/gif_packet_builder"
require "./phase_extractor"

require "./digit_quad_table"

module Citrine
  module ISO
    record VirtualInput, start_frame : UInt32, duration_frames : UInt16, button_mask : UInt16, port : UInt8 = 0_u8

    struct PhaseWidgetInfo
      property scrubber_present : Bool = false
      property scrub_quad_offset : UInt32 = 0_u32
      property scrub_min_x : UInt16 = 62_u16
      property scrub_max_x : UInt16 = 578_u16
      property scrub_y2 : UInt16 = 214_u16

      property scrub_knob_present : Bool = false
      property scrub_knob_offset : UInt32 = 0_u32
      property scrub_knob_half_w : UInt16 = 3_u16
      property scrub_knob_y1 : UInt16 = 200_u16
      property scrub_knob_y2 : UInt16 = 218_u16

      property vol_meter_present : Bool = false
      property vol_meter_offset : UInt32 = 0_u32
      property vol_min_x : UInt16 = 100_u16
      property vol_max_x : UInt16 = 220_u16
      property vol_y2 : UInt16 = 236_u16

      property time_text_present : Bool = false
      property min_tens_offset : UInt32 = 0_u32
      property min_ones_offset : UInt32 = 0_u32
      property sec_tens_offset : UInt32 = 0_u32
      property sec_ones_offset : UInt32 = 0_u32
      property min_tens_pos : UInt32 = 0_u32
      property min_ones_pos : UInt32 = 0_u32
      property sec_tens_pos : UInt32 = 0_u32
      property sec_ones_pos : UInt32 = 0_u32
      property time_text_scale : Int32 = 1
      property dur_frames : UInt32 = 0_u32

      property spinner_present : Bool = false
      property spinner_offset : UInt32 = 0_u32
      property spinner_cx : UInt16 = 0_u16
      property spinner_cy : UInt16 = 0_u16
      property spinner_radius : UInt16 = 0_u16

      property frame_text_present : Bool = false
      property frame_digit_offsets : Array(UInt32) = [] of UInt32
      property frame_digit_positions : Array(UInt32) = [] of UInt32
      property frame_text_scale : Int32 = 1
    end

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
      property spinner_table_addr : UInt32
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
      property scrub_knob_present : Bool
      property scrub_knob_offset : UInt32
      property scrub_knob_half_w : UInt16
      property scrub_knob_y1 : UInt16
      property scrub_knob_y2 : UInt16
      property vol_meter_present : Bool
      property vol_meter_offset : UInt32
      property vol_min_x : UInt16
      property vol_max_x : UInt16
      property vol_y2 : UInt16
      property frame_text_present : Bool
      property frame_digit_offsets : Array(UInt32)
      property frame_digit_positions : Array(UInt32)
      property frame_text_scale : Int32
      property time_text_scale : Int32

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
        @spinner_table_addr = 0_u32,
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
        @scrub_knob_present = false,
        @scrub_knob_offset = 0_u32,
        @scrub_knob_half_w = 3_u16,
        @scrub_knob_y1 = 200_u16,
        @scrub_knob_y2 = 218_u16,
        @vol_meter_present = false,
        @vol_meter_offset = 0_u32,
        @vol_min_x = 100_u16,
        @vol_max_x = 220_u16,
        @vol_y2 = 236_u16,
        @frame_text_present = false,
        @frame_digit_offsets = [] of UInt32,
        @frame_digit_positions = [] of UInt32,
        @frame_text_scale = 1,
        @time_text_scale = 1
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

        # 2. Primary Phase Draw Packets & Per-Phase Widget Analysis
        phase_addrs = [] of UInt32
        phase_qwcs = [] of UInt16
        phase_infos = [] of PhaseWidgetInfo

        @profile.phases.each do |phase|
          body_mem = IO::Memory.new
          info = PhaseWidgetInfo.new
          info.dur_frames = phase.delay_frames if phase.delay_frames > 0
          prev_cmd : Citrine::GS::DrawCommand? = nil
          prev_cmd_body_start = 0_u32

          phase.commands.each do |cmd|
            cmd_body_start = body_mem.pos.to_u32
            r = (cmd.color & 0xFF).to_u8
            g = ((cmd.color >> 8) & 0xFF).to_u8
            b = ((cmd.color >> 16) & 0xFF).to_u8

            case cmd.type
            when Citrine::GS::DrawCommand::Type::Clear
              GifPacketBuilder.emit_quad(body_mem, 0, 0, 640, 448, r, g, b)
            when Citrine::GS::DrawCommand::Type::Rect
              w = cmd.x2 - cmd.x1
              h = cmd.y2 - cmd.y1
              if prev = prev_cmd
                prev_w = prev.x2 - prev.x1
                if prev.type == Citrine::GS::DrawCommand::Type::Rect && cmd.y1 == prev.y1 && cmd.x1 == prev.x1
                  if prev_w >= 200
                    info.scrubber_present = true
                    info.scrub_quad_offset = 16_u32 + cmd_body_start
                    info.scrub_min_x = cmd.x1.to_u16
                    info.scrub_max_x = prev.x2.to_u16
                    info.scrub_y2 = cmd.y2.to_u16
                  else
                    info.vol_meter_present = true
                    info.vol_meter_offset = 16_u32 + cmd_body_start
                    info.vol_min_x = cmd.x1.to_u16
                    info.vol_max_x = prev.x2.to_u16
                    info.vol_y2 = cmd.y2.to_u16
                  end
                elsif info.scrubber_present && prev.type == Citrine::GS::DrawCommand::Type::Rect &&
                      (16_u32 + cmd_body_start == info.scrub_quad_offset + 64_u32) &&
                      w <= 20 && cmd.y1 <= info.scrub_y2 && cmd.y2 >= (info.scrub_y2.to_i - 20)
                  info.scrub_knob_present = true
                  info.scrub_knob_offset = 16_u32 + cmd_body_start
                  info.scrub_knob_half_w = (w // 2).to_u16
                  info.scrub_knob_y1 = cmd.y1.to_u16
                  info.scrub_knob_y2 = cmd.y2.to_u16
                end
              end
              GifPacketBuilder.emit_quad(body_mem, cmd.x1, cmd.y1, cmd.x2, cmd.y2, r, g, b)
            when Citrine::GS::DrawCommand::Type::Circle
              GifPacketBuilder.emit_circle(body_mem, cmd.x1, cmd.y1, cmd.radius, r, g, b)
            when Citrine::GS::DrawCommand::Type::Line
              if prev = prev_cmd
                if prev.type == Citrine::GS::DrawCommand::Type::Line
                  is_case_a = (prev.y1 == prev.y2) && (cmd.x1 == cmd.x2)
                  is_case_b = (prev.x1 == prev.x2) && (cmd.y1 == cmd.y2)

                  if is_case_a || is_case_b
                    cx1 = is_case_a ? (prev.x1 + prev.x2) // 2 : prev.x1
                    cy1 = is_case_a ? prev.y1 : (prev.y1 + prev.y2) // 2
                    r1 = is_case_a ? (prev.x2 - prev.x1).abs // 2 : (prev.y2 - prev.y1).abs // 2

                    cx2 = is_case_a ? cmd.x1 : (cmd.x1 + cmd.x2) // 2
                    cy2 = is_case_a ? (cmd.y1 + cmd.y2) // 2 : cmd.y1
                    r2 = is_case_a ? (cmd.y2 - cmd.y1).abs // 2 : (cmd.x2 - cmd.x1).abs // 2

                    if cx1 == cx2 && cy1 == cy2 && r1 == r2 && r1 >= 4 && r1 <= 32
                      info.spinner_present = true
                      info.spinner_offset = 16_u32 + prev_cmd_body_start
                      info.spinner_cx = cx1.to_u16
                      info.spinner_cy = cy1.to_u16
                      info.spinner_radius = r1.to_u16
                    end
                  end
                end
              end
              GifPacketBuilder.emit_line(body_mem, cmd.x1, cmd.y1, cmd.x2, cmd.y2, r, g, b)
            when Citrine::GS::DrawCommand::Type::Triangle
              GifPacketBuilder.emit_triangle(body_mem, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x3, cmd.y3, r, g, b)
            when Citrine::GS::DrawCommand::Type::Quad
              GifPacketBuilder.emit_quad_triangles(body_mem, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x3, cmd.y3, cmd.x4, cmd.y4, r, g, b)
            when Citrine::GS::DrawCommand::Type::Text
              scale = cmd.x2 >= 20 ? 2 : 1
              char_w = 5 * scale
              spacing = 2 * scale

              if md = cmd.text.match(/Frame:\s*(\d{5})/i)
                info.frame_text_present = true
                info.frame_text_scale = scale
                match_start = md.begin(1).not_nil!
                cx = cmd.x1
                cy = cmd.y1
                cmd.text.each_char_with_index do |ch, ci|
                  if ch == '\n'
                    cx = cmd.x1
                    cy += 8 * scale
                    next
                  end
                  pos_fixed = ((cy.to_u32 << 4) << 16) | (cx.to_u32 << 4)
                  if ci >= match_start && ci < match_start + 5
                    info.frame_digit_offsets << (16_u32 + body_mem.pos.to_u32)
                    info.frame_digit_positions << pos_fixed
                    emit_digit_slot(body_mem, ch, cx, cy, scale, r, g, b)
                  elsif ch != ' '
                    GifPacketBuilder.emit_text(body_mem, ch.to_s, cx, cy, scale, r, g, b)
                  end
                  cx += char_w + spacing
                end
              elsif md = cmd.text.match(/(\d\d):(\d\d)/)
                info.time_text_present = true
                info.time_text_scale = scale
                all_times = cmd.text.scan(/(\d\d):(\d\d)/)
                if all_times.size >= 2
                  d_min = all_times[1][1].to_i
                  d_sec = all_times[1][2].to_i
                  tot_sec = d_min * 60 + d_sec
                  info.dur_frames = (tot_sec * 60).to_u32 if tot_sec > 0
                end
                match_start = md.begin(0).not_nil!
                cx = cmd.x1
                cy = cmd.y1
                cmd.text.each_char_with_index do |ch, ci|
                  if ch == '\n'
                    cx = cmd.x1
                    cy += 8 * scale
                    next
                  end
                  pos_fixed = ((cy.to_u32 << 4) << 16) | (cx.to_u32 << 4)
                  char_offset = 16_u32 + body_mem.pos.to_u32
                  is_dynamic_digit = false
                  case ci
                  when match_start
                    info.min_tens_offset = char_offset
                    info.min_tens_pos = pos_fixed
                    is_dynamic_digit = true
                  when match_start + 1
                    info.min_ones_offset = char_offset
                    info.min_ones_pos = pos_fixed
                    is_dynamic_digit = true
                  when match_start + 3
                    info.sec_tens_offset = char_offset
                    info.sec_tens_pos = pos_fixed
                    is_dynamic_digit = true
                  when match_start + 4
                    info.sec_ones_offset = char_offset
                    info.sec_ones_pos = pos_fixed
                    is_dynamic_digit = true
                  end
                  if is_dynamic_digit
                    emit_digit_slot(body_mem, ch, cx, cy, scale, r, g, b)
                  elsif ch != ' '
                    GifPacketBuilder.emit_text(body_mem, ch.to_s, cx, cy, scale, r, g, b)
                  end
                  cx += char_w + spacing
                end
              else
                GifPacketBuilder.emit_text(body_mem, cmd.text, cmd.x1, cmd.y1, scale, r, g, b)
              end
            end
            prev_cmd = cmd
            prev_cmd_body_start = cmd_body_start
          end

          total_items = {(body_mem.pos // 16).to_i, 65500}.min
          packet = IO::Memory.new
          body_slice = body_mem.to_slice
          gif_tag = (1_u64 << 60) | (1_u64 << 15) | total_items.to_u64
          packet.write_bytes(gif_tag, IO::ByteFormat::LittleEndian)
          packet.write_bytes(0x0e_u64, IO::ByteFormat::LittleEndian)
          packet.write(body_slice[0, total_items * 16])

          pkt = packet.to_slice
          phase_addrs << curr_addr
          phase_qwcs << (pkt.size // 16).to_u16
          out_mem.write(pkt)
          curr_addr += pkt.size.to_u32
          phase_infos << info
        end

        # 3. Phase Descriptor Table (128 bytes per phase, LittleEndian)
        phase_table_addr = 0_u32
        if phase_infos.size > 0
          pad = (16 - (out_mem.size % 16)) % 16
          pad.times { out_mem.write_byte(0_u8) }
          phase_table_addr = RODATA_VADDR + out_mem.size.to_u32

          pt_mem = IO::Memory.new
          phase_infos.each_with_index do |info, i|
            pt_mem.write_bytes(phase_addrs[i], IO::ByteFormat::LittleEndian)         # +0: madr
            pt_mem.write_bytes(phase_qwcs[i].to_u32, IO::ByteFormat::LittleEndian)   # +4: qwc
            pt_mem.write_bytes(info.scrub_quad_offset, IO::ByteFormat::LittleEndian) # +8: scrub_offset
            pt_mem.write_bytes(info.scrub_knob_offset, IO::ByteFormat::LittleEndian) # +12: knob_offset
            pt_mem.write_bytes(info.vol_meter_offset, IO::ByteFormat::LittleEndian)  # +16: vol_offset
            pt_mem.write_bytes(info.min_tens_offset, IO::ByteFormat::LittleEndian)   # +20: min_tens_offset
            pt_mem.write_bytes(info.min_ones_offset, IO::ByteFormat::LittleEndian)   # +24: min_ones_offset
            pt_mem.write_bytes(info.sec_tens_offset, IO::ByteFormat::LittleEndian)   # +28: sec_tens_offset
            pt_mem.write_bytes(info.sec_ones_offset, IO::ByteFormat::LittleEndian)   # +32: sec_ones_offset
            pt_mem.write_bytes(info.min_tens_pos, IO::ByteFormat::LittleEndian)      # +36: min_tens_pos
            pt_mem.write_bytes(info.min_ones_pos, IO::ByteFormat::LittleEndian)      # +40: min_ones_pos
            pt_mem.write_bytes(info.sec_tens_pos, IO::ByteFormat::LittleEndian)      # +44: sec_tens_pos
            pt_mem.write_bytes(info.sec_ones_pos, IO::ByteFormat::LittleEndian)      # +48: sec_ones_pos
            pt_mem.write_bytes(info.scrub_min_x.to_u32, IO::ByteFormat::LittleEndian) # +52: scrub_min_x
            pt_mem.write_bytes(info.scrub_max_x.to_u32, IO::ByteFormat::LittleEndian) # +56: scrub_max_x
            pt_mem.write_bytes(info.scrub_y2.to_u32, IO::ByteFormat::LittleEndian)    # +60: scrub_y2
            pt_mem.write_bytes(info.scrub_knob_half_w.to_u32, IO::ByteFormat::LittleEndian) # +64: knob_half_w
            pt_mem.write_bytes(info.scrub_knob_y1.to_u32, IO::ByteFormat::LittleEndian)    # +68: knob_y1
            pt_mem.write_bytes(info.scrub_knob_y2.to_u32, IO::ByteFormat::LittleEndian)    # +72: knob_y2
            pt_mem.write_bytes(info.vol_min_x.to_u32, IO::ByteFormat::LittleEndian)   # +76: vol_min_x
            pt_mem.write_bytes(info.vol_max_x.to_u32, IO::ByteFormat::LittleEndian)   # +80: vol_max_x
            pt_mem.write_bytes(info.vol_y2.to_u32, IO::ByteFormat::LittleEndian)      # +84: vol_y2
            pt_mem.write_bytes(info.dur_frames, IO::ByteFormat::LittleEndian)         # +88: dur_frames
            flags = 0_u32
            flags |= 1_u32 if info.scrubber_present
            flags |= 2_u32 if info.scrub_knob_present
            flags |= 4_u32 if info.vol_meter_present
            flags |= 8_u32 if info.time_text_present
            flags |= 16_u32 if info.frame_text_present
            flags |= 32_u32 if info.spinner_present
            flags |= (info.time_text_scale.to_u32 & 0xFF_u32) << 8 # scale packed in bits 8..15
            pt_mem.write_bytes(flags, IO::ByteFormat::LittleEndian)                     # +92: flags
            pt_mem.write_bytes(info.spinner_offset, IO::ByteFormat::LittleEndian)        # +96: spinner_offset
            pt_mem.write_bytes(info.spinner_cx.to_u32, IO::ByteFormat::LittleEndian)     # +100: spinner_cx
            pt_mem.write_bytes(info.spinner_cy.to_u32, IO::ByteFormat::LittleEndian)     # +104: spinner_cy
            pt_mem.write_bytes(info.spinner_radius.to_u32, IO::ByteFormat::LittleEndian) # +108: spinner_radius
            4.times { pt_mem.write_bytes(0_u32, IO::ByteFormat::LittleEndian) }          # +112..+124: padding to 128 bytes
          end
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

        # 6. Digit Quad Table (1040 bytes)
        digit_table_addr = 0_u32
        if phase_infos.any?(&.time_text_present) || phase_infos.any?(&.frame_text_present)
          pad = (16 - (out_mem.size % 16)) % 16
          pad.times { out_mem.write_byte(0_u8) }
          digit_table_addr = RODATA_VADDR + out_mem.size.to_u32
          DigitQuadTable::DATA.each do |w|
            out_mem.write_bytes(w, IO::ByteFormat::LittleEndian)
          end
          curr_addr = RODATA_VADDR + out_mem.size.to_u32
        end

        # 7. Spinner Trig Table (64 bytes: 8 steps of dx_factor:Int32, dy_factor:Int32)
        pad = (16 - (out_mem.size % 16)) % 16
        pad.times { out_mem.write_byte(0_u8) }
        spinner_table_addr = RODATA_VADDR + out_mem.size.to_u32
        spinner_factors = [
          {256, 0},
          {181, 181},
          {0, 256},
          {-181, 181},
          {-256, 0},
          {-181, -181},
          {0, -256},
          {181, -181},
        ]
        spinner_factors.each do |(dx_f, dy_f)|
          out_mem.write_bytes(dx_f.to_i32, IO::ByteFormat::LittleEndian)
          out_mem.write_bytes(dy_f.to_i32, IO::ByteFormat::LittleEndian)
        end
        curr_addr = RODATA_VADDR + out_mem.size.to_u32

        f_info = phase_infos.first? || PhaseWidgetInfo.new

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
          spinner_table_addr: spinner_table_addr,
          time_text_present: f_info.time_text_present,
          min_tens_offset: f_info.min_tens_offset,
          min_ones_offset: f_info.min_ones_offset,
          sec_tens_offset: f_info.sec_tens_offset,
          sec_ones_offset: f_info.sec_ones_offset,
          min_tens_pos: f_info.min_tens_pos,
          min_ones_pos: f_info.min_ones_pos,
          sec_tens_pos: f_info.sec_tens_pos,
          sec_ones_pos: f_info.sec_ones_pos,
          scrubber_present: f_info.scrubber_present,
          scrub_quad_offset: f_info.scrub_quad_offset,
          scrub_min_x: f_info.scrub_min_x,
          scrub_max_x: f_info.scrub_max_x,
          scrub_y2: f_info.scrub_y2,
          scrub_knob_present: f_info.scrub_knob_present,
          scrub_knob_offset: f_info.scrub_knob_offset,
          scrub_knob_half_w: f_info.scrub_knob_half_w,
          scrub_knob_y1: f_info.scrub_knob_y1,
          scrub_knob_y2: f_info.scrub_knob_y2,
          vol_meter_present: f_info.vol_meter_present,
          vol_meter_offset: f_info.vol_meter_offset,
          vol_min_x: f_info.vol_min_x,
          vol_max_x: f_info.vol_max_x,
          vol_y2: f_info.vol_y2,
          frame_text_present: f_info.frame_text_present,
          frame_digit_offsets: f_info.frame_digit_offsets,
          frame_digit_positions: f_info.frame_digit_positions,
          frame_text_scale: f_info.frame_text_scale,
          time_text_scale: f_info.time_text_scale
        )
      end

      private def emit_digit_slot(io : IO::Memory, ch : Char, cx : Int32, cy : Int32, scale : Int32, r : UInt8, g : UInt8, b : UInt8)
        d = ch.to_i? || 0
        13.times do |qi|
          d3 = DigitQuadTable::DATA[d * 26 + qi * 2]
          d2 = DigitQuadTable::DATA[d * 26 + qi * 2 + 1]
          if d2 != 0
            x1 = cx + ((d3 & 0xFFFF) >> 4) * scale
            y1 = cy + ((d3 >> 20)) * scale
            x2 = cx + ((d2 & 0xFFFF) >> 4) * scale
            y2 = cy + ((d2 >> 20)) * scale
            GifPacketBuilder.emit_quad(io, x1.to_i, y1.to_i, x2.to_i, y2.to_i, r, g, b, 128_u8)
          else
            GifPacketBuilder.emit_quad(io, 0, 0, 0, 0, 0_u8, 0_u8, 0_u8, 0_u8)
          end
        end
      end
    end
  end
end
