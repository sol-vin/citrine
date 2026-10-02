require "../cradare2/plugin"
require "../compiler/source_map"

module Citrine
  module CLI
    class DebugCommand
      def self.run(args : Array(String))
        target_cbc = args.find { |a| a.ends_with?(".cbc") } || "game.cbc"
        port = 1234
        if idx = args.index("--port")
          port = args[idx + 1]?.try(&.to_i?) || 1234
        end

        puts "[Citrine Debugger] Preparing radare2 debugging session for #{target_cbc} (port #{port})..."

        # Generate custom radare2 script
        sym_file = target_cbc.gsub(/\.cbc$/, ".cbcsym")
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

        # Macros for Emotion Engine & SPRAM inspection
        io.puts "\n# Custom Macro: (spram <idx>) to inspect 16-byte Value in SPRAM"
        io.puts "(spram idx, px 16 @ 0x70000000 + ($0 * 16))"
        io.puts "(ee_regs, dr)"

        # Load Source Map symbols
        if File.exists?(sym_file)
          sm = SourceMap.from_file(sym_file)
          io.puts "\n# Crystal Source Map Markers"
          sm.locations.each do |offset, loc|
            addr = offset * 4
            io.puts "CC #{File.basename(loc.file)}:#{loc.line} @ #{addr}"
          end
        end

        File.write(rc_path, io.to_s)
        puts "[Citrine Debugger] Generated #{rc_path}."

        # Check if radare2 is installed
        r2_bin = Process.find_executable("r2") || Process.find_executable("radare2")
        if r2_bin
          puts "[Citrine Debugger] Launching radare2 connected to gdb://127.0.0.1:#{port}..."
          puts "Tip: In radare2, type 'V' for Visual Mode, 'dr' for registers, or '.(spram 0)' to inspect SPRAM R0."
          Process.run(r2_bin, ["-d", "gdb://127.0.0.1:#{port}", "-i", rc_path])
        else
          puts "[Citrine Debugger] 'r2' (radare2) executable not found in PATH."
          puts "You can connect manually by running:"
          puts "  r2 -d gdb://127.0.0.1:#{port} -i #{rc_path}"
        end
      end
    end
  end
end
