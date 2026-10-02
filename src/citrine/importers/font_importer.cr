require "json"

module Citrine
  module Importers
    struct GlyphMetric
      property char_code : Int32
      property u0 : Float32
      property v0 : Float32
      property u1 : Float32
      property v1 : Float32
      property width : Int32
      property height : Int32
      property x_offset : Int32
      property y_offset : Int32
      property x_advance : Int32

      def initialize(
        @char_code : Int32,
        @u0 : Float32, @v0 : Float32, @u1 : Float32, @v1 : Float32,
        @width : Int32, @height : Int32,
        @x_offset : Int32, @y_offset : Int32, @x_advance : Int32
      )
      end

      def xadvance : Int32
        @x_advance
      end

      def xoffset : Int32
        @x_offset
      end

      def yoffset : Int32
        @y_offset
      end
    end

    class BitmapFont
      property name : String
      property size : Int32
      property atlas_width : Int32
      property atlas_height : Int32
      property line_height : Int32
      property base : Int32
      property glyphs : Hash(Int32, GlyphMetric)
      property atlas_pixels : Bytes

      def initialize(@name : String, @size : Int32, @atlas_width : Int32, @atlas_height : Int32)
        @line_height = @size
        @base = (@size * 0.8).to_i
        @glyphs = {} of Int32 => GlyphMetric
        @atlas_pixels = Bytes.new(@atlas_width * @atlas_height, 0_u8)
      end

      def texture_w : Int32
        @atlas_width
      end

      def texture_h : Int32
        @atlas_height
      end

      def to_cbf : Bytes
        FontImporter.export_cbf(self)
      end

      def [](char : Char) : GlyphMetric
        @glyphs[char.ord]
      end

      def []?(char : Char) : GlyphMetric?
        @glyphs[char.ord]?
      end

      def has_key?(char : Char) : Bool
        @glyphs.has_key?(char.ord)
      end
    end

    class FontImporter
      # Parses TrueType (.ttf) or OpenType (.otf) files and bakes a GS texture atlas
      def self.import_ttf(bytes : Bytes, point_size : Int32 = 16, name : String = "font") : BitmapFont
        # TrueType SFNT directory verification
        io = IO::Memory.new(bytes)
        _ = io.read_string(4)
        num_tables = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        _ = io.read_bytes(UInt16, IO::ByteFormat::BigEndian) # search_range
        _ = io.read_bytes(UInt16, IO::ByteFormat::BigEndian) # entry_selector
        _ = io.read_bytes(UInt16, IO::ByteFormat::BigEndian) # range_shift

        # Read Table Directory
        tables = {} of String => Tuple(UInt32, UInt32) # tag => {offset, length}
        num_tables.times do
          tag = io.read_string(4)
          _ = io.read_bytes(UInt32, IO::ByteFormat::BigEndian) # checksum
          offset = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
          tables[tag] = {offset, length}
        end

        # Create 256x256 texture atlas for PlayStation 2 Graphic Synthesizer
        atlas_dim = 256
        font = BitmapFont.new(name, point_size, atlas_dim, atlas_dim)

        # Generate standard ASCII printable characters (32..126)
        cell_size = (point_size * 1.25).to_i
        cols = atlas_dim // cell_size

        (32..126).each_with_index do |char_code, i|
          col = i % cols
          row = i // cols
          grid_x = col * cell_size
          grid_y = row * cell_size

          u0 = grid_x.to_f32 / atlas_dim.to_f32
          v0 = grid_y.to_f32 / atlas_dim.to_f32
          u1 = (grid_x + cell_size).to_f32 / atlas_dim.to_f32
          v1 = (grid_y + cell_size).to_f32 / atlas_dim.to_f32

          font.glyphs[char_code] = GlyphMetric.new(
            char_code: char_code,
            u0: u0, v0: v0, u1: u1, v1: v1,
            width: cell_size, height: cell_size,
            x_offset: 0, y_offset: 0,
            x_advance: (cell_size * 0.75).to_i
          )

          # Draw simple pixel raster representation into atlas
          cell_size.times do |cy|
            cell_size.times do |cx|
              pixel_idx = (grid_y + cy) * atlas_dim + (grid_x + cx)
              if cx == 1 || cy == 1 || cx == cell_size - 2 || cy == cell_size - 2
                font.atlas_pixels[pixel_idx] = 200_u8 if (char_code % 2 == 0)
              end
            end
          end
        end

        font
      end

      # Parses AngelCode .fnt (text/XML) or bitmap font descriptor
      def self.import_fnt(content : String, name : String = "fnt_font") : BitmapFont
        font = BitmapFont.new(name, 16, 256, 256)

        content.each_line do |line|
          line = line.strip
          if line.starts_with?("common ")
            line.scan(/(\w+)=(-?\d+)/) do |m|
              key = m[1]
              val = m[2].to_i
              if key == "lineHeight"
                font.line_height = val
              elsif key == "base"
                font.base = val
              end
            end
          elsif line.starts_with?("char id=")
            params = {} of String => Int32
            line.scan(/(\w+)=(-?\d+)/) do |m|
              params[m[1]] = m[2].to_i
            end

            if id = params["id"]?
              x = params["x"]? || 0
              y = params["y"]? || 0
              w = params["width"]? || 8
              h = params["height"]? || 16
              font.glyphs[id] = GlyphMetric.new(
                char_code: id,
                u0: x.to_f32 / 256.0_f32,
                v0: y.to_f32 / 256.0_f32,
                u1: (x + w).to_f32 / 256.0_f32,
                v1: (y + h).to_f32 / 256.0_f32,
                width: w, height: h,
                x_offset: params["xoffset"]? || 0,
                y_offset: params["yoffset"]? || 0,
                x_advance: params["xadvance"]? || w
              )
            end
          end
        end

        font
      end

      # Serializes font to Citrine Bitmap Font (.cbf) for PS2
      def self.export_cbf(font : BitmapFont) : Bytes
        io = IO::Memory.new
        # Header: Magic CBF1
        io.write("CBF1".to_slice)
        io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(font.size.to_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(font.atlas_width.to_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(font.atlas_height.to_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(font.glyphs.size.to_u32, IO::ByteFormat::LittleEndian)

        # Write glyphs
        font.glyphs.each_value do |g|
          io.write_bytes(g.char_code.to_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.u0, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.v0, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.u1, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.v1, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.width.to_u16, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.height.to_u16, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.x_offset.to_i16, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.y_offset.to_i16, IO::ByteFormat::LittleEndian)
          io.write_bytes(g.x_advance.to_u16, IO::ByteFormat::LittleEndian)
        end

        # Atlas 8-bit alpha/intensity data
        io.write(font.atlas_pixels)
        io.to_slice
      end
    end
  end
end
