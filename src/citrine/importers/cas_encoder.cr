require "./sound_importer"

module Citrine
  module Importers
    class CasConfig
      property bitrate : Int32
      property channels : Int32
      property loop_audio : Bool
      property chunk_sectors : UInt16

      def initialize(
        @bitrate : Int32 = 96_000,
        @channels : Int32 = 1,
        @loop_audio : Bool = true,
        @chunk_sectors : UInt16 = 8_u16 # 8 sectors * 2048 bytes = 16,384 bytes (16 KB)
      )
      end

      # Derives optimal SPU2 sample rate from target bitrate and channel count
      def sample_rate : Int32
        if @channels == 2
          case @bitrate
          when .>= 160_000 then 24_000 # 192 kbps stereo
          when .>= 112_000 then 16_000 # 128 kbps stereo
          when .>= 80_000  then 11_025 # 88.2 kbps stereo
          else                  8_000  # 64 kbps stereo
          end
        else
          case @bitrate
          when .>= 180_000 then 48_000 # 192 kbps mono
          when .>= 150_000 then 44_100 # 176.4 kbps mono
          when .>= 112_000 then 32_000 # 128 kbps mono
          when .>= 80_000  then 24_000 # 96 kbps mono (standard default)
          when .>= 56_000  then 16_000 # 64 kbps mono
          when .>= 40_000  then 11_025 # 44.1 kbps mono
          else                  8_000  # 32 kbps mono (speech/voice)
          end
        end
      end

      # Calculates hardware SPU2 pitch register value: (sample_rate * 4096 / 48000)
      def pitch_reg : UInt16
        sr = sample_rate.to_u32
        ((sr * 4096_u32 + 24_000_u32) // 48_000_u32).to_u16
      end
    end

    class CasHeader
      MAGIC = "CAS\1" # Citrine Audio Stream Version 1

      property channels : UInt16
      property flags : UInt16 # Bit 0: loop, Bit 1: stereo
      property sample_rate : UInt32
      property pitch_reg : UInt16
      property chunk_sectors : UInt16
      property total_samples : UInt32
      property total_blocks : UInt32
      property duration_ms : UInt32

      def initialize(
        @channels : UInt16,
        @flags : UInt16,
        @sample_rate : UInt32,
        @pitch_reg : UInt16,
        @chunk_sectors : UInt16,
        @total_samples : UInt32,
        @total_blocks : UInt32,
        @duration_ms : UInt32
      )
      end

      def self.read(io : IO) : CasHeader
        magic = io.read_string(4)
        raise "Invalid CAS header magic: expected 'CAS\\1', got #{magic.inspect}" unless magic == MAGIC

        channels = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        flags = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        sample_rate = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        pitch_reg = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        chunk_sectors = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        total_samples = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        total_blocks = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        duration_ms = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

        # Skip reserved 4 bytes (pad to 32 bytes total)
        _reserved = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

        new(
          channels: channels,
          flags: flags,
          sample_rate: sample_rate,
          pitch_reg: pitch_reg,
          chunk_sectors: chunk_sectors,
          total_samples: total_samples,
          total_blocks: total_blocks,
          duration_ms: duration_ms
        )
      end

      def write(io : IO)
        io.write(MAGIC.to_slice)
        io.write_bytes(@channels, IO::ByteFormat::LittleEndian)
        io.write_bytes(@flags, IO::ByteFormat::LittleEndian)
        io.write_bytes(@sample_rate, IO::ByteFormat::LittleEndian)
        io.write_bytes(@pitch_reg, IO::ByteFormat::LittleEndian)
        io.write_bytes(@chunk_sectors, IO::ByteFormat::LittleEndian)
        io.write_bytes(@total_samples, IO::ByteFormat::LittleEndian)
        io.write_bytes(@total_blocks, IO::ByteFormat::LittleEndian)
        io.write_bytes(@duration_ms, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian) # 4 bytes reserved
      end
    end

    class CasEncoder
      # Encodes a SoundAsset into standard Citrine Audio Stream (.cas) bytes
      def self.encode(sound : SoundAsset, config : CasConfig = CasConfig.new) : Bytes
        target_sr = config.sample_rate
        # Linear PCM resampling if needed
        resampled_samples = if sound.sample_rate == target_sr
                              sound.pcm_samples
                            else
                              resample_pcm(sound.pcm_samples, sound.sample_rate, target_sr)
                            end

        resampled_sound = SoundAsset.new(target_sr, config.channels, 16, resampled_samples)
        adpcm_blocks = SoundImporter.encode_raw_blocks(resampled_sound, loop_audio: config.loop_audio)

        total_blocks = (adpcm_blocks.size // 16).to_u32
        total_samples = total_blocks * 28_u32
        duration_ms = ((total_samples.to_f64 / target_sr.to_f64) * 1000.0).round.to_u32

        flags = 0_u16
        flags |= 0x0001_u16 if config.loop_audio
        flags |= 0x0002_u16 if config.channels == 2

        header = CasHeader.new(
          channels: config.channels.to_u16,
          flags: flags,
          sample_rate: target_sr.to_u32,
          pitch_reg: config.pitch_reg,
          chunk_sectors: config.chunk_sectors,
          total_samples: total_samples,
          total_blocks: total_blocks,
          duration_ms: duration_ms
        )

        io = IO::Memory.new(2048 + adpcm_blocks.size)
        header.write(io)
        # Pad header sector to exactly 2048 bytes (1 CD-ROM sector) for sector-aligned zero-latency streaming
        (2048 - 32).times { io.write_byte(0_u8) }
        io.write(adpcm_blocks)
        io.to_slice
      end

      # High-performance linear interpolation PCM resampler
      private def self.resample_pcm(samples : Array(Int16), from_sr : Int32, to_sr : Int32) : Array(Int16)
        return samples if from_sr == to_sr || samples.empty?

        ratio = from_sr.to_f64 / to_sr.to_f64
        out_count = (samples.size.to_f64 / ratio).floor.to_i
        resampled = Array(Int16).new(out_count)

        out_count.times do |i|
          src_pos = i.to_f64 * ratio
          idx0 = src_pos.floor.to_i
          frac = src_pos - idx0.to_f64

          idx1 = Math.min(idx0 + 1, samples.size - 1)
          s0 = samples[idx0].to_f64
          s1 = samples[idx1].to_f64

          interp = s0 + frac * (s1 - s0)
          resampled << interp.round.clamp(-32768.0, 32767.0).to_i16
        end

        resampled
      end
    end
  end
end
