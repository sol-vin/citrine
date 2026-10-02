module Citrine
  module Cradare2
    class R2PluginGenerator
      # Generates a radare2 r2pipe/r2 script or configuration
      # that registers Citrine VM opcodes, types, and SPRAM memory maps.
      def self.generate_r2_script(cbc_path : String, source_map_path : String? = nil) : String
        io = IO::Memory.new
        io.puts "#!/usr/bin/env r2 -i"
        io.puts "# Radare2 Debug & Analysis Script for Citrine PS2"
        io.puts "# Load binary"
        io.puts "o #{cbc_path}"
        io.puts "e asm.bits = 32"
        io.puts "e asm.arch = mips"
        io.puts "e asm.cpu = r5900"

        io.puts "\n# Citrine PS2 Memory Map flags"
        io.puts "f spram.start = 0x70000000"
        io.puts "f spram.end   = 0x70004000"
        io.puts "f spram.size  = 0x4000 # 16KB SPRAM"

        io.puts "\n# Framebuffer & GS Memory"
        io.puts "f gs.framebuffer0 = 0x00000000"
        io.puts "f gs.framebuffer1 = 0x00080000"
        io.puts "f gs.zbuffer      = 0x00100000"

        if source_map_path && File.exists?(source_map_path)
          sm = SourceMap.from_file(source_map_path)
          io.puts "\n# Citrine Source Map Symbols"
          sm.locations.each do |offset, loc|
            # Bytecode offset to word offset
            byte_addr = offset * 4
            fn = loc.function ? "_#{loc.function}" : ""
            io.puts "f sym.citrine.line#{loc.line}#{fn} = #{byte_addr}"
            io.puts "CC #{File.basename(loc.file)}:#{loc.line} @ #{byte_addr}"
          end
        end

        io.to_s
      end
    end
  end
end
