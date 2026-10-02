require "../runner/runner"
require "../iso/iso_builder"

module Citrine
  module CLI
    class IsoCommand
      def self.run(args : Array(String))
        input_file = args.reject(&.starts_with?("-")).first?

        if input_file.nil? || input_file.empty?
          if File.exists?("main.cr")
            input_file = "main.cr"
          elsif cbc = Dir["*.cbc"].first?
            input_file = cbc
          end
        end

        out_idx = args.index("-o") || args.index("--out")
        out_iso = out_idx ? args[out_idx + 1]? : nil

        unless input_file && File.exists?(input_file)
          puts "Usage: citrine iso <file.cr | file.cbc> [-o output.iso]"
          puts "Packages Citrine Bytecode into a bootable PlayStation 2 ISO9660 image."
          exit(1)
        end

        runner = Runner.new
        release_mode = args.includes?("--release")
        cbc_path = if input_file.ends_with?(".cbc")
                     input_file
                   else
                     temp_cbc = input_file.gsub(/\.cr$/, ".cbc")
                     runner.compile_game(input_file, temp_cbc, release: release_mode)
                     temp_cbc
                   end

        target_iso = out_iso || cbc_path.gsub(/\.cbc$/, ".iso")
        puts "[Citrine] Building PS2 ISO9660 image: #{target_iso}..."
        runner.build_iso(cbc_path, target_iso)
        sectors = File.size(target_iso) // 2048
        puts "[Citrine] Success: #{target_iso} created (#{File.size(target_iso)} bytes, #{sectors} sectors)."
      end
    end
  end
end
