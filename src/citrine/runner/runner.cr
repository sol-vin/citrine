require "file_utils"
require "../compiler/bytecode_compiler"
require "../parser/dsl_parser"

module Citrine
  class Runner
    property pcsx2_path : String?
    property runner_elf_path : String

    def initialize(@pcsx2_path : String? = nil, @runner_elf_path : String = "runtime/bin/citrine_runner.elf")
      @pcsx2_path ||= find_pcsx2
    end

    def find_pcsx2 : String?
      if env_path = ENV["PCSX2_PATH"]?
        return env_path if File.exists?(env_path)
      end

      # Common search paths on Windows & Linux
      candidates = [
        "pcsx2",
        "pcsx2-qt",
        "C:\\Program Files\\PCSX2\\pcsx2-qt.exe",
        "C:\\Program Files (x86)\\PCSX2\\pcsx2.exe",
        "#{ENV["LOCALAPPDATA"]? || ""}\\Programs\\PCSX2\\pcsx2-qt.exe"
      ]

      candidates.each do |c|
        return c if File.exists?(c)
      end

      nil
    end

    def compile_game(source_path : String, output_cbc_path : String) : BytecodeCompiler
      source = File.read(source_path)
      parser = DslParser.new(filename: source_path)
      program = parser.parse(source)

      compiler = BytecodeCompiler.new(filename: source_path)
      bytes = compiler.compile(program)

      File.write(output_cbc_path, bytes)

      # Write source map alongside .cbc
      sym_path = output_cbc_path.gsub(/\.cbc$/, ".cbcsym")
      compiler.source_map.to_file(sym_path)

      compiler
    end

    def run(source_path : String, host_dir : String = ".")
      output_cbc = File.join(host_dir, "game.cbc")
      puts "[Citrine] Compiling #{source_path} -> #{output_cbc}..."
      t0 = Time.monotonic
      compiler = compile_game(source_path, output_cbc)
      dt = (Time.monotonic - t0).total_milliseconds
      puts "[Citrine] Compiled successfully in #{dt.round(1)} ms."

      # Run safety budget check
      fn_regs = {} of String => UInt8
      compiler.functions.each { |f| fn_regs[f.name] = f.num_registers }
      report = BudgetChecker.check(fn_regs, File.size(output_cbc).to_i32)

      if report.warnings.size > 0
        puts "[Citrine] Budget Warnings:"
        report.warnings.each { |w| puts "  - #{w}" }
      end

      pcsx2 = @pcsx2_path
      if pcsx2
        puts "[Citrine] Launching PCSX2 with #{runner_elf_path}..."
        args = ["-elf", runner_elf_path, "-hostpath", host_dir]
        Process.run(pcsx2, args)
      else
        puts "[Citrine] PCSX2 not found in standard paths. Bytecode generated at #{output_cbc}."
        puts "[Citrine] Set PCSX2_PATH or run directly in your PS2 emulator/hardware."
      end
    end

    def watch_and_reload(source_path : String, host_dir : String = ".")
      output_cbc = File.join(host_dir, "game.cbc")
      compile_game(source_path, output_cbc)
      puts "[Citrine] Watching #{source_path} for live hot-reloading (Ctrl+C to stop)..."

      last_mtime = File.info(source_path).modification_time

      loop do
        sleep 0.2.seconds
        begin
          current_mtime = File.info(source_path).modification_time
          if current_mtime > last_mtime
            last_mtime = current_mtime
            puts "\n[Citrine] Change detected! Recompiling..."
            t0 = Time.monotonic
            compile_game(source_path, output_cbc)
            dt = (Time.monotonic - t0).total_milliseconds
            puts "[Citrine] Hot-reloaded #{output_cbc} in #{dt.round(1)} ms! Screen updated."
          end
        rescue ex
          # File might be temporarily locked while saving
        end
      end
    end
  end
end
