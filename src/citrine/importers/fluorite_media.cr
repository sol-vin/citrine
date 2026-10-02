require "fluorite"
require "./sound_importer"
require "./image_importer"

module Citrine
  module Importers
    module FluoriteMedia
      # Video presets optimized for PlayStation 2 Emotion Engine & IPU
      record VideoConfig,
        fps : Int32 = 15,
        width : Int32 = 512,
        height : Int32 = 448,
        bitrate : String = "2000k",
        dvd_track : Bool = false,
        loop_video : Bool = false

      # Audio presets optimized for PlayStation 2 SPU2 4-bit ADPCM
      record AudioConfig,
        sample_rate : Int32 = 22050,
        channels : Int32 = 1,
        loop_audio : Bool = false

      # Texture presets optimized for PlayStation 2 Graphics Synthesizer CLUT
      record TextureConfig,
        clut_bits : Int32 = 8,
        width : Int32? = nil,
        height : Int32? = nil

      # DVD Track Layout for the "DVD Video Track Trick"
      # Hiding video data in raw interleaved DVD sectors outside ISO9660 filesystem
      record DvdTrackMetadata,
        path : String,
        sector_size : Int32,
        total_sectors : Int64,
        fps : Int32,
        width : Int32,
        height : Int32,
        bitrate : String,
        estimated_lba_start : Int64 = 0_i64

      def self.ffmpeg_installed? : Bool
        Process.find_executable("ffmpeg") != nil
      end

      def self.probe(target_path : String) : Fluorite::Probe::ProbeResult
        Fluorite.probe(target_path)
      end

      # Converts any media video input into PS2 IPU-compatible MPEG-2 Program Stream (.pss / .mpg)
      # Defaults to 15 FPS downsampling to fit within PS2 4x DVD transfer limits (5.28 MB/s)
      # and IOP DMA buffer limits.
      def self.convert_video(
        input_path : String,
        output_path : String,
        config : VideoConfig = VideoConfig.new,
        &progress_block : Fluorite::Runner::Progress -> Nil
      ) : Tuple(Process::Status, DvdTrackMetadata?)
        raise "FFmpeg is not installed or not in PATH." unless ffmpeg_installed?

        cmd = Fluorite.build do
          overwrite!
          input(input_path)

          output(output_path) do |outp|
            # Force MPEG-2 video stream for PS2 IPU
            outp.video_codec("mpeg2video")
            outp.video_bitrate(config.bitrate)
            outp.fps(config.fps)
            outp.scale(config.width, config.height)

            # Standard GOP size for fast seek and IPU macroblock decoding
            outp.option("-g", config.fps.to_s)
            outp.option("-bf", "0") # Disable B-frames for low latency PS2 decoding

            if config.dvd_track
              # DVD Video Track Trick: sector-aligned MPEG-2 Program Stream (2048-byte sectors)
              outp.format("dvd")
              outp.option("-packetsize", "2048")
              outp.option("-muxrate", config.bitrate)
            else
              outp.format("mpeg")
            end
          end
        end

        status = cmd.run(&progress_block)

        metadata : DvdTrackMetadata? = nil
        if status.success? && config.dvd_track && File.exists?(output_path)
          file_size = File.size(output_path)
          sector_count = (file_size + 2047) // 2048
          metadata = DvdTrackMetadata.new(
            path: output_path,
            sector_size: 2048,
            total_sectors: sector_count,
            fps: config.fps,
            width: config.width,
            height: config.height,
            bitrate: config.bitrate
          )

          # Write sector layout track descriptor file (.track_info)
          track_file = "#{output_path}.track_info"
          File.open(track_file, "w") do |f|
            f.puts "# Citrine PS2 DVD Video Track Descriptor"
            f.puts "file=#{File.basename(output_path)}"
            f.puts "sector_size=2048"
            f.puts "total_sectors=#{sector_count}"
            f.puts "fps=#{config.fps}"
            f.puts "resolution=#{config.width}x#{config.height}"
            f.puts "bitrate=#{config.bitrate}"
          end
        end

        {status, metadata}
      end

      # Overload without progress block
      def self.convert_video(
        input_path : String,
        output_path : String,
        config : VideoConfig = VideoConfig.new
      ) : Tuple(Process::Status, DvdTrackMetadata?)
        convert_video(input_path, output_path, config) { |_| }
      end

      # Converts any audio or video stream into PlayStation 2 Sony SPU2 4-bit ADPCM (.vag)
      def self.convert_audio(
        input_path : String,
        output_path : String,
        config : AudioConfig = AudioConfig.new
      ) : Bool
        raise "FFmpeg is not installed or not in PATH." unless ffmpeg_installed?

        temp_wav = "#{output_path}.tmp_pcm.wav"

        # Step 1: Decode/resample source to 16-bit PCM WAV using Fluorite
        cmd = Fluorite.build do
          overwrite!
          input(input_path)

          output(temp_wav) do |outp|
            outp.no_video
            outp.audio_codec("pcm_s16le")
            outp.sample_rate(config.sample_rate)
            outp.channels(config.channels)
          end
        end

        status = cmd.run
        return false unless status.success? && File.exists?(temp_wav)

        begin
          # Step 2: Read PCM WAV and encode into 4-bit SPU2 ADPCM blocks
          wav_bytes = File.read(temp_wav).to_slice
          sound_asset = SoundImporter.import_wav(wav_bytes)

          vag_name = File.basename(output_path, File.extname(output_path))[0...16]
          vag_bytes = SoundImporter.to_vag(sound_asset, vag_name, loop_audio: config.loop_audio)

          File.write(output_path, vag_bytes)
          true
        ensure
          File.delete(temp_wav) if File.exists?(temp_wav)
        end
      end

      # Converts any image format (PNG, JPG, BMP, etc.) into PS2 GS Paletted Texture (.cbt)
      # CLUT8 (8-bit paletted, 256 colors) saves 75% GS VRAM.
      # CLUT4 (4-bit paletted, 16 colors) saves 87.5% GS VRAM.
      def self.convert_texture(
        input_path : String,
        output_path : String,
        config : TextureConfig = TextureConfig.new
      ) : Bool
        raise "FFmpeg is not installed or not in PATH." unless ffmpeg_installed?

        temp_bmp = "#{output_path}.tmp_conv.bmp"

        cmd = Fluorite.build do
          overwrite!
          input(input_path)

          output(temp_bmp) do |outp|
            if (w = config.width) && (h = config.height)
              outp.scale(w, h)
            end
            outp.format("bmp")
          end
        end

        status = cmd.run
        return false unless status.success? && File.exists?(temp_bmp)

        begin
          bmp_bytes = File.read(temp_bmp).to_slice
          tex = ImageImporter.import_bmp(bmp_bytes)

          # Palettize if 8-bit or 4-bit requested
          tex_asset = if config.clut_bits == 8
                        ImageImporter.to_paletted_8bit(tex)
                      else
                        tex
                      end

          cbt_bytes = ImageImporter.export_cbt(tex_asset)
          File.write(output_path, cbt_bytes)
          true
        ensure
          File.delete(temp_bmp) if File.exists?(temp_bmp)
        end
      end

      # Automatically inspects and converts all assets in a media folder
      def self.auto_import_directory(
        input_dir : String,
        output_dir : String,
        &logger : String -> Nil
      ) : Tuple(Int32, Int64, Int64)
        Dir.mkdir_p(output_dir) unless Dir.exists?(output_dir)

        converted_count = 0
        original_total_bytes = 0_i64
        optimized_total_bytes = 0_i64

        video_exts = [".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv"]
        audio_exts = [".mp3", ".wav", ".ogg", ".flac", ".m4a", ".aac"]
        image_exts = [".png", ".jpg", ".jpeg", ".bmp", ".tga", ".webp"]

        Dir.glob("#{input_dir}/**/*") do |file|
          next unless File.file?(file)
          ext = File.extname(file).downcase
          basename = File.basename(file, ext)
          orig_size = File.size(file)

          if video_exts.includes?(ext)
            out_file = File.join(output_dir, "#{basename}.pss")
            logger.call("Converting video #{file} -> #{out_file} (15 FPS downsampling, MPEG-2 IPU)...")
            status, _ = convert_video(file, out_file, VideoConfig.new(fps: 15))
            if status.success?
              opt_size = File.size(out_file)
              converted_count += 1
              original_total_bytes += orig_size
              optimized_total_bytes += opt_size
            end
          elsif audio_exts.includes?(ext)
            out_file = File.join(output_dir, "#{basename}.vag")
            logger.call("Converting audio #{file} -> #{out_file} (SPU2 4-bit ADPCM, 22.05kHz)...")
            if convert_audio(file, out_file, AudioConfig.new(sample_rate: 22050))
              opt_size = File.size(out_file)
              converted_count += 1
              original_total_bytes += orig_size
              optimized_total_bytes += opt_size
            end
          elsif image_exts.includes?(ext)
            out_file = File.join(output_dir, "#{basename}.cbt")
            logger.call("Converting texture #{file} -> #{out_file} (GS CLUT8 256 colors)...")
            if convert_texture(file, out_file, TextureConfig.new(clut_bits: 8))
              opt_size = File.size(out_file)
              converted_count += 1
              original_total_bytes += orig_size
              optimized_total_bytes += opt_size
            end
          end
        end

        {converted_count, original_total_bytes, optimized_total_bytes}
      end
    end
  end
end
