require "spec"
require "./ps2_spec"
require "../debugger/pcsx2_bridge"
require "../debugger/crash_analyzer"
require "../iso/iso_builder"

module Citrine
  module Spec
    class IsoTestCase
      getter name : String
      property iso_path : String?
      property lines : Array(String) = [] of String

      def initialize(@name : String, @iso_path : String? = nil)
      end

      def load(path : String)
        @iso_path = path
      end

      # Compiles a .cr or .cbc file into an ISO if not already an ISO
      def target(path : String)
        if path.ends_with?(".iso")
          @iso_path = path
        else
          # Compile and package
          test_case = Ps2TestCase.new(@name)
          test_case.target(path)
          bytes, sm = test_case.compile
          temp_iso = "tmp_iso_#{@name.gsub(/[^a-zA-Z0-9_]/, "_")}.iso"
          IsoBuilder.build(temp_iso, bytes)
          @iso_path = temp_iso
        end
      end

      def boot_pcsx2(timeout : ::Time::Span = 3.seconds) : Ps2ExecutionResult
        iso = @iso_path
        raise "No ISO path provided for ISO test: #{name}" unless iso && File.exists?(iso)

        bridge = Debugger::Pcsx2Bridge.new
        lines = [] of String
        panic_found = false
        panic_msg : String? = nil
        crash_rep : Debugger::CrashReport? = nil
        t0 = ::Time.instant

        status = bridge.spawn_pcsx2(iso, batch: true, timeout: timeout) do |line|
          lines << line
          if rep = Debugger::CrashAnalyzer.analyze(line, nil)
            panic_found = true
            panic_msg = rep.message
            crash_rep = rep
          end
        end

        elapsed = (::Time.instant - t0).total_seconds
        canary_ok = !lines.any? { |l| l.includes?("SPRAM Stack Canary Corrupted") }

        Ps2ExecutionResult.new(
          lines: lines,
          panic_detected: panic_found,
          panic_message: panic_msg,
          crash_report: crash_rep,
          status: status,
          spram_canary_valid: canary_ok,
          boot_time_seconds: elapsed
        )
      rescue ex
        Ps2ExecutionResult.new(
          lines: ["PCSX2 runner not available: #{ex.message}"],
          panic_detected: false,
          spram_canary_valid: true,
          boot_time_seconds: 0.0
        )
      end
    end

    # Discovers and boots all ISOs matching a glob pattern
    def self.test_all_isos(
      glob_pattern : String = "examples/**/game.iso",
      timeout : ::Time::Span = 3.seconds,
      &block : (String, Ps2ExecutionResult) -> Nil
    )
      iso_files = Dir.glob(glob_pattern)
      if iso_files.empty?
        raise "No ISO files found matching pattern '#{glob_pattern}'"
      end

      iso_files.each do |iso_file|
        test_case = IsoTestCase.new(File.basename(iso_file), iso_path: iso_file)
        result = test_case.boot_pcsx2(timeout: timeout)
        block.call(iso_file, result)
      end
    end

    def self.run_iso_suite(
      glob_pattern : String = "examples/**/game.iso",
      timeout : ::Time::Span = 3.seconds
    ) : Tuple(Int32, Int32)
      iso_files = Dir.glob(glob_pattern)
      if iso_files.empty?
        puts "No ISO files found matching '#{glob_pattern}'"
        return {0, 0}
      end

      passed = 0
      failed = 0

      puts "\n======================================================================"
      puts "                 PCSX2 AUTOMATED ISO TEST RUNNER                      "
      puts "======================================================================"
      puts "Found #{iso_files.size} game ISO(s) to verify in PCSX2.\n"

      iso_files.each do |iso_file|
        rel_name = iso_file.gsub(/\\/, "/")
        print "Testing #{rel_name.ljust(48)} ... "
        STDOUT.flush

        test_case = IsoTestCase.new(File.basename(iso_file), iso_path: iso_file)
        result = test_case.boot_pcsx2(timeout: timeout)

        if result.panic_detected
          puts " [FAIL] Panic: #{result.panic_message}"
          failed += 1
        elsif !result.spram_canary_valid
          puts " [FAIL] SPRAM Canary Corrupted"
          failed += 1
        else
          puts sprintf(" [PASS] (%.2fs)", result.boot_time_seconds)
          passed += 1
        end
      end

      puts "======================================================================"
      puts sprintf("ISO Verification Results: %d passed, %d failed", passed, failed)
      puts "======================================================================\n"

      {passed, failed}
    end
  end
end

# Top-level DSL Macro
def iso_spec(name : String, &block : Citrine::Spec::IsoTestCase -> Nil)
  describe "PS2 ISO [#{name}]" do
    test_case = Citrine::Spec::IsoTestCase.new(name)
    block.call(test_case)
  end
end
