require "fluorite"
require "json"
require "./sound_importer"
require "./image_importer"
require "./cas_encoder"

module Citrine
  module Importers
    module FluoriteMedia
      # Metadata descriptor for an optical CD-DA audio track
      record AudioTrackMetadata,
        track_number : Int32,
        title : String,
        artist : String,
        album : String,
        duration_seconds : Float64,
        sector_count : UInt32,
        source_file : String,
        output_file : String do
        include JSON::Serializable
      end
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
        loop_audio : Bool = false,
        duration_seconds : Float64? = nil

      # CD-DA presets compliant with Red Book Compact Disc Digital Audio (44.1 kHz, 16-bit signed stereo Linear PCM)
      record CddaConfig,
        sample_rate : Int32 = 44100,
        channels : Int32 = 2,
        sector_size : Int32 = 2352,
        duration_seconds : Float64? = nil

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
            if dur = config.duration_seconds
              outp.option("-t", dur.to_s)
            end
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

      # Converts any audio or video stream into PlayStation 2 Citrine Audio Stream (.cas)
      # with configurable output sizing (bitrate/quality)
      def self.convert_to_cas(
        input_path : String,
        output_path : String,
        bitrate : Int32 = 96_000,
        channels : Int32 = 1,
        loop_audio : Bool = true
      ) : Bool
        raise "FFmpeg is not installed or not in PATH." unless ffmpeg_installed?

        config = CasConfig.new(bitrate: bitrate, channels: channels, loop_audio: loop_audio)
        temp_wav = "#{output_path}.tmp_cas_pcm.wav"

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
          wav_bytes = File.read(temp_wav).to_slice
          sound_asset = SoundImporter.import_wav(wav_bytes)
          cas_bytes = CasEncoder.encode(sound_asset, config)

          File.write(output_path, cas_bytes)
          true
        ensure
          File.delete(temp_wav) if File.exists?(temp_wav)
        end
      end

      # Converts any audio or video stream into a Red Book CD-DA raw PCM sector stream (2,352 bytes/sector)
      def self.convert_cdda(
        input_path : String,
        output_path : String,
        config : CddaConfig = CddaConfig.new
      ) : Bool
        raise "FFmpeg is not installed or not in PATH." unless ffmpeg_installed?

        temp_raw = "#{output_path}.tmp_cdda.raw"

        cmd = Fluorite.build do
          overwrite!
          input(input_path)

          output(temp_raw) do |outp|
            outp.no_video
            outp.audio_codec("pcm_s16le")
            outp.sample_rate(config.sample_rate)
            outp.channels(config.channels)
            outp.format("s16le")
            if dur = config.duration_seconds
              outp.option("-t", dur.to_s)
            end
          end
        end

        status = cmd.run
        return false unless status.success? && File.exists?(temp_raw)

        begin
          raw_size = File.size(temp_raw)
          pad_bytes = (config.sector_size - (raw_size % config.sector_size)) % config.sector_size
          File.open(output_path, "wb") do |out_f|
            File.open(temp_raw, "rb") do |in_f|
              IO.copy(in_f, out_f)
            end
            pad_bytes.times { out_f.write_byte(0_u8) }
          end
          true
        ensure
          File.delete(temp_raw) if File.exists?(temp_raw)
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

        temp_raw = "#{output_path}.tmp_conv.raw"
        w = config.width || 128
        h = config.height || 128

        # Maintain aspect ratio and pad to exact target dimensions with transparent pixels
        vf_filter = "scale=#{w}:#{h}:force_original_aspect_ratio=decrease,pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2:color=0x00000000"
        args = ["-y", "-i", input_path, "-vf", vf_filter, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", temp_raw]
        status = Process.run("ffmpeg", args)
        return false unless status.success? && File.exists?(temp_raw)

        begin
          raw_bytes = File.read(temp_raw).to_slice
          tex = TextureAsset.new(w, h, GSColorFormat::PSMCT32, raw_bytes)

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
          File.delete(temp_raw) if File.exists?(temp_raw)
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

      # Checks if ffprobe executable is installed and available in PATH
      def self.ffprobe_installed? : Bool
        Process.find_executable("ffprobe") != nil
      end

      # Extracts audio track metadata (track number, title, artist, album, duration) using ffprobe
      def self.extract_audio_metadata(input_path : String) : AudioTrackMetadata
        filename = File.basename(input_path)
        default_title = File.basename(input_path, File.extname(input_path))
        default_track = 1
        default_artist = "Unknown Artist"
        default_album = "Unknown Album"
        default_duration = 0.0_f64

        # Clean title heuristic if filename has track prefix like "01 Overture" or "Artist - Album - 01 Title"
        if md = filename.match(/(?:^|\b|[-_])0*(\d{1,2})\s*[-_.]?\s*(.*?)\.[^.]+$/i)
          default_track = md[1].to_i
          clean_title = md[2].strip
          default_title = clean_title unless clean_title.empty?
        end

        if ffprobe_installed?
          io = IO::Memory.new
          err_io = IO::Memory.new
          proc = Process.new(
            "ffprobe",
            ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", input_path],
            output: io,
            error: err_io
          )
          if proc.wait.success?
            begin
              parsed = JSON.parse(io.to_s)

              # Duration
              if dur_val = parsed.dig?("format", "duration")
                default_duration = dur_val.as_s.to_f64 rescue 0.0_f64
              elsif dur_val = parsed.dig?("streams", 0, "duration")
                default_duration = dur_val.as_s.to_f64 rescue 0.0_f64
              end

              # Tags (case-insensitive search across format and audio streams)
              tags_hash = Hash(String, String).new
              if fmt_tags = parsed.dig?("format", "tags").try(&.as_h?)
                fmt_tags.each { |k, v| tags_hash[k.to_s.downcase] = v.to_s }
              end
              if strm_tags = parsed.dig?("streams", 0, "tags").try(&.as_h?)
                strm_tags.each { |k, v| tags_hash[k.to_s.downcase] = v.to_s }
              end

              # Track Number
              if trk_str = tags_hash["track"]?
                if md = trk_str.match(/^(\d+)/)
                  default_track = md[1].to_i
                end
              end

              # Title
              if t = tags_hash["title"]?
                default_title = t unless t.strip.empty?
              end

              # Artist
              if a = tags_hash["artist"]? || tags_hash["album_artist"]?
                default_artist = a unless a.strip.empty?
              end

              # Album
              if alb = tags_hash["album"]?
                default_album = alb unless alb.strip.empty?
              end
            rescue
              # Ignore JSON parse errors and use filename defaults
            end
          end
        end

        sector_count = ((default_duration * 44100.0 * 4.0 + 2351.0) / 2352.0).to_u32

        AudioTrackMetadata.new(
          track_number: default_track,
          title: default_title,
          artist: default_artist,
          album: default_album,
          duration_seconds: default_duration,
          sector_count: sector_count,
          source_file: input_path,
          output_file: ""
        )
      end

      # Transcodes an entire album directory of MP3/OGG/FLAC files into Red Book CD-DA raw PCM sector tracks
      # for mixed-mode PlayStation 2 CD-ROM images.
      def self.import_album(
        album_dir : String,
        output_dir : String,
        &block : String -> Nil
      ) : Array(AudioTrackMetadata)
        audio_exts = [".ogg", ".mp3", ".wav", ".flac", ".m4a"]

        files = Dir.children(album_dir).map { |f| File.join(album_dir, f) }.select do |f|
          File.file?(f) && audio_exts.includes?(File.extname(f).downcase)
        end

        if files.empty?
          yield "Warning: No audio files found in #{album_dir}"
          return [] of AudioTrackMetadata
        end

        yield "Found #{files.size} audio tracks in #{album_dir}. Extracting metadata..."

        # Extract metadata
        tracks = files.map { |f| extract_audio_metadata(f) }

        # Sort strictly by track number
        tracks.sort_by!(&.track_number)

        Dir.mkdir_p(output_dir)
        processed_tracks = [] of AudioTrackMetadata

        # Note: CD Track 1 is always the ISO9660 Data track!
        # Audio tracks start at optical Track 2 (track02.raw .. trackNN.raw)
        tracks.each_with_index do |track, idx|
          cdda_track_num = idx + 2
          out_filename = sprintf("track%02d.raw", cdda_track_num)
          out_path = File.join(output_dir, out_filename)

          yield sprintf("  [%02d/%02d] Trk %02d: %s - %s (%.1fs) -> %s",
                        idx + 1, tracks.size, track.track_number, track.artist, track.title,
                        track.duration_seconds, out_filename)

          convert_cdda(track.source_file, out_path, CddaConfig.new)

          actual_sectors = File.exists?(out_path) ? (File.size(out_path) // 2352).to_u32 : track.sector_count
          actual_duration = actual_sectors.to_f64 / 75.0

          processed_tracks << AudioTrackMetadata.new(
            track_number: track.track_number,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration_seconds: actual_duration,
            sector_count: actual_sectors,
            source_file: track.source_file,
            output_file: out_path
          )
        end

        # Ingest cover art if present (cover.jpg, cover.png, folder.jpg)
        ["cover.jpg", "cover.png", "folder.jpg", "cover.jpeg"].each do |img_name|
          img_path = File.join(album_dir, img_name)
          if File.exists?(img_path)
            cbt_path = File.join(output_dir, "cover.cbt")
            yield "  Ingesting album cover #{img_path} -> #{cbt_path} (GS CLUT8, 128x128)..."
            begin
              convert_texture(img_path, cbt_path, TextureConfig.new(width: 128, height: 128, clut_bits: 8))
            rescue ex
              yield "  Warning: Album cover conversion failed: #{ex.message}"
            end
            break
          end
        end

        # Save album_metadata.json
        json_path = File.join(output_dir, "album_metadata.json")
        File.open(json_path, "w") do |f|
          processed_tracks.to_json(f)
        end
        yield "Saved album descriptors to #{json_path}"

        processed_tracks
      end

      def self.import_album(
        album_dir : String,
        output_dir : String
      ) : Array(AudioTrackMetadata)
        import_album(album_dir, output_dir) { |msg| puts msg }
      end

      # Transcodes an entire album directory of MP3/OGG/FLAC files into Citrine Audio Stream (.cas) files
      # for PlayStation 2 optical disc file streaming with configurable output sizing (bitrate/quality).
      def self.import_stream_album(
        album_dir : String,
        output_dir : String,
        bitrate : Int32 = 96_000,
        channels : Int32 = 1,
        &block : String -> Nil
      ) : Array(AudioTrackMetadata)
        audio_exts = [".ogg", ".mp3", ".wav", ".flac", ".m4a"]

        files = Dir.children(album_dir).map { |f| File.join(album_dir, f) }.select do |f|
          File.file?(f) && audio_exts.includes?(File.extname(f).downcase)
        end

        if files.empty?
          yield "Warning: No audio files found in #{album_dir}"
          return [] of AudioTrackMetadata
        end

        yield "Found #{files.size} audio tracks in #{album_dir}. Extracting metadata (bitrate: #{bitrate // 1000} kbps)..."

        # Extract metadata
        tracks = files.map { |f| extract_audio_metadata(f) }
        tracks.sort_by!(&.track_number)

        Dir.mkdir_p(output_dir)
        processed_tracks = [] of AudioTrackMetadata

        tracks.each_with_index do |track, idx|
          out_filename = sprintf("track%02d.cas", idx + 1)
          out_path = File.join(output_dir, out_filename)

          yield sprintf("  [%02d/%02d] Trk %02d: %s - %s (%.1fs) -> %s (%d kbps)",
                        idx + 1, tracks.size, track.track_number, track.artist, track.title,
                        track.duration_seconds, out_filename, bitrate // 1000)

          convert_to_cas(track.source_file, out_path, bitrate: bitrate, channels: channels)

          actual_size = File.exists?(out_path) ? File.size(out_path) : 0_i64
          actual_sectors = ((actual_size + 2047) // 2048).to_u32

          processed_tracks << AudioTrackMetadata.new(
            track_number: idx + 1,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration_seconds: track.duration_seconds,
            sector_count: actual_sectors,
            source_file: track.source_file,
            output_file: out_path
          )
        end

        # Ingest cover art if present
        ["cover.jpg", "cover.png", "folder.jpg", "cover.jpeg"].each do |img_name|
          img_path = File.join(album_dir, img_name)
          if File.exists?(img_path)
            cbt_path = File.join(output_dir, "cover.cbt")
            yield "  Ingesting album cover #{img_path} -> #{cbt_path} (GS CLUT8, 128x128)..."
            begin
              convert_texture(img_path, cbt_path, TextureConfig.new(width: 128, height: 128, clut_bits: 8))
            rescue ex
              yield "  Warning: Album cover conversion failed: #{ex.message}"
            end
            break
          end
        end

        # Save album_metadata.json
        json_path = File.join(output_dir, "album_metadata.json")
        File.open(json_path, "w") do |f|
          processed_tracks.to_json(f)
        end
        yield "Saved album stream descriptors to #{json_path}"

        processed_tracks
      end

      def self.import_stream_album(
        album_dir : String,
        output_dir : String,
        bitrate : Int32 = 96_000,
        channels : Int32 = 1
      ) : Array(AudioTrackMetadata)
        import_stream_album(album_dir, output_dir, bitrate, channels) { |msg| puts msg }
      end
    end
  end
end
