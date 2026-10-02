require "../runner/runner"

module Citrine
  module CLI
    class RunCommand
      def self.run(args : Array(String))
        watch = args.includes?("--watch")
        batch = args.includes?("--batch")
        host_sim = args.includes?("--host")

        # Extract file target if specified
        file_arg = args.reject(&.starts_with?("--")).first?

        # Discover default targets in current directory if no argument is passed
        input_file = file_arg
        if input_file.nil? || input_file.empty?
          if File.exists?("main.cr")
            input_file = "main.cr"
          elsif iso = Dir["*.iso"].first?
            input_file = iso
          elsif cbc = Dir["*.cbc"].first?
            input_file = cbc
          end
        end

        unless input_file && File.exists?(input_file)
          puts "Usage: citrine run [file.cr | file.cbc | game.iso] [options]"
          puts ""
          puts "Options:"
          puts "  --watch   Watch source file and hot-reload bytecode and ISO on save"
          puts "  --batch   Run PCSX2 in headless / batch mode"
          puts "  --host    Run in local desktop host simulator (citrine_host_runner.exe)"
          puts ""
          puts "Examples:"
          puts "  citrine run"
          puts "  citrine run examples/01_hello_pad/main.cr"
          puts "  citrine run examples/05_hello_world/main.cr --batch"
          puts "  citrine run examples/08_controller_tester/main.cr"
          exit(1)
        end

        runner = Runner.new
        if watch
          runner.watch_and_reload(input_file)
        else
          runner.run(input_file, batch_mode: batch, host_sim: host_sim)
        end
      end
    end
  end
end
