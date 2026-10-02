require "io/memory"
require "./gs_config"

module Citrine
  module GS
    struct DrawCommand
      enum Type
        Clear
        Rect
        Circle
        Line
        Triangle
        Quad
        Text
      end

      getter type : Type
      getter x1 : Int32
      getter y1 : Int32
      getter x2 : Int32
      getter y2 : Int32
      getter x3 : Int32
      getter y3 : Int32
      getter x4 : Int32
      getter y4 : Int32
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
        @x4 : Int32 = 0,
        @y4 : Int32 = 0,
        @radius : Int32 = 0,
        @color : UInt32 = 0_u32,
        @text : String = ""
      )
      end
    end

    struct Phase
      property commands : Array(DrawCommand)
      property delay_frames : UInt32
      property message : String?

      def initialize(@commands : Array(DrawCommand), @delay_frames : UInt32 = 0_u32, @message : String? = nil)
      end
    end

    class GifPacketBuilder
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
        'Z' => [0x61, 0x51, 0x49, 0x45, 0x43]
      }

      def self.build_env_packet : Bytes
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

      def self.build_draw_packet(commands : Array(DrawCommand)) : Bytes
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
          when DrawCommand::Type::Quad
            emit_quad_triangles(body, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x3, cmd.y3, cmd.x4, cmd.y4, r, g, b)
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

      # Emits 2D Sprite primitive (Upper-left to Lower-right)
      def self.emit_quad(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
        io.write_bytes(6_u64, IO::ByteFormat::LittleEndian) # PRIM (0x00) = Sprite (6)
        io.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
        rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
        io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u64, IO::ByteFormat::LittleEndian) # RGBAQ (0x01)
        gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian) # XYZ3 (0x0D - queue without draw)
        gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
        io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)    # XYZ2 (0x05 - queue and kick draw)
      end

      # Decomposes 4-vertex quad into TWO triangles: (1, 2, 3) and (1, 3, 4)
      def self.emit_quad_triangles(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, x3 : Int32, y3 : Int32, x4 : Int32, y4 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
        # Triangle 1
        emit_triangle(io, x1, y1, x2, y2, x3, y3, r, g, b, a)
        # Triangle 2
        emit_triangle(io, x1, y1, x3, y3, x4, y4, r, g, b, a)
      end

      def self.emit_line(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
        emit_single_line(io, x1, y1, x2, y2, r, g, b, a)
        if (x2 - x1).abs > (y2 - y1).abs
          emit_single_line(io, x1, y1 + 1, x2, y2 + 1, r, g, b, a)
        else
          emit_single_line(io, x1 + 1, y1, x2 + 1, y2, r, g, b, a)
        end
      end

      def self.emit_single_line(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
        io.write_bytes(1_u64, IO::ByteFormat::LittleEndian) # PRIM (0x00) = Line (1)
        io.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
        rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
        io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
        gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian)
        gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
        io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)
      end

      # Decomposes circle into radial triangles (TriangleFan approximation)
      def self.emit_circle(io : IO::Memory, cx : Int32, cy : Int32, radius : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
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

      def self.emit_triangle(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, x3 : Int32, y3 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
        io.write_bytes(3_u64, IO::ByteFormat::LittleEndian) # PRIM (0x00) = Triangle (3)
        io.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
        rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
        io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u64, IO::ByteFormat::LittleEndian)
        gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian)
        gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian)
        gs_x3 = ((x3.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y3 = ((y3.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y3 << 16) | gs_x3, IO::ByteFormat::LittleEndian)
        io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)    # XYZ2 (0x05) kicks draw
      end

      def self.emit_text(io : IO::Memory, text : String, start_x : Int32, start_y : Int32, scale : Int32, r : UInt8, g : UInt8, b : UInt8) : Int32
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
    end
  end
end
