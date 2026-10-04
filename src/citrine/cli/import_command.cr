require "../importers/fluorite_media"

module Citrine
  module CLI
    class ImportCommand
      def self.run(args : Array(String))
        if args.empty? || args.includes?("-h") || args.includes?("--help")
          print_help
          return
        end

        sub = args[0]
        case sub
        when "video"
          run_video(args[1..])
        when "cdda", "cd-audio"
          run_cdda(args[1..])
        when "album"
          run_album(args[1..])
        when "audio", "sound"
          run_audio(args[1..])
        when "texture", "image"
          run_texture(args[1..])
        when "auto", "batch"
          run_auto(args[1..])
        when "probe", "info"
          run_probe(args[1..])
        else
          # If first arg is a file, auto-detect type
          if File.exists?(sub)
            run_single_file(sub, args[1..])
          else
            puts "Unknown import target: '#{sub}'. Run 'citrine import --help' for usage."
          end
        end
      end

      def self.print_help
        puts <<-HELP
        Citrine Media Importer (powered by Fluorite & FFmpeg)
        Transcodes and optimizes video, audio, and images for PlayStation 2 hardware.

        Usage:
          citrine import <type> <input_file> [options]
          citrine import auto <media_dir> [-o <output_dir>]
          citrine import probe <media_file>

        Subcommands:
          video <file>    Transcode video to PS2 IPU MPEG-2 Program Stream (.pss)
          cdda <file>     Transcode audio to Red Book CD-DA raw sector stream (.raw / 2352B)
          audio <file>    Transcode audio to Sony SPU2 4-bit ADPCM (.vag) or CD-DA (--cdda)
          texture <file>  Convert image to GS CLUT paletted texture (.cbt)
          auto <dir>      Batch convert an entire folder of assets
          probe <file>    Display stream and codec details of a media file

        Video Options:
          -o <path>             Output path (default: <basename>.pss)
          --fps <rate>          Downsample framerate (default: 15 fps)
          --resolution <w>x<h>  Target resolution (default: 512x448)
          --bitrate <rate>      Target bitrate (default: 2000k)
          --dvd-track           Package into DVD sector stream ("DVD Video Track Trick")

        Audio Options:
          -o <path>             Output path (default: <basename>.vag or <basename>.raw)
          --rate <hz>           Sample rate in Hz: 22050 (default) or 44100
          --loop                Set SPU2 hardware loop repeat flags
          --cdda                Transcode as Red Book CD-DA 16-bit stereo sectors (2,352 bytes)
          --duration <sec>      Optional audio duration limit in seconds

        Texture Options:
          -o <path>             Output path (default: <basename>.cbt)
          --clut <4|8>          CLUT palette depth: 8-bit (256 colors) or 4-bit (16 colors)
          --size <w>x<h>        Target dimensions (e.g. 256x256)
        HELP
      end

      private def self.run_video(args : Array(String))
        input = args.reject(&.starts_with?("-")).first?
        unless input && File.exists?(input)
          puts "Error: Input video file not found."
          return
        end

        out_path = extract_opt(args, "-o") || "#{File.basename(input, File.extname(input))}.pss"
        fps = (extract_opt(args, "--fps") || "15").to_i
        bitrate = extract_opt(args, "--bitrate") || "2000k"
        dvd_track = args.includes?("--dvd-track")

        width = 512
        height = 448
        if res_str = extract_opt(args, "--resolution")
          parts = res_str.split("x")
          if parts.size == 2
            width = parts[0].to_i
            height = parts[1].to_i
          end
        end

        puts "======================================================================"
        puts "              CITRINE VIDEO IMPORT (PS2 IPU MPEG-2)                  "
        puts "======================================================================"
        puts "  Input:       #{input}"
        puts "  Output:      #{out_path}"
        puts "  Framerate:   #{fps} FPS (downsampled for 4x DVD streaming limits)"
        puts "  Resolution:  #{width}x#{height}"
        puts "  Bitrate:     #{bitrate}"
        puts "  DVD Track:   #{dvd_track ? "YES (interleaved sector stream)" : "NO"}"
        puts "----------------------------------------------------------------------"

        config = Importers::FluoriteMedia::VideoConfig.new(
          fps: fps,
          width: width,
          height: height,
          bitrate: bitrate,
          dvd_track: dvd_track
        )

        status, metadata = Importers::FluoriteMedia.convert_video(input, out_path, config)
        if status.success?
          orig_kb = File.size(input) // 1024
          out_kb = File.size(out_path) // 1024
          puts "\n[SUCCESS] Video encoded successfully!"
          puts sprintf("  Size: %d KB -> %d KB (%.1f%% of original)", orig_kb, out_kb, (out_kb.to_f / orig_kb.to_f) * 100.0)
          if metadata
            puts "  DVD Track Sectors: #{metadata.total_sectors} sectors (2048 bytes/sec)"
            puts "  Descriptor:        #{out_path}.track_info"
          end
        else
          puts "\n[ERROR] FFmpeg video transcoding failed."
        end
      end

      private def self.run_cdda(args : Array(String))
        input = args.reject(&.starts_with?("-")).first?
        unless input && File.exists?(input)
          puts "Error: Input audio file not found."
          return
        end

        out_path = extract_opt(args, "-o") || "#{File.basename(input, File.extname(input))}.raw"
        rate = (extract_opt(args, "--rate") || "44100").to_i
        duration = extract_opt(args, "--duration").try(&.to_f64)

        puts "======================================================================"
        puts "              CITRINE RED BOOK CD-DA AUDIO IMPORT                    "
        puts "======================================================================"
        puts "  Input:       #{input}"
        puts "  Output:      #{out_path}"
        puts "  Sample Rate: #{rate} Hz"
        puts "  Channels:    2 (Stereo Linear PCM 16-bit LE)"
        puts "  Sector Size: 2,352 bytes (Red Book CD-DA)"
        if duration
          puts "  Duration:    #{duration} seconds"
        end
        puts "----------------------------------------------------------------------"

        config = Importers::FluoriteMedia::CddaConfig.new(
          sample_rate: rate,
          channels: 2,
          sector_size: 2352,
          duration_seconds: duration
        )

        if Importers::FluoriteMedia.convert_cdda(input, out_path, config)
          orig_kb = File.size(input) // 1024
          out_kb = File.size(out_path) // 1024
          sectors = File.size(out_path) // 2352
          puts "\n[SUCCESS] Audio encoded to Red Book CD-DA (.raw) successfully!"
          puts sprintf("  Size: %d KB -> %d KB (%d CD audio sectors)", orig_kb, out_kb, sectors)
        else
          puts "\n[ERROR] CD-DA audio transcoding failed."
        end
      end

      private def self.run_audio(args : Array(String))
        if args.includes?("--cdda")
          run_cdda(args)
          return
        end

        input = args.reject(&.starts_with?("-")).first?
        unless input && File.exists?(input)
          puts "Error: Input audio file not found."
          return
        end

        out_path = extract_opt(args, "-o") || "#{File.basename(input, File.extname(input))}.vag"
        rate = (extract_opt(args, "--rate") || "22050").to_i
        loop_audio = args.includes?("--loop")

        puts "======================================================================"
        puts "              CITRINE AUDIO IMPORT (SPU2 4-BIT ADPCM)                 "
        puts "======================================================================"
        puts "  Input:       #{input}"
        puts "  Output:      #{out_path}"
        puts "  Sample Rate: #{rate} Hz"
        puts "  Format:      Sony SPU2 4-bit ADPCM (4:1 hardware compression)"
        puts "  Loop Repeat: #{loop_audio}"
        puts "----------------------------------------------------------------------"

        config = Importers::FluoriteMedia::AudioConfig.new(
          sample_rate: rate,
          loop_audio: loop_audio
        )

        if Importers::FluoriteMedia.convert_audio(input, out_path, config)
          orig_kb = File.size(input) // 1024
          out_kb = File.size(out_path) // 1024
          puts "\n[SUCCESS] Audio encoded to SPU2 ADPCM (.vag) successfully!"
          puts sprintf("  Size: %d KB -> %d KB (75%% SPU2 RAM savings achieved)", orig_kb, out_kb)
        else
          puts "\n[ERROR] Audio transcoding failed."
        end
      end

      private def self.run_texture(args : Array(String))
        input = args.reject(&.starts_with?("-")).first?
        unless input && File.exists?(input)
          puts "Error: Input image file not found."
          return
        end

        out_path = extract_opt(args, "-o") || "#{File.basename(input, File.extname(input))}.cbt"
        clut = (extract_opt(args, "--clut") || "8").to_i

        width : Int32? = nil
        height : Int32? = nil
        if size_str = extract_opt(args, "--size")
          parts = size_str.split("x")
          if parts.size == 2
            width = parts[0].to_i
            height = parts[1].to_i
          end
        end

        puts "======================================================================"
        puts "              CITRINE TEXTURE IMPORT (GS CLUT PALETTED)               "
        puts "======================================================================"
        puts "  Input:       #{input}"
        puts "  Output:      #{out_path}"
        puts "  Palette:     CLUT#{clut} (#{clut == 8 ? 256 : 16} colors)"
        puts "  Target Size: #{width && height ? "#{width}x#{height}" : "original"}"
        puts "----------------------------------------------------------------------"

        config = Importers::FluoriteMedia::TextureConfig.new(
          clut_bits: clut,
          width: width,
          height: height
        )

        if Importers::FluoriteMedia.convert_texture(input, out_path, config)
          out_kb = File.size(out_path) // 1024
          puts "\n[SUCCESS] Texture exported to Citrine CBT format!"
          puts "  Output size: #{out_kb} KB"
        else
          puts "\n[ERROR] Texture conversion failed."
        end
      end

      private def self.run_auto(args : Array(String))
        input_dir = args.reject(&.starts_with?("-")).first?
        unless input_dir && Dir.exists?(input_dir)
          puts "Error: Input directory not found."
          return
        end

        out_dir = extract_opt(args, "-o") || "assets"

        puts "======================================================================"
        puts "              CITRINE AUTOMATIC BATCH MEDIA IMPORTER                  "
        puts "======================================================================"
        puts "  Scanning: #{input_dir}"
        puts "  Target:   #{out_dir}"
        puts "----------------------------------------------------------------------"

        count, orig_bytes, opt_bytes = Importers::FluoriteMedia.auto_import_directory(input_dir, out_dir) do |msg|
          puts "  * #{msg}"
        end

        puts "----------------------------------------------------------------------"
        puts sprintf("[COMPLETE] Converted %d media files.", count)
        if count > 0 && orig_bytes > 0
          orig_mb = orig_bytes.to_f / 1024.0 / 1024.0
          opt_mb = opt_bytes.to_f / 1024.0 / 1024.0
          savings = (1.0 - (opt_bytes.to_f / orig_bytes.to_f)) * 100.0
          puts sprintf("  Total storage: %.2f MB -> %.2f MB (%.1f%% memory saved!)", orig_mb, opt_mb, savings)
        end
      end

      private def self.run_album(args : Array(String))
        input_dir = args.reject(&.starts_with?("-")).first?
        unless input_dir && Dir.exists?(input_dir)
          puts "Error: Input album directory not found."
          return
        end

        out_dir = extract_opt(args, "-o") || File.dirname(input_dir)

        puts "======================================================================"
        puts "              CITRINE RED BOOK CD-DA ALBUM IMPORTER                  "
        puts "======================================================================"
        puts "  Album Source: #{input_dir}"
        puts "  Disc Target:  #{out_dir}"
        puts "  Format:       Red Book CD-DA (44.1 kHz, 16-bit Stereo, 2,352 B/sec)"
        puts "----------------------------------------------------------------------"

        tracks = Importers::FluoriteMedia.import_album(input_dir, out_dir) do |msg|
          puts "  * #{msg}"
        end

        puts "----------------------------------------------------------------------"
        puts sprintf("[COMPLETE] Ingested %d album tracks onto mixed-mode disc layout.", tracks.size)
        total_sectors = tracks.sum(&.sector_count)
        total_min = (total_sectors.to_f / 75.0 / 60.0)
        puts sprintf("  Total Audio Duration: %.2f minutes (%d optical sectors)", total_min, total_sectors)
      end

      private def self.run_probe(args : Array(String))
        input = args.reject(&.starts_with?("-")).first?
        unless input && File.exists?(input)
          puts "Error: File not found."
          return
        end

        res = Importers::FluoriteMedia.probe(input)
        puts "======================================================================"
        puts "                      CITRINE MEDIA PROBE                             "
        puts "======================================================================"
        puts "  File:     #{input}"
        puts "  Format:   #{res.format_name} (#{res.format.format_long_name || "unknown"})"
        puts "  Duration: #{res.duration_formatted}"
        puts "  Size:     #{res.human_size}"
        puts sprintf("  Streams:  %d total", res.streams.size)
        res.streams.each_with_index do |s, idx|
          puts sprintf("    Stream #%d: %s (%s)", idx, s.codec_type, s.codec_name)
          if s.codec_type == "video"
            puts sprintf("      Resolution: %dx%d, FPS: %.2f", s.width || 0, s.height || 0, s.fps)
          elsif s.codec_type == "audio"
            puts sprintf("      Sample rate: %d Hz, Channels: %d", s.sample_rate || 0, s.channels || 0)
          end
        end
        puts "======================================================================"
      end

      private def self.run_single_file(path : String, args : Array(String))
        ext = File.extname(path).downcase
        case ext
        when ".mp4", ".mkv", ".avi", ".mov", ".webm"
          run_video([path] + args)
        when ".mp3", ".wav", ".ogg", ".flac", ".m4a", ".aac"
          run_audio([path] + args)
        when ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".webp"
          run_texture([path] + args)
        else
          puts "Unsupported media format: #{ext}"
        end
      end

      private def self.extract_opt(args : Array(String), flag : String) : String?
        if idx = args.index(flag)
          args[idx + 1]?
        else
          nil
        end
      end
    end
  end
end
