require "./spec_helper"
require "../src/citrine/importers/fluorite_media"
require "../src/citrine/iso/iso_builder"

describe "Citrine CD-DA Audio & Mixed-Mode Disc Pipeline" do
  it "encodes audio to Red Book CD-DA raw PCM sector-aligned stream" do
    pending! "FFmpeg is required for CD-DA audio transcode testing" unless Citrine::Importers::FluoriteMedia.ffmpeg_installed?

    # Generate 1 second 44.1kHz stereo test WAV
    temp_wav = "temp_cdda_test.wav"
    temp_raw = "temp_cdda_test.raw"

    begin
      sample_rate = 44100
      channels = 2
      duration = 1.0
      num_samples = (sample_rate * channels * duration).to_i

      File.open(temp_wav, "wb") do |f|
        f.write("RIFF".to_slice)
        f.write_bytes((36 + num_samples * 2).to_u32, IO::ByteFormat::LittleEndian)
        f.write("WAVE".to_slice)
        f.write("fmt ".to_slice)
        f.write_bytes(16_u32, IO::ByteFormat::LittleEndian)
        f.write_bytes(1_u16, IO::ByteFormat::LittleEndian) # PCM
        f.write_bytes(channels.to_u16, IO::ByteFormat::LittleEndian)
        f.write_bytes(sample_rate.to_u32, IO::ByteFormat::LittleEndian)
        f.write_bytes((sample_rate * channels * 2).to_u32, IO::ByteFormat::LittleEndian)
        f.write_bytes((channels * 2).to_u16, IO::ByteFormat::LittleEndian)
        f.write_bytes(16_u16, IO::ByteFormat::LittleEndian)
        f.write("data".to_slice)
        f.write_bytes((num_samples * 2).to_u32, IO::ByteFormat::LittleEndian)
        num_samples.times { f.write_bytes(0_i16, IO::ByteFormat::LittleEndian) }
      end

      # Transcode to CD-DA
      success = Citrine::Importers::FluoriteMedia.convert_cdda(temp_wav, temp_raw)
      success.should be_true
      File.exists?(temp_raw).should be_true

      # Verify 2,352-byte Red Book sector alignment
      raw_size = File.size(temp_raw)
      (raw_size % 2352).should eq(0)
      (raw_size > 0).should be_true
    ensure
      File.delete(temp_wav) if File.exists?(temp_wav)
      File.delete(temp_raw) if File.exists?(temp_raw)
    end
  end

  it "generates Mixed-Mode CUE sheet with Track 1 Data and Track 2 Audio" do
    temp_iso = "temp_cdda_test.iso"
    temp_cue = "temp_cdda_test.cue"
    temp_track2 = "temp_track02.raw"

    begin
      # Create dummy audio track
      File.open(temp_track2, "wb") do |f|
        2352.times { f.write_byte(0_u8) }
      end

      cbc_dummy = Bytes.new(64, 0_u8)
      Citrine::IsoBuilder.build(temp_iso, cbc_dummy, audio_tracks: [temp_track2])

      File.exists?(temp_iso).should be_true
      File.exists?(temp_cue).should be_true

      cue_text = File.read(temp_cue)
      cue_text.should contain(%(FILE "temp_cdda_test.iso" BINARY))
      cue_text.should contain(%(TRACK 01 MODE1/2048))
      cue_text.should contain(%(FILE "temp_track02.raw" BINARY))
      cue_text.should contain(%(TRACK 02 AUDIO))
      cue_text.should contain(%(INDEX 01 00:00:00))
    ensure
      File.delete(temp_iso) if File.exists?(temp_iso)
      File.delete(temp_cue) if File.exists?(temp_cue)
      File.delete(temp_track2) if File.exists?(temp_track2)
    end
  end

  it "compiles CD-DA optical audio commands in bytecode" do
    source = <<-CR
      require "citrine"
      Citrine.play_cdda_track(2)
      status = Citrine.cdda_status
      Citrine.stop_cdda
    CR

    parser = Citrine::DslParser.new("audio.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("audio.cr")
    cbc_bytes = compiler.compile(program)
    cbc_bytes.size.should be > 16

    main_fn = compiler.functions.last
    instructions = main_fn.instructions
    opcodes = instructions.map(&.opcode)
    opcodes.should contain(Citrine::Opcode::CallNative)
  end
end
