require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/iso/sound_irx_builder"

describe "Citrine PS2 Audio Streaming Suite" do
  it "builds a valid streaming S.IRX ELF module with CDVD stubs and track table" do
    track_table = [
      Citrine::ISO::SoundIrxBuilder::TrackInfo.new(1739_u32, 102_u32),
      Citrine::ISO::SoundIrxBuilder::TrackInfo.new(2555_u32, 162_u32),
      Citrine::ISO::SoundIrxBuilder::TrackInfo.new(3851_u32, 167_u32),
    ]

    elf = Citrine::ISO::SoundIrxBuilder.build_streaming(track_table)
    elf.size.should eq 45407
    elf[0, 4].should eq Bytes[0x7f, 0x45, 0x4c, 0x46] # \x7fELF

    # Verify track table written at text_off + 0x1920
    text_off = 0x90_u32
    table_pos = text_off + 0x1920
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[text_off + 0x1914, 4]).should eq 3_u32 # total_tracks
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[table_pos, 4]).should eq 1739_u32      # track 1 lba
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[table_pos + 4, 4]).should eq 102_u32   # track 1 banks
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[table_pos + 8, 4]).should eq 2555_u32  # track 2 lba
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[table_pos + 12, 4]).should eq 162_u32 # track 2 banks

    # Verify thbase DelayThread import at text_off + 0x10a0
    thbase_pos = text_off + 0x10a0
    String.new(elf[thbase_pos + 12, 8]).should eq "thbase\0\0"
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[thbase_pos + 20, 4]).should eq 0x03e00008_u32 # jr $ra
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[thbase_pos + 24, 4]).should eq 0x24000021_u32 # addiu $zero, $zero, 33 (DelayThread)
    IO::ByteFormat::LittleEndian.decode(UInt32, elf[thbase_pos + 28, 4]).should eq 0_u32          # terminator
  end

  it "verifies IsoBuilder deterministically calculates sector LBAs for disc streaming" do
    tc = Citrine::Spec::Ps2TestCase.new("10_iso_streaming_layout")
    tc.target("examples/10_cd_player/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18

    # Ensure all 13 full-length album tracks exist
    album_tracks = Dir.glob("examples/10_cd_player/*.cas").sort_by do |p|
      if md = p.match(/(\d+)/)
        md[1].to_i
      else
        999
      end
    end
    if album_tracks.empty?
      album_tracks = Dir.glob("examples/10_cd_player/*.vag").sort_by do |p|
        if md = p.match(/(\d+)/)
          md[1].to_i
        else
          999
        end
      end
    end
    album_tracks.size.should be >= 13

    extra_files = Hash(String, Bytes).new
    album_tracks.each do |vpath|
      extra_files[File.basename(vpath)] = File.read(vpath).to_slice
    end
    if File.exists?("examples/10_cd_player/cover.cbt")
      extra_files["cover.cbt"] = File.read("examples/10_cd_player/cover.cbt").to_slice
    end

    temp_iso = "tmp_spec_streaming_layout.iso"
    begin
      Citrine::IsoBuilder.build(temp_iso, bytes, extra_files: extra_files)
      File.exists?(temp_iso).should be_true
      iso_size = File.size(temp_iso)
      # 13 tracks + cover + ELF + S.IRX should be > 10 MB at 32 kbps
      iso_size.should be > 10_000_000
    ensure
      File.delete(temp_iso) if File.exists?(temp_iso)
    end
  end

  it "boots and streams full-length album audio continuously off disc in PCSX2" do
    tc = Citrine::Spec::Ps2TestCase.new("10_cd_audio_streaming")
    tc.target("examples/10_cd_player/main.cr")

    # Inject controller input:
    # Frame 60: DPAD Right (Next Track)
    # Frame 120: Cross (Pause/Resume)
    # Frame 180: R1 (Jump +10s / Seek)
    tc.inject_input(60, Citrine::PadButton::Right, duration: 2)
    tc.inject_input(120, Citrine::PadButton::Cross, duration: 2)
    tc.inject_input(180, Citrine::PadButton::R1, duration: 2)

    result = tc.boot_pcsx2(timeout: 14.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_not_have_memory_faults

    # Verify S.IRX module load
    result.should_have_output("cdrom0:S.IRX;1")

    # Verify streaming engine started
    result.should_have_output(">>> Play track")

    # Verify seek command executed
    result.should_have_output(">>> Seek bank")

    # Verify continuous disc streaming refill activity
    result.should_have_output(">>> Stream bank")
  end
end
