require "compress/zlib"

module Citrine
  module ISO
    # Builds GS GIF draw packets for the mandatory Citrine 2-second boot splash screen.
    # Displays logo.png centered against a solid white background (#FFFFFF).
    # Packet memory is placed in heap space at 0x00220000 and 100% reclaimed after boot.
    class SplashScreenBuilder
      LOGO_W   = 195
      LOGO_H   = 220
      SCREEN_W = 640
      SCREEN_H = 448

      @@cached_packet : Bytes? = nil

      # Generates a standard GS GIF packet containing a full-screen white quad
      # and the centered Citrine gem logo.
      def self.build_packet(logo_path : String? = nil) : Bytes
        if cached = @@cached_packet
          return cached
        end

        path = logo_path || (File.exists?("logo.png") ? "logo.png" : File.join(Dir.current, "logo.png"))
        path = File.join(__DIR__, "../../../logo.png") unless File.exists?(path)

        raw_rgba : Bytes? = nil
        if File.exists?(path)
          raw_rgba = decode_png(path) rescue nil
        end

        body_mem = IO::Memory.new(65536)

        # 1. Full-screen solid white background quad (0, 0 to 640, 448, color #FFFFFF)
        emit_quad(body_mem, 0, 0, SCREEN_W, SCREEN_H, 0xFF_u8, 0xFF_u8, 0xFF_u8, 0x80_u8)

        # 2. Centered Logo pixel spans
        if raw = raw_rgba
          start_x = (SCREEN_W - LOGO_W) // 2 # 222
          start_y = (SCREEN_H - LOGO_H) // 2 # 114

          LOGO_H.times do |y|
            x = 0
            while x < LOGO_W
              pix_idx = (y * LOGO_W + x) * 4
              r = raw[pix_idx]
              g = raw[pix_idx + 1]
              b = raw[pix_idx + 2]
              a = raw[pix_idx + 3]

              span_len = 1
              while (x + span_len) < LOGO_W
                n_idx = (y * LOGO_W + (x + span_len)) * 4
                break if raw[n_idx] != r || raw[n_idx + 1] != g || raw[n_idx + 2] != b || (a < 16 && raw[n_idx + 3] < 16)
                span_len += 1
              end

              # Render non-white pixels
              if a >= 16 && !(r > 240 && g > 240 && b > 240)
                x1 = start_x + x
                y1 = start_y + y
                x2 = start_x + x + span_len
                y2 = start_y + y + 1
                emit_quad(body_mem, x1, y1, x2, y2, r, g, b, 0x80_u8)
              end

              x += span_len
            end
          end
        end

        total_items = (body_mem.pos // 16).to_i
        packet = IO::Memory.new(16 + total_items * 16)
        # GIFTag: NLOOP = total_items, EOP = 1, FLG = PACKED (0), NREG = 1, REGS = 0x0E (A+D)
        gif_tag = (1_u64 << 60) | (1_u64 << 15) | (total_items.to_u64 & 0x7FFF_u64)
        packet.write_bytes(gif_tag, IO::ByteFormat::LittleEndian)
        packet.write_bytes(0x0e_u64, IO::ByteFormat::LittleEndian)
        packet.write(body_mem.to_slice[0, total_items * 16])

        res = packet.to_slice
        @@cached_packet = res
        res
      end

      # Emits 2D Sprite primitive (Upper-left to Lower-right)
      private def self.emit_quad(io : IO::Memory, x1 : Int32, y1 : Int32, x2 : Int32, y2 : Int32, r : UInt8, g : UInt8, b : UInt8, a : UInt8 = 0x80_u8)
        io.write_bytes(6_u64, IO::ByteFormat::LittleEndian) # PRIM (0x00) = Sprite (6)
        io.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
        rgbaq = (0x3F800000_u64 << 32) | (a.to_u64 << 24) | (b.to_u64 << 16) | (g.to_u64 << 8) | r.to_u64
        io.write_bytes(rgbaq, IO::ByteFormat::LittleEndian)
        io.write_bytes(1_u64, IO::ByteFormat::LittleEndian) # RGBAQ (0x01)
        gs_x1 = ((x1.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y1 = ((y1.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y1 << 16) | gs_x1, IO::ByteFormat::LittleEndian)
        io.write_bytes(0x0d_u64, IO::ByteFormat::LittleEndian) # XYZ3 (0x0D)
        gs_x2 = ((x2.to_i64 << 4) & 0xFFFF_i64).to_u64
        gs_y2 = ((y2.to_i64 << 4) & 0xFFFF_i64).to_u64
        io.write_bytes((gs_y2 << 16) | gs_x2, IO::ByteFormat::LittleEndian)
        io.write_bytes(5_u64, IO::ByteFormat::LittleEndian)    # XYZ2 (0x05)
      end

      private def self.paeth(a : Int32, b : Int32, c : Int32) : Int32
        p = a + b - c
        pa = (p - a).abs
        pb = (p - b).abs
        pc = (p - c).abs
        if pa <= pb && pa <= pc
          a
        elsif pb <= pc
          b
        else
          c
        end
      end

      private def self.decode_png(path : String) : Bytes
        bytes = File.read(path).to_slice
        io = IO::Memory.new(bytes)
        magic = io.read_string(8)
        raise "Invalid PNG header" unless magic == "\x89PNG\r\n\x1a\n"

        idat_mem = IO::Memory.new
        width = 0
        height = 0

        while io.pos < bytes.size
          len = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          ctype = io.read_string(4)
          if ctype == "IHDR"
            width = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
            height = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
            io.skip(len - 8)
          elsif ctype == "IDAT"
            chunk = Bytes.new(len)
            io.read_fully(chunk)
            idat_mem.write(chunk)
          else
            io.skip(len)
          end
          io.read_bytes(UInt32) # crc
        end

        decomp_mem = IO::Memory.new
        Compress::Zlib::Reader.open(IO::Memory.new(idat_mem.to_slice)) do |z|
          IO.copy(z, decomp_mem)
        end
        decompressed = decomp_mem.to_slice

        stride = width * 4
        raw_rgba = Bytes.new(width * height * 4)
        prev_line = Bytes.new(stride, 0_u8)
        curr_line = Bytes.new(stride, 0_u8)

        height.times do |y|
          src_offset = y * (stride + 1)
          filter_type = decompressed[src_offset]
          scanline = decompressed[src_offset + 1, stride]

          case filter_type
          when 0 # None
            scanline.copy_to(curr_line)
          when 1 # Sub
            stride.times do |i|
              left = i >= 4 ? curr_line[i - 4].to_i : 0
              curr_line[i] = ((scanline[i].to_i + left) & 0xFF).to_u8
            end
          when 2 # Up
            stride.times do |i|
              up = prev_line[i].to_i
              curr_line[i] = ((scanline[i].to_i + up) & 0xFF).to_u8
            end
          when 3 # Average
            stride.times do |i|
              left = i >= 4 ? curr_line[i - 4].to_i : 0
              up = prev_line[i].to_i
              curr_line[i] = ((scanline[i].to_i + (left + up) // 2) & 0xFF).to_u8
            end
          when 4 # Paeth
            stride.times do |i|
              left = i >= 4 ? curr_line[i - 4].to_i : 0
              up = prev_line[i].to_i
              up_left = i >= 4 ? prev_line[i - 4].to_i : 0
              curr_line[i] = ((scanline[i].to_i + paeth(left, up, up_left)) & 0xFF).to_u8
            end
          end

          curr_line.copy_to(raw_rgba[y * stride, stride])
          curr_line.copy_to(prev_line)
        end

        raw_rgba
      end
    end
  end
end
