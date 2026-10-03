require "file_utils"
require "../compiler/bytecode_compiler"
require "../parser/dsl_parser"
require "../iso/iso_builder"
require "../iso/elf_builder"
require "../debugger/pcsx2_bridge"
require "../debugger/virtual_pad_bridge"

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

    def build_iso(cbc_path : String, output_iso_path : String, extra_files : Hash(String, Bytes) = {} of String => Bytes) : String
      cbc_data = File.read(cbc_path).to_slice
      elf_data = if @runner_elf_path != "runtime/bin/citrine_runner.elf" && File.exists?(@runner_elf_path)
                   File.read(@runner_elf_path).to_slice
                 else
                   ElfBuilder.build_default_runner_elf(cbc_data)
                 end
      IsoBuilder.build(output_iso_path, cbc_data, elf_data, extra_files)
      output_iso_path
    end

    def run(source_path : String, host_dir : String = ".", batch_mode : Bool = false, host_sim : Bool = false)
      if host_sim
        run_host_simulator(source_path, host_dir)
        return
      end

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
        puts "[Citrine] Launching PCSX2 with #{abs_iso}..."
        args = [] of String
        args << "-fastboot"
        args << "-earlyconsolelog"
        args << "-batch" if batch_mode
        args << abs_iso
        if batch_mode
          proc = Process.new(pcsx2, args)
          proc.wait
        else
          bridge = Debugger::VirtualPadBridge.new
          bridge.clean_previous_log
          proc = Process.new(pcsx2, args, input: Process::Redirect::Inherit)
          bridge.start(proc.pid)
          puts "[Citrine] PCSX2 process running. (Close PCSX2 or press Ctrl+C to exit)..."
          begin
            while !proc.terminated?
              sleep 0.1.seconds
            end
          ensure
            bridge.stop
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
