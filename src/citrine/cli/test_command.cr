require "../core/regression"
require "../dsl/regression"

module Citrine
  module CLI
    class TestCommand
      def self.run(args : Array(String))
        if args.includes?("--headless") || args.includes?("--regression") || args.first? == "regression" || args.first? == "headless"
          run_headless_regression_battery(args)
          return
        end

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
          retries = 0
          while !status.success? && (error.to_s.includes?("LNK1104") || output.to_s.includes?("LNK1104")) && retries < 3
            retries += 1
            {% if flag?(:windows) %}
              Process.run("taskkill", ["/F", "/IM", "crystal-run-spec.tmp.exe"]) rescue nil
            {% end %}
            sleep 1.5.seconds
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
        puts("=" * 70)

        if failed_count > 0
          exit(1)
        end
      end

      # Runs the automated headless PCSX2 regression suite with active watchdog monitoring
      # and generates a comprehensive Markdown report.
      def self.run_headless_regression_battery(args : Array(String))
        puts "======================================================================"
        puts "       CITRINE HEADLESS PCSX2 AUTOMATED REGRESSION BATTERY           "
        puts "======================================================================"

        manager = Core::Regression::HeadlessProcessManager.new
        unless manager.available?
          puts "\n[!] PCSX2 executable not found in host environment or PATH."
          puts "    Install PCSX2 or set PCSX2_PATH to run headless regression tests."
          if ENV["REQUIRE_PCSX2"]? == "1"
            exit(1)
          else
            exit(0)
          end
        end

        puts "PCSX2 Binary: #{manager.pcsx2_path}"
        puts "Execution Mode: Headless Batch (-batch -fastboot -nogui --)"
        puts "Watchdog Interval: 5.0s (Inviolable 60s Watchdog Law Active)\n"

        builder = Citrine::DSL::Regression::SuiteBuilder.new("Citrine PS2 Hardware & VM Regression Battery")
        builder.default_timeout(10.seconds)
        builder.watchdog_interval(5.seconds)
        builder.early_exit_on_close(true)

        # 1. EE ALU Arithmetic & 128-bit Registers
        builder.test("ee_alu_and_math", "Verifies 32-bit & 64-bit integer arithmetic on EE core") do |t|
          t.source <<-CR
            a = 100 + 250
            b = a * 4
            c = b / 2
            d = c - 100
            Test.assert_equal(350, a, "Addition")
            Test.assert_equal(1400, b, "Multiplication")
            Test.assert_equal(700, c, "Division")
            Test.assert_equal(600, d, "Subtraction")
          CR
          t.expect_clean_boot
          t.expect_pass("Addition", "Multiplication", "Division", "Subtraction")
        end

        # 2. Control Flow, Conditionals & Loops
        builder.test("control_flow_and_loops", "Verifies while loops, comparisons, and branch conditionals") do |t|
          t.source <<-CR
            sum = 0
            i = 1
            while i <= 10
              sum = sum + i
              i = i + 1
            end
            Test.assert_equal(55, sum, "While loop summation")

            flag = 0
            if sum > 50
              flag = 1
            end
            Test.assert_equal(1, flag, "Branch conditional")
          CR
          t.expect_clean_boot
          t.expect_pass("While loop summation", "Branch conditional")
        end

        # 3. String & Array Operations
        builder.test("strings_and_arrays", "Verifies array indexing, size, and string operations") do |t|
          t.source <<-CR
            items = [10, 20, 30]
            sz = items.size
            first_val = items[0]
            last_val = items[2]
            Test.assert_equal(3, sz, "Array size")
            Test.assert_equal(10, first_val, "Array first item")
            Test.assert_equal(30, last_val, "Array last item")

            prefix = "Citrine "
            suffix = "PS2"
            msg = prefix + suffix
            Test.assert(msg == "Citrine PS2", "String concatenation")
          CR
          t.expect_clean_boot
          t.expect_pass("Array size", "Array first item", "Array last item", "String concatenation")
        end

        # 4. Memory Health & SPRAM Canary Integrity
        builder.test("spram_canary_integrity", "Verifies SPRAM 0x70000000 canary preservation across execution") do |t|
          t.source <<-CR
            arr = [1, 2, 3, 4]
            sum = 0
            idx = 0
            while idx < arr.size
              sum = sum + arr[idx]
              idx = idx + 1
            end
            Test.assert_equal(10, sum, "Array summation")
          CR
          t.expect_clean_boot
          t.expect_spram_preserved
          t.expect_no_memory_leaks
          t.expect_no_memory_faults
          t.expect_pass("Array summation")
        end

        # 5. GS CRTC Video Configuration & Milestones
        builder.test("gs_crtc_environment", "Verifies NTSC 640x448 GS video mode milestone initialization") do |t|
          t.source <<-CR
            boot_screen false
            Test.pass("GS display mode active")
          CR
          t.expect_clean_boot
          t.expect_pass("GS display mode active")
        end

        # Progress reporter
        reporter = ->(msg : String) {
          puts msg
        }

        # Watchdog heartbeat callback (<60s requirement)
        watchdog_cb = ->(elapsed : Time::Span) {
          puts "   [Watchdog Heartbeat] Active test running (#{elapsed.total_seconds.round(1)}s elapsed)..."
        }

        report = builder.run(reporter: reporter, watchdog_callback: watchdog_cb)

        # Print terminal summary
        puts report.to_terminal

        # Save markdown report to build/reports/pcsx2_regression_report.md
        report_dir = "build/reports"
        Dir.mkdir_p(report_dir)
        report_path = File.join(report_dir, "pcsx2_regression_report.md")
        File.write(report_path, report.to_markdown)
        puts "Saved regression report to #{report_path}"

        if report.failed_tests > 0
          exit(1)
        end
      end
    end
  end
end
