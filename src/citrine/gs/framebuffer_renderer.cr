require "compress/zlib"
require "digest/crc32"
require "./gif_packet_builder"

module Citrine
  module GS
    class FramebufferRenderer
      WIDTH  = 640
      HEIGHT = 448

      # Rasterizes an array of GS DrawCommands into a 32-bit RGBA pixel buffer
      def self.render(commands : Array(DrawCommand), width : Int32 = WIDTH, height : Int32 = HEIGHT) : Slice(UInt32)
        buf = Slice(UInt32).new(width * height, 0xFF000000_u32)

        commands.each do |cmd|
          case cmd.type
          when DrawCommand::Type::Clear
            c = cmd.color != 0_u32 ? cmd.color : 0xFF000000_u32
            buf.fill(c)

          when DrawCommand::Type::Rect
            draw_rect(buf, width, height, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.color)

          when DrawCommand::Type::Circle
            draw_circle(buf, width, height, cmd.x1, cmd.y1, cmd.radius, cmd.color)

          when DrawCommand::Type::Line
            draw_line(buf, width, height, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.color)

          when DrawCommand::Type::Triangle
            draw_triangle(buf, width, height, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x3, cmd.y3, cmd.color)

          when DrawCommand::Type::Quad
            draw_triangle(buf, width, height, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x3, cmd.y3, cmd.color)
            draw_triangle(buf, width, height, cmd.x1, cmd.y1, cmd.x3, cmd.y3, cmd.x4, cmd.y4, cmd.color)

          when DrawCommand::Type::Text
            draw_text(buf, width, height, cmd.text, cmd.x1, cmd.y1, cmd.x2, cmd.color)
          end
        end

        buf
      end

      # Saves rendered commands directly to a PNG file
      def self.save_png(commands : Array(DrawCommand), output_path : String, width : Int32 = WIDTH, height : Int32 = HEIGHT) : Bool
        pixels = render(commands, width, height)
        Dir.mkdir_p(File.dirname(output_path))
        encode_png(pixels, width, height, output_path)
        File.exists?(output_path) && File.size(output_path) > 0
      end

      private def self.set_pixel(buf : Slice(UInt32), w : Int32, h : Int32, x : Int32, y : Int32, color : UInt32)
        return if x < 0 || x >= w || y < 0 || y >= h
        
        # Color format: 0xAABBGGRR or 0xAARRGGBB depending on source. Standardize:
        a = ((color >> 24) & 0xFF).to_u32
        if a == 0 && color != 0
          a = 255_u32
        end

        if a >= 250
          buf[y * w + x] = color | 0xFF000000_u32
        else
          # Alpha blend
          dst = buf[y * w + x]
          dst_r = dst & 0xFF
          dst_g = (dst >> 8) & 0xFF
          dst_b = (dst >> 16) & 0xFF

          src_r = color & 0xFF
          src_g = (color >> 8) & 0xFF
          src_b = (color >> 16) & 0xFF

          inv_a = 255_u32 - a
          out_r = (src_r * a + dst_r * inv_a) // 255
          out_g = (src_g * a + dst_g * inv_a) // 255
          out_b = (src_b * a + dst_b * inv_a) // 255

          buf[y * w + x] = 0xFF000000_u32 | (out_b << 16) | (out_g << 8) | out_r
        end
      end

      private def self.draw_rect(buf : Slice(UInt32), w : Int32, h : Int32, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, col : UInt32)
        min_x = Math.max(0, Math.min(x1, x2))
        max_x = Math.min(w - 1, Math.max(x1, x2))
        min_y = Math.max(0, Math.min(y1, y2))
        max_y = Math.min(h - 1, Math.max(y1, y2))

        (min_y..max_y).each do |y|
          (min_x..max_x).each do |x|
            set_pixel(buf, w, h, x, y, col)
          end
        end
      end

      private def self.draw_circle(buf : Slice(UInt32), w : Int32, h : Int32, cx : Int32, cy : Int32, radius : Int32, col : UInt32)
        r2 = radius * radius
        (-radius..radius).each do |dy|
          y = cy + dy
          next if y < 0 || y >= h
          (-radius..radius).each do |dx|
            x = cx + dx
            next if x < 0 || x >= w
            if dx * dx + dy * dy <= r2
              set_pixel(buf, w, h, x, y, col)
            end
          end
        end
      end

      private def self.draw_line(buf : Slice(UInt32), w : Int32, h : Int32, x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32, col : UInt32)
        dx = (x1.to_i64 - x0.to_i64).abs
        dy = -(y1.to_i64 - y0.to_i64).abs
        sx = x0 < x1 ? 1 : -1
        sy = y0 < y1 ? 1 : -1
        err = dx + dy

        curr_x = x0
        curr_y = y0
        steps = 0
        max_steps = 4000

        loop do
          set_pixel(buf, w, h, curr_x, curr_y, col)
          break if (curr_x == x1 && curr_y == y1) || (steps += 1) >= max_steps
          e2 = 2_i64 * err
          if e2 >= dy
            err += dy
            curr_x += sx
          end
          if e2 <= dx
            err += dx
            curr_y += sy
          end
        end
      end

      private def self.draw_triangle(buf : Slice(UInt32), w : Int32, h : Int32, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, x3 : Int32, y3 : Int32, col : UInt32)
        min_x = Math.max(0, {x1, x2, x3}.min)
        max_x = Math.min(w - 1, {x1, x2, x3}.max)
        min_y = Math.max(0, {y1, y2, y3}.min)
        max_y = Math.min(h - 1, {y1, y2, y3}.max)
        return if min_x > max_x || min_y > max_y

        denom = ((y2.to_i64 - y3.to_i64) * (x1.to_i64 - x3.to_i64) + (x3.to_i64 - x2.to_i64) * (y1.to_i64 - y3.to_i64)).to_f32
        return if denom.abs < 0.0001_f32

        (min_y..max_y).each do |y|
          (min_x..max_x).each do |x|
            w1 = ((y2.to_i64 - y3.to_i64) * (x.to_i64 - x3.to_i64) + (x3.to_i64 - x2.to_i64) * (y.to_i64 - y3.to_i64)).to_f32 / denom
            w2 = ((y3.to_i64 - y1.to_i64) * (x.to_i64 - x3.to_i64) + (x1.to_i64 - x3.to_i64) * (y.to_i64 - y3.to_i64)).to_f32 / denom
            w3 = 1.0_f32 - w1 - w2
            if w1 >= 0.0_f32 && w2 >= 0.0_f32 && w3 >= 0.0_f32
              set_pixel(buf, w, h, x, y, col)
            end
          end
        end
      end

      private def self.draw_text(buf : Slice(UInt32), w : Int32, h : Int32, text : String, start_x : Int32, start_y : Int32, font_size : Int32, col : UInt32)
        scale = Math.max(1, font_size // 10)
        curr_x = start_x
        curr_y = start_y

        text.each_char do |ch|
          if ch == '\n'
            curr_x = start_x
            curr_y += 8 * scale
            next
          end

          columns = GifPacketBuilder::FONT_5X7[ch]? || GifPacketBuilder::FONT_5X7[ch.upcase]? || GifPacketBuilder::FONT_5X7['?']
          columns.each_with_index do |col_byte, col_idx|
            7.times do |row_idx|
              if ((col_byte >> row_idx) & 1) == 1
                (0...scale).each do |sy|
                  (0...scale).each do |sx|
                    px = curr_x + (col_idx * scale) + sx
                    py = curr_y + (row_idx * scale) + sy
                    set_pixel(buf, w, h, px, py, col)
                  end
                end
              end
            end
          end
          curr_x += 6 * scale
        end
      end

      # Pure Crystal PNG Encoder (8-bit RGBA)
      private def self.encode_png(pixels : Slice(UInt32), width : Int32, height : Int32, file_path : String)
        File.open(file_path, "wb") do |io|
          # 1. PNG Header
          io.write(Bytes[0x89_u8, 0x50_u8, 0x4E_u8, 0x47_u8, 0x0D_u8, 0x0A_u8, 0x1A_u8, 0x0A_u8])

          # 2. IHDR Chunk
          ihdr_data = IO::Memory.new(13)
          ihdr_data.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
          ihdr_data.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
          ihdr_data.write_byte(8_u8) # Bit depth
          ihdr_data.write_byte(6_u8) # Color type: RGBA
          ihdr_data.write_byte(0_u8) # Compression
          ihdr_data.write_byte(0_u8) # Filter
          ihdr_data.write_byte(0_u8) # Interlace
          write_chunk(io, "IHDR", ihdr_data.to_slice)

          # 3. IDAT Chunk (raw scanlines compressed with Zlib)
          raw_scanlines = IO::Memory.new((width * 4 + 1) * height)
          height.times do |y|
            raw_scanlines.write_byte(0_u8) # Filter type 0 (None)
            width.times do |x|
              pixel = pixels[y * width + x]
              # Little-endian UInt32: RR GG BB AA
              r = (pixel & 0xFF).to_u8
              g = ((pixel >> 8) & 0xFF).to_u8
              b = ((pixel >> 16) & 0xFF).to_u8
              a = ((pixel >> 24) & 0xFF).to_u8
              a = 255_u8 if a == 0 && pixel != 0
              raw_scanlines.write_byte(r)
              raw_scanlines.write_byte(g)
              raw_scanlines.write_byte(b)
              raw_scanlines.write_byte(a)
            end
          end

          compressed = IO::Memory.new
          Compress::Zlib::Writer.open(compressed) do |zlib|
            zlib.write(raw_scanlines.to_slice)
          end
          write_chunk(io, "IDAT", compressed.to_slice)

          # 4. IEND Chunk
          write_chunk(io, "IEND", Bytes.empty)
        end
      end

      private def self.write_chunk(io : IO, type : String, data : Bytes)
        io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
        type_bytes = type.to_slice
        io.write(type_bytes)
        io.write(data) unless data.empty?

        # CRC32 computed over type + data
        crc_mem = IO::Memory.new(type_bytes.size + data.size)
        crc_mem.write(type_bytes)
        crc_mem.write(data) unless data.empty?
        crc = Digest::CRC32.checksum(crc_mem.to_slice)
        io.write_bytes(crc.to_u32, IO::ByteFormat::BigEndian)
      end
    end
  end
end
