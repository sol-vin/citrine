require "./spec_helper"
require "../src/citrine/importers/cas_encoder"

describe "Citrine Audio Stream (CAS) Encoder & Bitrate Sizing" do
  it "accurately derives sample rate and pitch register for target bitrates" do
    # 192 kbps mono -> 48 kHz, pitch 0x1000
    c192 = Citrine::Importers::CasConfig.new(bitrate: 192_000, channels: 1)
    c192.sample_rate.should eq 48_000
    c192.pitch_reg.should eq 0x1000_u16

    # 128 kbps mono -> 32 kHz, pitch 0x0AAB (2731)
    c128 = Citrine::Importers::CasConfig.new(bitrate: 128_000, channels: 1)
    c128.sample_rate.should eq 32_000
    c128.pitch_reg.should eq 0x0AAB_u16

    # 96 kbps mono (default) -> 24 kHz, pitch 0x0800
    c96 = Citrine::Importers::CasConfig.new(bitrate: 96_000, channels: 1)
    c96.sample_rate.should eq 24_000
    c96.pitch_reg.should eq 0x0800_u16

    # 64 kbps mono -> 16 kHz, pitch 0x0555
    c64 = Citrine::Importers::CasConfig.new(bitrate: 64_000, channels: 1)
    c64.sample_rate.should eq 16_000
    c64.pitch_reg.should eq 0x0555_u16

    # 32 kbps mono (voice) -> 8 kHz, pitch 0x02AB (683)
    c32 = Citrine::Importers::CasConfig.new(bitrate: 32_000, channels: 1)
    c32.sample_rate.should eq 8_000
    c32.pitch_reg.should eq 0x02AB_u16
  end

  it "encodes 16-bit PCM into a valid .cas file with standard 32-byte header" do
    # Generate 1.0 second test sine wave at 44.1 kHz (44,100 samples)
    samples = Array(Int16).new(44100) do |i|
      (Math.sin(2.0 * Math::PI * 440.0 * (i.to_f64 / 44100.0)) * 10000.0).round.to_i16
    end

    sound = Citrine::Importers::SoundAsset.new(44100, 1, 16, samples)
    config = Citrine::Importers::CasConfig.new(bitrate: 96_000, channels: 1)

    cas_bytes = Citrine::Importers::CasEncoder.encode(sound, config)
    cas_bytes.size.should be > 32

    # Read back 32-byte header
    header = Citrine::Importers::CasHeader.read(IO::Memory.new(cas_bytes))
    header.sample_rate.should eq 24_000_u32
    header.pitch_reg.should eq 0x0800_u16
    header.chunk_sectors.should eq 8_u16
    header.flags.should eq 1_u16 # loop flag enabled
    header.duration_ms.should be_close(1000, 20)

    # Payload should be exact multiple of 16-byte ADPCM blocks
    payload_size = cas_bytes.size - 2048
    (payload_size % 16).should eq 0
  end
end
