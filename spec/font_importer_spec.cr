require "./spec_helper"

describe Citrine::Importers::FontImporter do
  it "imports AngelCode .fnt file and metrics" do
    fnt_text = <<-FNT
    info face="Arial" size=16 bold=0 italic=0
    common lineHeight=20 base=15 scaleW=256 scaleH=256 pages=1
    page id=0 file="arial_0.png"
    chars count=3
    char id=65 x=0 y=0 width=12 height=16 xoffset=0 yoffset=2 xadvance=13 page=0
    char id=66 x=14 y=0 width=11 height=16 xoffset=1 yoffset=2 xadvance=13 page=0
    char id=67 x=27 y=0 width=12 height=16 xoffset=0 yoffset=2 xadvance=13 page=0
    FNT

    font = Citrine::Importers::FontImporter.import_fnt(fnt_text, "arial")
    font.name.should eq("arial")
    font.line_height.should eq(20)
    font.base.should eq(15)
    font.glyphs.size.should eq(3)
    font['A'].xadvance.should eq(13)
    font['B'].width.should eq(11)

    cbf_bytes = font.to_cbf
    String.new(cbf_bytes[0..3]).should eq("CBF1")
  end

  it "parses TrueType SFNT directory structure and produces 256x256 GS atlas" do
    # Build minimal valid TrueType SFNT header: 12-byte header + 1 table record (16 bytes)
    ttf_io = IO::Memory.new
    # scalarType: 0x00010000 (OpenType / TrueType 1.0)
    ttf_io.write(Bytes[0x00, 0x01, 0x00, 0x00])
    ttf_io.write_bytes(1_u16, IO::ByteFormat::BigEndian) # numTables = 1
    ttf_io.write_bytes(16_u16, IO::ByteFormat::BigEndian) # searchRange
    ttf_io.write_bytes(1_u16, IO::ByteFormat::BigEndian) # entrySelector
    ttf_io.write_bytes(0_u16, IO::ByteFormat::BigEndian) # rangeShift

    # Table record: tag="head", checkSum=0, offset=28, length=54
    ttf_io.write("head".to_slice)
    ttf_io.write_bytes(0_u32, IO::ByteFormat::BigEndian)
    ttf_io.write_bytes(28_u32, IO::ByteFormat::BigEndian)
    ttf_io.write_bytes(54_u32, IO::ByteFormat::BigEndian)

    # 54 bytes of dummy head table
    54.times { ttf_io.write_byte(0_u8) }

    font = Citrine::Importers::FontImporter.import_ttf(ttf_io.to_slice, point_size: 16, name: "truetype_test")
    font.texture_w.should eq(256)
    font.texture_h.should eq(256)
    font.glyphs.size.should be > 0
    font.has_key?('A').should be_true
    font.has_key?('Z').should be_true

    cbf = font.to_cbf
    String.new(cbf[0..3]).should eq("CBF1")
  end
end
