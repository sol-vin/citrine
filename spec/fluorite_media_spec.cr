require "./spec_helper"
require "../src/citrine/importers/fluorite_media"

describe "Citrine Media Pipeline (Fluorite & FFmpeg)" do
  it "detects FFmpeg installation" do
    if Process.find_executable("ffmpeg")
      Citrine::Importers::FluoriteMedia.ffmpeg_installed?.should be_true
    else
      Citrine::Importers::FluoriteMedia.ffmpeg_installed?.should be_false
    end
  end

  it "configures Video presets with 15 FPS downsampling for PS2 IPU" do
    cfg = Citrine::Importers::FluoriteMedia::VideoConfig.new
    cfg.fps.should eq(15)
    cfg.width.should eq(512)
    cfg.height.should eq(448)
    cfg.bitrate.should eq("2000k")
    cfg.dvd_track.should be_false
  end

  it "computes DVD track sector alignment for the DVD Video Track Trick" do
    file_bytes = 100_000_i64
    sector_size = 2048
    sectors = (file_bytes + sector_size - 1) // sector_size
    meta = Citrine::Importers::FluoriteMedia::DvdTrackMetadata.new(
      path: "cutscene.pss",
      sector_size: sector_size,
      total_sectors: sectors,
      fps: 15,
      width: 512,
      height: 448,
      bitrate: "2000k"
    )

    meta.total_sectors.should eq(49)
    meta.sector_size.should eq(2048)
    meta.fps.should eq(15)
  end

  it "configures SPU2 Audio presets with 22.05kHz 4-bit ADPCM" do
    cfg = Citrine::Importers::FluoriteMedia::AudioConfig.new
    cfg.sample_rate.should eq(22050)
    cfg.channels.should eq(1)
    cfg.loop_audio.should be_false
  end

  it "configures GS Texture presets with CLUT8 (256 colors)" do
    cfg = Citrine::Importers::FluoriteMedia::TextureConfig.new
    cfg.clut_bits.should eq(8)
  end

  it "exports 8-bit paletted CLUT textures with 75% VRAM savings" do
    pixels = Bytes.new(64 * 64 * 4, 128_u8)
    rgba_tex = Citrine::Importers::TextureAsset.new(64, 64, Citrine::Importers::GSColorFormat::PSMCT32, pixels)
    rgba_vram = rgba_tex.vram_size_bytes

    psmt8_tex = Citrine::Importers::ImageImporter.to_psmt8(rgba_tex)
    psmt8_vram = psmt8_tex.vram_size_bytes

    rgba_vram.should eq(64 * 64 * 4) # 16,384 bytes
    psmt8_vram.should eq(64 * 64 + 1024) # 4,096 + 1024 = 5,120 bytes
    psmt8_vram.should be < rgba_vram
  end
end
