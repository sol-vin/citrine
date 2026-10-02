require "../disassembler/disassembler"
require "../compiler/source_map"

module Citrine
  module CLI
    class DisasmCommand
      def self.run(args : Array(String))
        input_file = args.first?
        unless input_file && File.exists?(input_file)
          puts "Usage: citrine disasm <file.cbc>"
          exit(1)
        end

        sym_path = input_file.gsub(/\.cbc$/, ".cbcsym")
        source_map = File.exists?(sym_path) ? SourceMap.from_file(sym_path) : nil

        disassembler = Disassembler.new(STDOUT, source_map)
        disassembler.disassemble_file(input_file)
      end
    end
  end
end
