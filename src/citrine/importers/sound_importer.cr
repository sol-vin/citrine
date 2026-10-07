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
            num_raw_samples = chunk_size // (bit_depth // 8)
            if channels > 1
              num_frames = num_raw_samples // channels
              num_frames.times do
                sum = 0_i64
                channels.times do
                  if bit_depth == 16
                    sum += io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_i64
                  else
                    b = io.read_byte || 128_u8
                    sum += ((b.to_i - 128) << 8).to_i64
                  end
                end
                samples << (sum // channels).clamp(-32768_i64, 32767_i64).to_i16
              end
              channels = 1
            else
              num_raw_samples.times do
                if bit_depth == 16
                  s = io.read_bytes(Int16, IO::ByteFormat::LittleEndian)
                  samples << s
                else
                  b = io.read_byte || 128_u8
                  s = ((b.to_i - 128) << 8).to_i16
                  samples << s
                end
              end
            end
          else
            io.skip(chunk_size)
          end
        end

        SoundAsset.new(sample_rate, channels, bit_depth, samples)
      end

      FILTER_COEFFS = [
        { 0.0,          0.0 },
        { 60.0 / 64.0,  0.0 },
        { 115.0 / 64.0, -52.0 / 64.0 },
        { 98.0 / 64.0,  -55.0 / 64.0 },
        { 122.0 / 64.0, -60.0 / 64.0 }
      ]

      # Encodes 16-bit PCM into raw PlayStation 2 SPU2 ADPCM blocks
      # 16-byte blocks containing 28 4-bit nibbles with optimal Sony ADPCM predictive filtering
      def self.encode_raw_blocks(sound : SoundAsset, loop_audio : Bool = false) : Bytes
        io = IO::Memory.new
        samples = sound.pcm_samples
        total_samples = samples.size
        num_blocks = (total_samples + 27) // 28

        s1 = 0.0
        s2 = 0.0

        num_blocks.times do |b_idx|
          is_first = (b_idx == 0)
          is_last = (b_idx == num_blocks - 1)

          flags = 0_u8
          if loop_audio
            flags |= 0x02_u8 # Bit 1: Loop Repeat is REQUIRED on all blocks in SPU2 looping stream!
            flags |= 0x04_u8 if is_first # Bit 2: Loop Start (0x06 total on first block)
            flags |= 0x01_u8 if is_last  # Bit 0: Loop End (0x03 total on last block)
          elsif is_last
            flags |= 0x01_u8 # End flag without repeat (0x01 = End + Mute)
          end

          # Get 28 source samples for this block
          block_samples = Array(Float64).new(28)
          28.times do |i|
            idx = b_idx * 28 + i
            s = idx < samples.size ? samples[idx].to_f64 : 0.0
            block_samples << s
          end

          best_filter = 0
          best_shift = 0
          best_error = Float64::INFINITY
          best_nibbles = Array(Int32).new(28, 0)
          best_s1 = s1
          best_s2 = s2

          5.times do |filt|
            c0, c1 = FILTER_COEFFS[filt]

            # Calculate prediction errors for this filter
            errors = Array(Float64).new(28)
            sim_s1 = s1
            sim_s2 = s2

            28.times do |i|
              pred = sim_s1 * c0 + sim_s2 * c1
              err = block_samples[i] - pred
              errors << err
              sim_s2 = sim_s1
              sim_s1 = block_samples[i]
            end

            # Find finest shift factor (12 down to 0) to fit max/min error in signed 4-bit (-8..7)
            max_err = errors.max
            min_err = errors.min
            shift = 12
            while shift > 0
              limit_pos = (7 << (12 - shift)).to_f64
              limit_neg = (-8 << (12 - shift)).to_f64
              break if min_err >= limit_neg && max_err <= limit_pos
              shift -= 1
            end

            scale = (1 << (12 - shift)).to_f64

            # Quantize and compute reconstruction error
            trial_s1 = s1
            trial_s2 = s2
            total_err = 0.0
            nibbles = Array(Int32).new(28)

            28.times do |i|
              pred = trial_s1 * c0 + trial_s2 * c1
              err = block_samples[i] - pred
              raw_nibble = (err / scale).round.to_i
              clamped_nibble = raw_nibble.clamp(-8, 7)
              nibbles << clamped_nibble

              decoded = (pred + clamped_nibble * scale).clamp(-32768.0, 32767.0)
              total_err += (block_samples[i] - decoded) ** 2

              trial_s2 = trial_s1
              trial_s1 = decoded
            end

            if total_err < best_error
              best_error = total_err
              best_filter = filt
              best_shift = shift
              best_nibbles = nibbles
              best_s1 = trial_s1
              best_s2 = trial_s2
            end
          end

          # Write header byte 0: (filter << 4) | shift
          hdr0 = ((best_filter << 4) | (best_shift & 0x0F)).to_u8
          io.write_byte(hdr0)
          io.write_byte(flags)

          # Write 14 bytes (28 nibbles: low nibble = even, high nibble = odd)
          14.times do |i|
            n0 = best_nibbles[i * 2] & 0x0F
            n1 = best_nibbles[i * 2 + 1] & 0x0F
            byte = (n1 << 4) | n0
            io.write_byte(byte.to_u8)
          end

          s1 = best_s1
          s2 = best_s2
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
        12.times { io.write_byte(0_u8) } # Reserved (12 bytes)
        name_bytes = Bytes.new(16, 0_u8)
        copy_len = {name.bytesize, 15}.min
        name.to_slice[0, copy_len].copy_to(name_bytes)
        io.write(name_bytes)
        io.write(blocks)

        io.to_slice
      end
    end
  end
end
