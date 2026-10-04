require "../cradare2/plugin"
require "../compiler/source_map"
require "../parser/dsl_parser"
require "../compiler/bytecode_compiler"
require "../iso/elf_builder"
require "../iso/iso_builder"
require "../debugger/pcsx2_bridge"
require "../debugger/crash_analyzer"

module Citrine
  module CLI
    class DebugCommand
      def self.run(args : Array(String))
        if args.includes?("--mem-check")
          MemCheckCommand.run(args.reject { |a| a == "--mem-check" })
          return
        end

        is_ci = args.includes?("--ci") || args.includes?("--batch")
        with_r2 = args.includes?("--r2")
        no_break = args.includes?("--no-break") || args.includes?("--run")
        port = 1234
        if idx = args.index("--port")
          port = args[idx + 1]?.try(&.to_i?) || 1234
        end

        timeout_sec = 10.0
        if idx = args.index("--timeout")
          timeout_sec = args[idx + 1]?.try(&.to_f?) || 10.0
        end

        skip_next = false
        target : String? = nil
        args.each do |arg|
          if skip_next
            skip_next = false
            next
          end
          if arg == "--port" || arg == "--timeout"
            skip_next = true
            next
          end
          if !arg.starts_with?("-") && target.nil?
            target = arg
          end
        end

        iso_path, source_map = prepare_target(target)

        puts "[Citrine Debugger] Target ISO: #{iso_path}"
        bridge = Debugger::Pcsx2Bridge.new

        unless bridge.pcsx2_path
          puts "\n[Citrine Debugger] Warning: PCSX2 executable not found in standard paths."
          puts "You can still run radare2 GDB client manually against port #{port}:"
          generate_r2_script(iso_path, port, source_map)
          return
        end

        puts "[Citrine Debugger] Using PCSX2 at: #{bridge.pcsx2_path}"
        bridge.ensure_logging_configured

        if with_r2
          generate_r2_script(iso_path, port, source_map)
          puts "[Citrine Debugger] radare2 script 'citrine_r2.rc' prepared."
        end

        puts "[Citrine Debugger] Launching PCSX2 in supervised debug mode..."
        if is_ci
          puts "[Citrine Debugger] Running in headless CI verification mode (timeout: #{timeout_sec}s)..."
        end

        ai_log_path = ".citrine_debug.log"
        ai_log = File.open(ai_log_path, "w")
        event_count = 0

        puts "[Citrine Debugger] AI Debug Bridge active -> #{File.expand_path(ai_log_path)}"
        puts "[Citrine Debugger] Interactive PCSX2 display running with live telemetry."
        puts "[Citrine Debugger] Press buttons on your controller in PCSX2 to inspect input."
        puts "[Citrine Debugger] (Close PCSX2 window or press Ctrl+C to exit)..."

        crash_detected = false
        timeout = is_ci ? timeout_sec.seconds : nil

        begin
          bridge.spawn_pcsx2(
            iso_path: iso_path,
            batch: is_ci,
            nogui: is_ci,
            debugger_gui: !no_break && !is_ci,
            timeout: timeout
          ) do |line|
            if line.includes?("[Citrine") || line.includes?("[CITRINE") || line.includes?("[DEBUG") || line.includes?("PANIC") || line.includes?("Watchdog") || line.includes?("Exception") || line.includes?("Button") || line.includes?("PAD") || line.includes?("Pad:") || line.includes?("padman") || line.includes?("sio2man")
              puts " [PS2 EE] #{line}"
              ai_log.puts(line)
              ai_log.flush
              event_count += 1
            end

            if report = Debugger::CrashAnalyzer.analyze(line, source_map)
              crash_detected = true
              STDERR.puts report.render
              ai_log.puts("[CRASH REPORT] #{report.render}")
              ai_log.flush
            end
          end
        ensure
          ai_log.close rescue nil
        end

        puts "\n[Citrine Debugger] Debug session ended. Captured #{event_count} events to #{ai_log_path}."

        if crash_detected
          STDERR.puts "\n[Citrine Debugger] FAILED: Hardware crash or panic detected during execution."
          exit(1) if is_ci
        elsif is_ci
          puts "\n[Citrine Debugger] PASSED: No hardware crashes or panics detected (#{timeout_sec}s test run clean)."
        end
      end

      private def self.prepare_target(target : String?) : Tuple(String, SourceMap?)
        # If target is nil, look for main.cr, game.cbc, or game.iso in current directory
        resolved = target
        unless resolved
          if File.exists?("main.cr")
            resolved = "main.cr"
          elsif File.exists?("game.iso")
            resolved = "game.iso"
          elsif File.exists?("game.cbc")
            resolved = "game.cbc"
          else
            resolved = "main.cr"
          end
        end

        source_map : SourceMap? = nil

        if resolved.ends_with?(".cr")
          puts "[Citrine Debugger] Compiling Crystal source: #{resolved}..."
          source = File.read(resolved)
          parser = DslParser.new(resolved)
          program = parser.parse(source)

          compiler = BytecodeCompiler.new(resolved)
          cbc_bytes = compiler.compile(program)
          source_map = compiler.source_map

          cbc_path = resolved.gsub(/\.cr$/, ".cbc")
          sym_path = resolved.gsub(/\.cr$/, ".cbcsym")
          File.write(cbc_path, cbc_bytes)
          source_map.save(sym_path)

          iso_path = resolved.gsub(/\.cr$/, ".iso")
          puts "[Citrine Debugger] Packaging bootable ISO: #{iso_path}..."
          IsoBuilder.build(iso_path, cbc_bytes)
          return {iso_path, source_map}

        elsif resolved.ends_with?(".cbc")
          cbc_bytes = File.read(resolved).to_slice
          sym_path = resolved.gsub(/\.cbc$/, ".cbcsym")
          if File.exists?(sym_path)
            source_map = SourceMap.from_file(sym_path)
          end

          iso_path = resolved.gsub(/\.cbc$/, ".iso")
          IsoBuilder.build(iso_path, cbc_bytes)
          return {iso_path, source_map}

        else
          # Assume ISO
          sym_path = resolved.gsub(/\.iso$/, ".cbcsym")
          if File.exists?(sym_path)
            source_map = SourceMap.from_file(sym_path)
          end
          return {resolved, source_map}
        end
      end

      private def self.generate_r2_script(target : String, port : Int32, source_map : SourceMap?)
        rc_path = "citrine_r2.rc"
        io = IO::Memory.new
        io.puts "#!/usr/bin/env r2 -i"
        io.puts "# Auto-generated Citrine PS2 Radare2 Script"
        io.puts "e asm.arch = mips"
        io.puts "e asm.cpu = r5900"
        io.puts "e asm.bits = 32"
        io.puts "e dbg.backend = gdb"

        io.puts "\n# PS2 Hardware Memory Regions"
        io.puts "f spram.start = 0x70000000"
        io.puts "f spram.end   = 0x70004000"
        io.puts "f gs.fb0      = 0x00000000"
        io.puts "f gs.fb1      = 0x00080000"
        io.puts "f gs.zbuf     = 0x00100000"

        io.puts "\n# Macros for Emotion Engine & SPRAM inspection"
        io.puts "(spram idx, px 16 @ 0x70000000 + ($0 * 16))"
        io.puts "(ee_regs, dr)"

        if source_map
          io.puts "\n# Crystal Source Map Markers"
          source_map.locations.each do |offset, loc|
            addr = offset * 4
            io.puts "CC #{File.basename(loc.file)}:#{loc.line} @ #{addr}"
          end
        end

        File.write(rc_path, io.to_s)
      end
    end
  end
end
