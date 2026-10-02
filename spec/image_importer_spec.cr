require "./spec_helper"

describe Citrine::Importers::ImageImporter do
  it "imports 24-bit BMP image into PSMCT32 texture" do
    # Minimal 2x2 24-bit BMP
    # File Header: 14 bytes
    # DIB Header: 40 bytes
    # Pixels: 2x2 RGB + 2 bytes padding per row = 8 + 4 = 12 bytes
    bmp_io = IO::Memory.new
    bmp_io.write("BM".to_slice)
    bmp_io.write_bytes(66_u32, IO::ByteFormat::LittleEndian) # file_size
    bmp_io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)  # reserved
    bmp_io.write_bytes(54_u32, IO::ByteFormat::LittleEndian) # offset to pixels

    # DIB header (BITMAPINFOHEADER: 40 bytes)
    bmp_io.write_bytes(40_u32, IO::ByteFormat::LittleEndian)
    bmp_io.write_bytes(2_i32, IO::ByteFormat::LittleEndian)   # width
    bmp_io.write_bytes(2_i32, IO::ByteFormat::LittleEndian)   # height
    bmp_io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)   # planes
    bmp_io.write_bytes(24_u16, IO::ByteFormat::LittleEndian)  # bpp
    bmp_io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)   # compression
    bmp_io.write_bytes(12_u32, IO::ByteFormat::LittleEndian)  # image size
    bmp_io.write_bytes(2835_i32, IO::ByteFormat::LittleEndian)
    bmp_io.write_bytes(2835_i32, IO::ByteFormat::LittleEndian)
    bmp_io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
    bmp_io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)

    # Row 1: 2 pixels (BGR) + 2 bytes padding
    bmp_io.write(Bytes[255, 0, 0, 0, 255, 0, 0, 0])
    # Row 2: 2 pixels (BGR) + 2 bytes padding
    bmp_io.write(Bytes[0, 0, 255, 255, 255, 0, 0, 0])

    texture = Citrine::Importers::ImageImporter.import_bmp(bmp_io.to_slice)
    texture.width.should eq(2)
    texture.height.should eq(2)
    texture.format.should eq(Citrine::Importers::GSColorFormat::PSMCT32)
    texture.vram_size_bytes.should eq(16) # 2x2 x 4 bytes

    # Convert to Citrine Binary Texture (.cbt)
    cbt_bytes = texture.to_cbt
    String.new(cbt_bytes[0..3]).should eq("CBT1")
  end

  it "converts 32-bit RGBA texture to 8-bit paletted (PSMT8) saving 75% VRAM" do
    # Create 8x8 RGBA texture with 4 colors
    rgba_data = Bytes.new(8 * 8 * 4)
    (8 * 8).times do |i|
      rgba_data[i * 4] = ((i % 4) * 60).to_u8
      rgba_data[i * 4 + 1] = 120_u8
      rgba_data[i * 4 + 2] = 200_u8
      rgba_data[i * 4 + 3] = 255_u8
    end

    tex_32 = Citrine::Importers::TextureAsset.new(8, 8, Citrine::Importers::GSColorFormat::PSMCT32, rgba_data)
    tex_8 = Citrine::Importers::ImageImporter.to_psmt8(tex_32)

    tex_8.format.should eq(Citrine::Importers::GSColorFormat::PSMT8)
    tex_8.palette.should_not be_nil
    # 8x8 indexed bytes = 64 bytes (vs 256 bytes for RGBA32)
    tex_8.pixels.size.should eq(64)
  end
end
