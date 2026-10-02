module Citrine
  module CLI
    class TestCommand
      def self.run(args : Array(String))
        if args.first? == "iso"
          iso_pattern = args[1]? || "examples/**/game.iso"
          status = Process.run("crystal", ["run", "src/citrine/spec/iso_runner.cr", "--", iso_pattern], output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          exit(status.exit_code)
        end

        target_path = args.reject(&.starts_with?("-")).first?

        puts "======================================================================"
        puts "                   CITRINE PLAYSTATION 2 TEST RUNNER                  "
        puts "======================================================================"

        spec_files = [] of String
        if target_path && File.file?(target_path)
          spec_files << target_path
        elsif target_path && Dir.exists?(target_path)
          spec_files = Dir.glob("#{target_path}/**/*_spec.cr").sort
        else
          spec_files = Dir.glob("spec/**/*_spec.cr").sort
        end

        if spec_files.empty?
          puts "No test files matching '*_spec.cr' found."
          return
        end

        puts "Found #{spec_files.size} spec files to execute.\n"

        passed_count = 0
        failed_count = 0
        start_time = Time.instant

        spec_files.each do |spec_file|
          file_rel = spec_file.gsub(/^(\.\/|spec\/)/, "")
          print "Running #{file_rel.ljust(45)} ... "
          STDOUT.flush

          # Run spec process with output capture for failure reporting
          output = IO::Memory.new
          error = IO::Memory.new
          status = Process.run("crystal", ["spec", spec_file], output: output, error: error)
          if !status.success? && (error.to_s.includes?("LNK1104") || output.to_s.includes?("LNK1104"))
            sleep 1.0.seconds
            output = IO::Memory.new
            error = IO::Memory.new
            status = Process.run("crystal", ["spec", spec_file], output: output, error: error)
          end

          if status.success?
            puts " [PASS]"
            passed_count += 1
          else
            puts " [FAIL]"
            puts "\n" + ("-" * 60)
            puts "Failure Output for #{file_rel}:"
            puts output.to_s
            puts error.to_s
            puts ("-" * 60) + "\n"
            failed_count += 1
          end
          sleep 0.25.seconds
        end

        elapsed = (Time.instant - start_time).total_seconds

        puts "\n" + ("=" * 70)
        puts sprintf("Results: %d passed, %d failed in %.2f seconds", passed_count, failed_count, elapsed)
        puts ("=" * 70)

        if failed_count > 0
          exit(1)
        end
      end
    end
  end
end
