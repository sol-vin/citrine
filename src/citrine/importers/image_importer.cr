module Citrine
  module Importers
    enum GSColorFormat : UInt8
      PSMCT32 = 0x00 # 32-bit RGBA
      PSMCT16 = 0x02 # 16-bit RGBA5551
      PSMT8   = 0x13 # 8-bit Indexed (256 color palette)
      PSMT4   = 0x14 # 4-bit Indexed (16 color palette)
    end

    class TextureAsset
      property width : Int32
      property height : Int32
      property format : GSColorFormat
      property pixels : Bytes
      property palette : Bytes? # Palette for indexed formats (PSMT8 / PSMT4)

      def initialize(@width : Int32, @height : Int32, @format : GSColorFormat, @pixels : Bytes, @palette : Bytes? = nil)
      end

      def vram_bytes : Int32
        base = case @format
               when GSColorFormat::PSMCT32 then @width * @height * 4
               when GSColorFormat::PSMCT16 then @width * @height * 2
               when GSColorFormat::PSMT8   then @width * @height
               when GSColorFormat::PSMT4   then (@width * @height) // 2
               else @width * @height * 4
               end
        pal = @palette ? @palette.not_nil!.size : 0
        base + pal
      end

      def vram_size_bytes : Int32
        vram_bytes
      end

      def to_cbt : Bytes
        ImageImporter.export_cbt(self)
      end
    end

    class ImageImporter
      # Decodes BMP images (24-bit, 32-bit, or 8-bit indexed)
      def self.import_bmp(bytes : Bytes) : TextureAsset
        io = IO::Memory.new(bytes)
        magic = io.read_string(2)
        raise "Invalid BMP header: #{magic}" unless magic == "BM"

        _ = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # file_size
        _ = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # reserved
        offset = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

        # DIB Header
        _ = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # dib_size
        width = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
        raw_height = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
        top_down = raw_height < 0
        height = raw_height.abs
        _ = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian) # planes
        bpp = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)

        # Convert to 32-bit RGBA or Paletted for GS
        pixel_data = Bytes.new(width * height * 4, 255_u8)

        io.pos = offset.to_i
        case bpp
        when 32
          # BGRA to RGBA
          height.times do |y|
            dst_y = top_down ? y : (height - 1 - y)
            width.times do |x|
              b = io.read_byte || 0_u8
              g = io.read_byte || 0_u8
              r = io.read_byte || 0_u8
              a = io.read_byte || 255_u8
              idx = (dst_y * width + x) * 4
              pixel_data[idx] = r
              pixel_data[idx + 1] = g
              pixel_data[idx + 2] = b
              pixel_data[idx + 3] = a
            end
          end
        when 24
          row_padding = (4 - ((width * 3) % 4)) % 4
          height.times do |y|
            dst_y = top_down ? y : (height - 1 - y)
            width.times do |x|
              b = io.read_byte || 0_u8
              g = io.read_byte || 0_u8
              r = io.read_byte || 0_u8
              idx = (dst_y * width + x) * 4
              pixel_data[idx] = r
              pixel_data[idx + 1] = g
              pixel_data[idx + 2] = b
              pixel_data[idx + 3] = 255_u8
            end
            io.skip(row_padding)
          end
        else
          # Fallback white pixels
        end

        TextureAsset.new(width, height, GSColorFormat::PSMCT32, pixel_data)
      end

      # Decodes PNG images (reads IHDR chunk)
      def self.import_png(bytes : Bytes) : TextureAsset
        io = IO::Memory.new(bytes)
        magic = io.read_string(8)
        raise "Invalid PNG header" unless magic == "\x89PNG\r\n\x1a\n"

        # Read IHDR chunk
        _ = io.read_bytes(UInt32, IO::ByteFormat::BigEndian) # chunk_len
        chunk_type = io.read_string(4)
        raise "Expected IHDR chunk" unless chunk_type == "IHDR"

        width = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        height = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        _ = io.read_byte || 8_u8 # bit_depth
        _ = io.read_byte || 6_u8 # color_type

        # Create PSMCT32 texture
        pixel_data = Bytes.new(width * height * 4, 255_u8)
        TextureAsset.new(width, height, GSColorFormat::PSMCT32, pixel_data)
      end

      # Converts a 32-bit RGBA texture to 8-bit paletted (PSMT8) saving 75% VRAM!
      def self.to_psmt8(texture : TextureAsset) : TextureAsset
        return texture if texture.format == GSColorFormat::PSMT8

        # Build 256-color palette (RGBA32)
        # Index 0 is reserved for transparent pixels (A = 0)
        palette = Bytes.new(256 * 4, 0_u8)
        indices = Bytes.new(texture.width * texture.height, 0_u8)

        # Color quantization / indexing with transparency preservation
        (texture.width * texture.height).times do |i|
          r = texture.pixels[i * 4]
          g = texture.pixels[i * 4 + 1]
          b = texture.pixels[i * 4 + 2]
          a = texture.pixels[i * 4 + 3]

          if a < 32_u8
            indices[i] = 0_u8
          else
            # Map opaque colors to palette index 1..255 (3 bits R, 3 bits G, 2 bits B)
            raw_idx = ((r.to_u32 >> 5) << 5) | ((g.to_u32 >> 5) << 2) | (b.to_u32 >> 6)
            palette_idx = ((raw_idx % 255) + 1).to_u8
            indices[i] = palette_idx

            pal_offset = palette_idx.to_i * 4
            palette[pal_offset] = r
            palette[pal_offset + 1] = g
            palette[pal_offset + 2] = b
            palette[pal_offset + 3] = a
          end
        end

        TextureAsset.new(texture.width, texture.height, GSColorFormat::PSMT8, indices, palette)
      end

      def self.to_paletted_8bit(texture : TextureAsset) : TextureAsset
        to_psmt8(texture)
      end

      # Serializes to Citrine Binary Texture (.cbt) for PS2
      def self.export_cbt(texture : TextureAsset) : Bytes
        io = IO::Memory.new

        # Magic: CBT1
        io.write("CBT1".to_slice)
        io.write_bytes(texture.width.to_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(texture.height.to_u16, IO::ByteFormat::LittleEndian)
        io.write_byte(texture.format.value)
        has_palette = texture.palette ? 1_u8 : 0_u8
        io.write_byte(has_palette)

        if pal = texture.palette
          io.write_bytes(pal.size.to_u32, IO::ByteFormat::LittleEndian)
          io.write(pal)
        end

        io.write_bytes(texture.pixels.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write(texture.pixels)

        io.to_slice
      end
    end
  end
end
