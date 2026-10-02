require "./spec_helper"

describe Citrine::Importers::SoundImporter do
  it "imports standard WAV PCM and encodes to PS2 SPU2 ADPCM / VAG blocks" do
    # Build 16-bit 44.1kHz mono WAV with 56 samples (exactly 2 VAG blocks: 28 samples per block)
    wav_io = IO::Memory.new
    wav_io.write("RIFF".to_slice)
    data_size = 56 * 2 # 112 bytes
    wav_io.write_bytes((36 + data_size).to_u32, IO::ByteFormat::LittleEndian)
    wav_io.write("WAVE".to_slice)

    # "fmt " chunk
    wav_io.write("fmt ".to_slice)
    wav_io.write_bytes(16_u32, IO::ByteFormat::LittleEndian) # chunk size
    wav_io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)  # PCM format
    wav_io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)  # 1 channel (mono)
    wav_io.write_bytes(44100_u32, IO::ByteFormat::LittleEndian) # sample rate
    wav_io.write_bytes((44100 * 2).to_u32, IO::ByteFormat::LittleEndian) # byte rate
    wav_io.write_bytes(2_u16, IO::ByteFormat::LittleEndian)  # block align
    wav_io.write_bytes(16_u16, IO::ByteFormat::LittleEndian) # bits per sample

    # "data" chunk
    wav_io.write("data".to_slice)
    wav_io.write_bytes(data_size.to_u32, IO::ByteFormat::LittleEndian)
    56.times do |i|
      sample = (Math.sin(i.to_f * 0.1) * 10000.0).to_i16
      wav_io.write_bytes(sample, IO::ByteFormat::LittleEndian)
    end

    sound = Citrine::Importers::SoundImporter.import_wav(wav_io.to_slice)
    sound.sample_rate.should eq(44100)
    sound.channels.should eq(1)
    sound.pcm_samples.size.should eq(56)

    # Encode to SPU2 ADPCM
    vag_blocks = Citrine::Importers::SoundImporter.encode_spu2_adpcm(sound)
    # Each SPU2 block is 16 bytes representing 28 samples
    # 56 samples -> exactly 2 blocks = 32 bytes (4:1 compression from 112 bytes)
    vag_blocks.size.should eq(32)
    (vag_blocks.size % 16).should eq(0)

    # Export to .vag container
    vag_file = Citrine::Importers::SoundImporter.to_vag(sound, "sine_wave")
    String.new(vag_file[0..3]).should eq("VAGp")
  end
end
