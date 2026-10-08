require "option_parser"
require "file_utils"

module CitrineTest
  class Runner
    property mode : Symbol = :battery
    property specific_spec : String? = nil
    property verbose : Bool = false

    def initialize
      parse_args
    end

    private def parse_args
      OptionParser.parse do |parser|
        parser.banner = "Citrine Test Runner & Protocol Protocol Manager\nUsage: citrine_test [options]"

        parser.on("--tier1", "Run Tier 1 fast in-process compiler specs") do
          @mode = :tier1
        end

        parser.on("--tier2", "Run Tier 2 PlayStation 2 EE hardware specs") do
          @mode = :tier2
        end

        parser.on("--battery", "Run the unified PS2 EE language battery spec (default)") do
          @mode = :battery
        end

        parser.on("--apparatus", "Run testing apparatus verification specs") do
          @mode = :apparatus
        end

        parser.on("--all", "Run Tier 1 and Tier 2 specs") do
          @mode = :all
        end

        parser.on("-s PATH", "--spec PATH", "Run a specific spec file") do |path|
          @mode = :specific
          @specific_spec = path
        end

        parser.on("-v", "--verbose", "Show verbose compiler and runner output") do
          @verbose = true
        end

        parser.on("--clean", "Clean compiled spec binaries in bin/specs/") do
          clean_specs
          exit 0
        end

        parser.on("-h", "--help", "Show help") do
          puts parser
          exit 0
        end
      end
    end

    def run
      FileUtils.mkdir_p("bin/specs")
      cleanup_orphans

      specs_to_run = select_specs

      if specs_to_run.empty?
        puts "No specs selected to run."
        return
      end

      puts "================================================================="
      puts " Citrine Testing Protocol: Running #{specs_to_run.size} Spec Suite(s)"
      puts " Mode: #{@mode}"
      puts "================================================================="

      total_start = Time.instant
      passed_count = 0
      failed_count = 0

      specs_to_run.each_with_index do |spec_path, idx|
        puts "\n[#{idx + 1}/#{specs_to_run.size}] Executing: #{spec_path}"
        spec_base = File.basename(spec_path, ".cr")
        target_bin = File.join("bin", "specs", "#{spec_base}.exe")

        build_ok = compile_spec(spec_path, target_bin)
        unless build_ok
          puts "❌ [BUILD ERROR] Failed to compile #{spec_path}"
          failed_count += 1
          next
        end

        exec_start = Time.instant
        run_ok = execute_spec(target_bin)
        exec_duration = (Time.instant - exec_start).total_seconds

        if run_ok
          puts "✅ [PASS] #{spec_base} (#{exec_duration.round(2)}s)"
          passed_count += 1
        else
          puts "❌ [FAIL] #{spec_base} (#{exec_duration.round(2)}s)"
          failed_count += 1
        end

        cleanup_orphans
      end

      total_duration = (Time.instant - total_start).total_seconds
      puts "\n================================================================="
      puts " Citrine Spec Protocol Summary"
      puts " Total Suites: #{specs_to_run.size} | Passed: #{passed_count} | Failed: #{failed_count}"
      puts " Total Execution Time: #{total_duration.round(2)}s"
      puts "================================================================="

      exit(failed_count > 0 ? 1 : 0)
    end

    private def select_specs : Array(String)
      case @mode
      when :tier1
        [
          "spec/opcode_spec.cr",
          "spec/bytecode_compiler_spec.cr",
          "spec/compiler/language_matrix_compiler_spec.cr",
        ].select { |p| File.exists?(p) }
      when :tier2
        [
          "spec/ps2/testing_apparatus_ps2_spec.cr",
          "spec/ps2/optimization_regression_ps2_spec.cr",
          "spec/ps2/language_pressure_points_ps2_spec.cr",
          "spec/ps2/language_cross_features_ps2_spec.cr",
          "spec/ps2/language_advanced_features_ps2_spec.cr",
        ].select { |p| File.exists?(p) }
      when :apparatus
        [
          "spec/ps2/testing_apparatus_ps2_spec.cr",
          "spec/ps2/optimization_regression_ps2_spec.cr",
        ].select { |p| File.exists?(p) }
      when :battery
        [
          "spec/ps2/language_spec_battery_ps2_spec.cr",
        ].select { |p| File.exists?(p) }
      when :all
        tier1 = select_specs_for(:tier1)
        battery = select_specs_for(:battery)
        tier1 + battery
      when :specific
        if s = @specific_spec
          File.exists?(s) ? [s] : [] of String
        else
          [] of String
        end
      else
        [] of String
      end
    end

    private def select_specs_for(mode : Symbol) : Array(String)
      old_mode = @mode
      @mode = mode
      res = select_specs
      @mode = old_mode
      res
    end

    private def compile_spec(source : String, target : String) : Bool
      # Remove old binary to ensure fresh build
      File.delete(target) if File.exists?(target)

      cmd = "crystal"
      args = ["build", source, "-o", target]
      args << "--no-debug" unless @verbose

      status = Process.run(cmd, args, output: (@verbose ? Process::Redirect::Inherit : Process::Redirect::Close),
        error: Process::Redirect::Inherit)
      status.success?
    end

    private def execute_spec(target_bin : String) : Bool
      status = Process.run(target_bin, [] of String, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      status.success?
    rescue ex
      puts "Execution fault: #{ex.message}"
      false
    end

    private def cleanup_orphans
      {% if flag?(:windows) %}
        Process.run("taskkill", ["/F", "/IM", "pcsx2-qt.exe"], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
      {% else %}
        Process.run("pkill", ["-9", "pcsx2"], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
      {% end %}
      sleep 0.5.seconds
    end

    private def clean_specs
      if Dir.exists?("bin/specs")
        FileUtils.rm_rf("bin/specs")
        puts "Cleaned bin/specs/"
      end
    end
  end
end

CitrineTest::Runner.new.run
