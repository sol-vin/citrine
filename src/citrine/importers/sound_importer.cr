module Citrine
  module Importers
    class SoundAsset
      property sample_rate : Int32
      property channels : Int32
      property bit_depth : Int32
      property pcm_samples : Array(Int16)

      def initialize(@sample_rate : Int32, @channels : Int32, @bit_depth : Int32, @pcm_samples : Array(Int16))
      end

      def duration_seconds : Float32
        return 0.0_f32 if @sample_rate == 0 || @channels == 0
        (@pcm_samples.size / (@sample_rate * @channels)).to_f32
      end

      def to_vag(name : String = "sound", loop_audio : Bool = false) : Bytes
        SoundImporter.to_vag(self, name, loop_audio)
      end
    end

    class SoundImporter
      # Parses standard RIFF WAV files
      def self.import_wav(bytes : Bytes) : SoundAsset
        io = IO::Memory.new(bytes)
        riff = io.read_string(4)
        raise "Invalid WAV: expected RIFF header" unless riff == "RIFF"

        _ = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # file_len
        wave = io.read_string(4)
        raise "Invalid WAV: expected WAVE format" unless wave == "WAVE"

        channels = 1
        sample_rate = 44100
        bit_depth = 16
        samples = [] of Int16

        while io.pos < bytes.size - 8
          chunk_id = io.read_string(4)
          chunk_size = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

          case chunk_id
          when "fmt "
            _ = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian) # format_tag
            channels = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i
            sample_rate = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i
            _ = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # avg_bps
            _ = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian) # block_align
            bit_depth = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i

            # Skip extra fmt bytes if any
            extra = chunk_size - 16
            io.skip(extra) if extra > 0
          when "data"
            num_samples = chunk_size // (bit_depth // 8)
            num_samples.times do
              if bit_depth == 16
                s = io.read_bytes(Int16, IO::ByteFormat::LittleEndian)
                samples << s
              else
                # 8-bit unsigned to 16-bit signed
                b = io.read_byte || 128_u8
                s = ((b.to_i - 128) << 8).to_i16
                samples << s
              end
            end
          else
            io.skip(chunk_size)
          end
        end

        SoundAsset.new(sample_rate, channels, bit_depth, samples)
      end

      # Encodes 16-bit PCM into raw PlayStation 2 SPU2 ADPCM blocks
      # 16-byte blocks containing 28 4-bit nibbles (4:1 compression saving 75% SPU2 RAM!)
      def self.encode_raw_blocks(sound : SoundAsset, loop_audio : Bool = false) : Bytes
        io = IO::Memory.new
        total_samples = sound.pcm_samples.size
        num_blocks = (total_samples + 27) // 28

        num_blocks.times do |b_idx|
          is_first = (b_idx == 0)
          is_last = (b_idx == num_blocks - 1)

          flags = 0_u8
          flags |= 0x02 if is_first && loop_audio # Loop start
          flags |= 0x01 if is_last # Loop end / Stop flag
          flags |= 0x02 if is_last && loop_audio # Loop repeat

          # Shift / Predictor factor (0x0C = standard shift)
          shift_factor = 0x0C_u8
          io.write_byte(shift_factor)
          io.write_byte(flags)

          # 14 bytes = 28 4-bit nibbles
          14.times do |byte_i|
            s_idx1 = b_idx * 28 + byte_i * 2
            s_idx2 = b_idx * 28 + byte_i * 2 + 1

            s1 = sound.pcm_samples[s_idx1]? || 0_i16
            s2 = sound.pcm_samples[s_idx2]? || 0_i16

            # Compress 16-bit to 4-bit nibble
            nibble1 = ((s1 >> 12) & 0x0F).to_u8
            nibble2 = ((s2 >> 12) & 0x0F).to_u8

            io.write_byte((nibble2 << 4) | nibble1)
          end
        end

        io.to_slice
      end

      def self.encode_spu2_adpcm(sound : SoundAsset, loop_audio : Bool = false) : Bytes
        encode_raw_blocks(sound, loop_audio)
      end

      # Packages SPU2 ADPCM blocks into standard PlayStation 2 .vag file
      def self.to_vag(sound : SoundAsset, name : String = "sound", loop_audio : Bool = false) : Bytes
        io = IO::Memory.new

        # SPU2 VAG Header (48 bytes)
        io.write("VAGp".to_slice)
        io.write_bytes(0x00000004_u32, IO::ByteFormat::BigEndian) # Version 4
        io.write_bytes(0_u32, IO::ByteFormat::BigEndian)          # Reserved
        blocks = encode_raw_blocks(sound, loop_audio)
        io.write_bytes(blocks.size.to_u32, IO::ByteFormat::BigEndian) # Data size
        io.write_bytes(sound.sample_rate.to_u32, IO::ByteFormat::BigEndian)
        12.times { io.write_bytes(0_u16, IO::ByteFormat::BigEndian) } # Reserved / Name
        io.write(blocks)

        io.to_slice
      end
    end
  end
end
