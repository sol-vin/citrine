require "../runner/runner"

module Citrine
  module CLI
    class RunCommand
      def self.run(args : Array(String))
        input_file = args.first?
        unless input_file && File.exists?(input_file)
          puts "Usage: citrine run <file.cr> [--watch]"
          exit(1)
        end

        runner = Runner.new
        if args.includes?("--watch")
          runner.watch_and_reload(input_file)
        else
          runner.run(input_file)
        end
      end
    end
  end
end
