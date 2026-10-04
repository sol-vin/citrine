require "file_utils"
require "../compiler/bytecode_compiler"
require "../parser/dsl_parser"
require "../iso/iso_builder"
require "../iso/elf_builder"
require "../iso/disc_manifest"
require "../importers/fluorite_media"
require "../debugger/pcsx2_bridge"

module Citrine
  class Runner
    property pcsx2_path : String?
    property runner_elf_path : String
    property host_runner_path : String

    def initialize(
      @pcsx2_path : String? = nil,
      @runner_elf_path : String = "runtime/bin/citrine_runner.elf",
      @host_runner_path : String = "runtime/bin/citrine_host_runner.exe"
    )
      @pcsx2_path ||= find_pcsx2
      ensure_runner_elf
    end

    def kill_running_pcsx2
      {% if flag?(:windows) %}
        Process.run("taskkill", ["/F", "/IM", "pcsx2-qt.exe", "/T"], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
        Process.run("taskkill", ["/F", "/IM", "pcsx2.exe", "/T"], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
      {% else %}
        Process.run("pkill", ["-f", "pcsx2"], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
      {% end %}
    end

    def ensure_runner_elf
      unless File.exists?(@runner_elf_path)
        Dir.mkdir_p(File.dirname(@runner_elf_path))
        File.write(@runner_elf_path, ElfBuilder.build_default_runner_elf)
      end
    end

    def find_pcsx2 : String?
      if env_path = ENV["PCSX2_PATH"]?
        return env_path if File.exists?(env_path)
      end

      # Common search paths on Windows & Linux & macOS
      candidates = [
        "pcsx2",
        "pcsx2-qt",
        "C:\\Program Files\\PCSX2\\pcsx2-qt.exe",
        "C:\\Program Files (x86)\\PCSX2\\pcsx2.exe",
        "#{ENV["LOCALAPPDATA"]? || ""}\\Programs\\PCSX2\\pcsx2-qt.exe",
        "/usr/bin/pcsx2",
        "/usr/bin/pcsx2-qt",
        "/Applications/PCSX2.app/Contents/MacOS/PCSX2"
      ]

      candidates.each do |c|
        return c if File.exists?(c)
      end

      nil
    end

    def compile_game(source_path : String, output_cbc_path : String, release : Bool = false) : BytecodeCompiler
      # Reset disc manifest for clean build session
      Citrine::ISO::DiscManifest.reset!

      src_dir = File.dirname(source_path)
      auto_prepare_assets(src_dir)

      source = File.read(source_path)
      parser = DslParser.new(filename: source_path)
      program = parser.parse(source)

      compiler = BytecodeCompiler.new(filename: source_path)
      compiler.release_mode = release
      bytes = compiler.compile(program)

      File.write(output_cbc_path, bytes)

      # Write source map alongside .cbc (omitted in release mode)
      unless release
        sym_path = output_cbc_path.gsub(/\.cbc$/, ".cbcsym")
        compiler.source_map.to_file(sym_path)
      end

      compiler
    end

    def auto_prepare_assets(src_dir : String)
      album_dir = File.join(src_dir, "album")
      return unless Dir.exists?(album_dir)

      metadata_file = File.join(src_dir, "album_metadata.json")
      track02_file = File.join(src_dir, "track02.raw")
      audio_exts = [".ogg", ".mp3", ".wav", ".flac", ".m4a"]

      album_audio_files = Dir.children(album_dir).select do |f|
        audio_exts.includes?(File.extname(f).downcase)
      end

      # 1. Check if cover needs conversion (cover.jpg/png -> cover.cbt)
      ["cover.jpg", "cover.png", "folder.jpg", "cover.jpeg"].each do |cname|
        cpath = File.join(album_dir, cname)
        out_cbt = File.join(src_dir, "cover.cbt")
        if File.exists?(cpath)
          cbt_stale = !File.exists?(out_cbt) || (File.info(cpath).modification_time > File.info(out_cbt).modification_time)
          if cbt_stale
            puts "[Citrine Media] Auto-converting album cover #{cpath} -> #{out_cbt} (GS CLUT8)..."
            Importers::FluoriteMedia.convert_texture(cpath, out_cbt, Importers::FluoriteMedia::TextureConfig.new(width: 128, height: 128, clut_bits: 8))
          end
          break
        end
      end

      # 2. Check if CD-DA album tracks need transcoding
      needs_import = false
      if !File.exists?(metadata_file) || !File.exists?(track02_file)
        needs_import = true
      else
        meta_mtime = File.info(metadata_file).modification_time
        if album_audio_files.any? { |f| File.info(File.join(album_dir, f)).modification_time > meta_mtime }
          needs_import = true
        else
          begin
            meta_json = JSON.parse(File.read(metadata_file)).as_a
            needs_import = (meta_json.size != album_audio_files.size)
          rescue
            needs_import = true
          end
        end
      end

      if needs_import
        puts "[Citrine Media] Auto-importing CD-DA album tracks from #{album_dir}..."
        # Clean up old raw track files
        Dir.children(src_dir).select { |f| f =~ /^track\d+\.raw$/i }.each do |f|
          File.delete(File.join(src_dir, f)) rescue nil
        end
        # Delete old track01.vag so SPU2 track gets regenerated
        File.delete(File.join(src_dir, "track01.vag")) rescue nil

        Importers::FluoriteMedia.import_album(album_dir, src_dir) { |msg| puts "[Citrine Media] #{msg}" }
      end

      # 3. Check if primary track VAG needs conversion (for SPU2 playback)
      track01_vag = File.join(src_dir, "track01.vag")
      first_audio = album_audio_files.sort.first?
      if first_audio
        first_path = File.join(album_dir, first_audio)
        vag_stale = !File.exists?(track01_vag) || (File.info(first_path).modification_time > File.info(track01_vag).modification_time)
        if vag_stale
          puts "[Citrine Media] Auto-converting primary album track #{first_path} -> #{track01_vag} (SPU2 4-bit ADPCM)..."
          Importers::FluoriteMedia.convert_audio(first_path, track01_vag, Importers::FluoriteMedia::AudioConfig.new(sample_rate: 22050, loop_audio: true))
        end
      end
    end

    def build_iso(cbc_path : String, output_iso_path : String, extra_files : Hash(String, Bytes) = {} of String => Bytes, audio_tracks : Array(String) = [] of String) : String
      cbc_data = File.read(cbc_path).to_slice
      src_dir = File.dirname(cbc_path)
      auto_prepare_assets(src_dir)

      # 1. Ingest all data assets registered via Citrine DiscManifest
      Citrine::ISO::DiscManifest.current.data_files.each do |asset|
        tname = asset.target_name
        spath = asset.source_path
        if File.exists?(spath)
          extra_files[tname] ||= File.read(spath).to_slice
        end
      end

      # 2. Auto-discover project assets in src_dir (cbt, vag, json, fnt, mesh)
      if Dir.exists?(src_dir)
        Dir.children(src_dir).each do |child|
          next if child == "SYSTEM.CNF" || child.ends_with?(".elf") || child.ends_with?(".cbc") || child.ends_with?(".iso") || child.ends_with?(".cue") || child.ends_with?(".cr")
          ext = File.extname(child).downcase
          if [".vag", ".cbt", ".json", ".fnt", ".mesh"].includes?(ext)
            cpath = File.join(src_dir, child)
            if File.file?(cpath)
              extra_files[child] ||= File.read(cpath).to_slice
            end
          end
        end
      end

      vag_files = Dir.glob(File.join(src_dir, "*.vag").gsub('\\', '/'))
      first_vag_data = vag_files.first? ? File.read(vag_files.first).to_slice : nil

      elf_data = if @runner_elf_path != "runtime/bin/citrine_runner.elf" && File.exists?(@runner_elf_path)
                   File.read(@runner_elf_path).to_slice
                 else
                   ElfBuilder.build_default_runner_elf(cbc_data, vag_bytes: first_vag_data)
                 end

      tracks = audio_tracks.dup

      # 3. Ingest CD-DA audio tracks from DiscManifest
      Citrine::ISO::DiscManifest.current.cd_audio_tracks.each do |asset|
        if File.exists?(asset.source_path) && !tracks.includes?(asset.source_path)
          tracks << asset.source_path
        end
      end

      # 4. Fallback discovery for track*.raw / track*.bin if not in DiscManifest
      if tracks.empty? && Dir.exists?(src_dir)
        discovered = Dir.children(src_dir).select do |f|
          ext = File.extname(f).downcase
          (ext == ".raw" || ext == ".bin") && f.downcase.starts_with?("track")
        end.map { |f| File.join(src_dir, f) }.sort_by do |p|
          base = File.basename(p)
          if md = base.match(/track(\d+)/i)
            md[1].to_i
          else
            999
          end
        end

        if discovered.empty?
          ["track02.raw", "track02.bin", "cdda.raw", "audio.raw"].each do |f|
            candidate = File.join(src_dir, f)
            tracks << candidate if File.exists?(candidate)
          end
        else
          discovered.each { |d| tracks << d }
        end
      end

      vag_files.each do |vag_file|
        base = File.basename(vag_file)
        extra_files[base] ||= File.read(vag_file).to_slice
      end

      IsoBuilder.build(output_iso_path, cbc_data, elf_data, extra_files, audio_tracks: tracks, vag_bytes: first_vag_data)
      output_iso_path
    end

    def run(source_path : String, host_dir : String = ".", batch_mode : Bool = false, host_sim : Bool = false)
      if host_sim
        run_host_simulator(source_path, host_dir)
        return
      end

      # Terminate any running PCSX2 instance to release file locks on target disc files
      kill_running_pcsx2

      output_iso = ""
      output_cbc = ""

      if source_path.ends_with?(".iso")
        output_iso = source_path
      elsif source_path.ends_with?(".cbc")
        output_cbc = source_path
        output_iso = source_path.gsub(/\.cbc$/, ".iso")
        puts "[Citrine] Packaging #{output_cbc} into PS2 ISO9660 image: #{output_iso}..."
        build_iso(output_cbc, output_iso)
      else
        dir = File.dirname(source_path)
        base = File.basename(source_path, ".cr")
        output_cbc = File.join(dir, "#{base}.cbc")
        output_iso = File.join(dir, "game.iso")

        puts "[Citrine] Compiling #{source_path} -> #{output_cbc}..."
        t0 = Time.instant
        compiler = compile_game(source_path, output_cbc)
        dt = (Time.instant - t0).total_milliseconds
        puts "[Citrine] Compiled successfully in #{dt.round(1)} ms."

        # Run safety budget check
        fn_regs = {} of String => UInt8
        compiler.functions.each { |f| fn_regs[f.name] = f.num_registers }
        report = BudgetChecker.check(fn_regs, File.size(output_cbc).to_i32)

        if report.warnings.size > 0
          puts "[Citrine] Budget Warnings:"
          report.warnings.each { |w| puts "  - #{w}" }
        end

        puts "[Citrine] Packaging #{output_cbc} into PS2 ISO9660 image: #{output_iso}..."
        build_iso(output_cbc, output_iso)
        puts "[Citrine] Success: #{output_iso} generated (#{File.size(output_iso)} bytes)."
      end

      pcsx2 = @pcsx2_path
      if pcsx2
        Debugger::Pcsx2Bridge.new.ensure_logging_configured rescue nil
        abs_iso = File.expand_path(output_iso).gsub('/', '\\')
        launch_target = abs_iso

        puts "[Citrine] Launching PCSX2 with #{launch_target}..."
        args = [] of String
        args << "-fastboot"
        args << "-earlyconsolelog"
        args << "-batch" if batch_mode
        args << launch_target
        if batch_mode
          proc = Process.new(pcsx2, args)
          proc.wait
        else
          proc = Process.new(pcsx2, args, input: Process::Redirect::Inherit)
          puts "[Citrine] PCSX2 process running. (Close PCSX2 or press Ctrl+C to exit)..."
          while !proc.terminated?
            sleep 0.1.seconds
          end
        end
      else
        puts "[Citrine] PCSX2 not found in standard paths. Disc image ready at #{output_iso}."
        puts "[Citrine] Set PCSX2_PATH or open #{output_iso} manually in PCSX2."
      end
    end

    def run_host_simulator(source_path : String, host_dir : String = ".")
      output_cbc = source_path.ends_with?(".cbc") ? source_path : File.join(host_dir, "game.cbc")
      if source_path.ends_with?(".cr")
        compile_game(source_path, output_cbc)
      end

      if File.exists?(@host_runner_path)
        puts "[Citrine] Starting Citrine Host Simulator (#{@host_runner_path})..."
        Process.run(@host_runner_path, [output_cbc])
      else
        puts "[Citrine] Host runner binary not found at #{@host_runner_path}."
      end
    end

    def watch_and_reload(source_path : String, host_dir : String = ".")
      output_cbc = File.join(host_dir, "game.cbc")
      output_iso = File.join(host_dir, "game.iso")
      compile_game(source_path, output_cbc)
      build_iso(output_cbc, output_iso)
      puts "[Citrine] Watching #{source_path} for live hot-reloading (Ctrl+C to stop)..."

      last_mtime = File.info(source_path).modification_time

      loop do
        sleep 0.2.seconds
        begin
          current_mtime = File.info(source_path).modification_time
          if current_mtime > last_mtime
            last_mtime = current_mtime
            puts "\n[Citrine] Change detected! Recompiling..."
            t0 = Time.instant
            compile_game(source_path, output_cbc)
            build_iso(output_cbc, output_iso)
            dt = (Time.instant - t0).total_milliseconds
            puts "[Citrine] Hot-reloaded #{output_cbc} and #{output_iso} in #{dt.round(1)} ms! Screen updated."
          end
        rescue ex
          # File might be temporarily locked while saving
        end
      end
    end
  end
end
