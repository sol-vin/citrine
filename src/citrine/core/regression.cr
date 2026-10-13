# Citrine PlayStation 2 Headless PCSX2 Automated Regression Engine (Tier 1)
# Pure, strongly-typed structs, log stream parsers, milestone state machines,
# and process lifecycle supervisors for headless automated PS2 testing.

require "process"
require "socket"
require "file_utils"
require "../debugger/crash_analyzer"
require "../debugger/pcsx2_bridge"
require "../iso/iso_builder"

module Citrine
  module Core
    module Regression
      # =========================================================================
      # Enumerations & Milestones
      # =========================================================================

      # Hardware and runtime milestones observable during PS2 emulation.
      enum Milestone
        IsoMounted        # ISO-9660 disc mounted and identified
        ElfLoaded         # Target ELF loaded into EE physical memory
        EntryPoint        # EE instruction pointer reached ELF entry point
        GsCrtcConfigured  # GS display mode & CRTC circuit configured (syscall 0x02)
        EngineInit        # Citrine engine runtime initialization confirmed
        TestInit          # Citrine test harness initialized ([CITRINE TEST] INIT)
        TestClose         # Citrine test harness concluded ([CITRINE TEST] CLOSE)
        Custom            # Custom user-defined marker reached
      end

      # High-level outcome of a regression test execution.
      enum ExecutionStatus
        Passed       # All assertions passed, clean boot, no panics
        Failed       # One or more assertions failed, or close status was failed
        TimedOut     # Test execution exceeded configured supervisor deadline
        Panicked     # Citrine runtime panic or unhandled exception encountered
        Crashed      # Emulator or EE CPU fault (TLB miss, bus error, bad opcode)
        Unavailable  # PCSX2 executable not found in host environment
      end

      # Recorded occurrence of a runtime milestone with timing.
      struct MilestoneRecord
        getter milestone : Milestone
        getter name : String
        getter elapsed : Time::Span
        getter raw_line : String

        def initialize(@milestone : Milestone, @name : String, @elapsed : Time::Span, @raw_line : String)
        end
      end

      # Recorded assertion event emitted by the PS2 test harness.
      struct AssertionRecord
        getter type : Symbol # :pass or :fail
        getter message : String
        getter elapsed : Time::Span
        getter raw_line : String

        def initialize(@type : Symbol, @message : String, @elapsed : Time::Span, @raw_line : String)
        end

        def passed? : Bool
          @type == :pass
        end

        def failed? : Bool
          @type == :fail
        end
      end

      # =========================================================================
      # Test Execution Result
      # =========================================================================

      # Complete diagnostic and verification results from a headless PCSX2 test run.
      class TestResult
        property name : String
        property status : ExecutionStatus
        property duration : Time::Span
        property exit_code : Int32?
        property panic_message : String?
        property crash_report : Citrine::Debugger::CrashReport?
        property spram_canary_valid : Bool
        property milestones : Array(MilestoneRecord)
        property passed_assertions : Array(AssertionRecord)
        property failed_assertions : Array(AssertionRecord)
        property memory_leaks : Array(String)
        property memory_faults : Array(String)
        property raw_logs : Array(String)
        property screenshot_path : String?
        property custom_metadata : Hash(String, String)

        def initialize(
          @name : String,
          @status : ExecutionStatus = ExecutionStatus::Passed,
          @duration : Time::Span = Time::Span.zero,
          @exit_code : Int32? = nil,
          @panic_message : String? = nil,
          @crash_report : Citrine::Debugger::CrashReport? = nil,
          @spram_canary_valid : Bool = true,
          @milestones : Array(MilestoneRecord) = [] of MilestoneRecord,
          @passed_assertions : Array(AssertionRecord) = [] of AssertionRecord,
          @failed_assertions : Array(AssertionRecord) = [] of AssertionRecord,
          @memory_leaks : Array(String) = [] of String,
          @memory_faults : Array(String) = [] of String,
          @raw_logs : Array(String) = [] of String,
          @screenshot_path : String? = nil,
          @custom_metadata : Hash(String, String) = Hash(String, String).new
        )
        end

        def passed? : Bool
          @status == ExecutionStatus::Passed
        end

        def failed? : Bool
          @status == ExecutionStatus::Failed
        end

        def timed_out? : Bool
          @status == ExecutionStatus::TimedOut
        end

        def panicked? : Bool
          @status == ExecutionStatus::Panicked
        end

        def crashed? : Bool
          @status == ExecutionStatus::Crashed
        end

        def unavailable? : Bool
          @status == ExecutionStatus::Unavailable
        end

        def passed_count : Int32
          @passed_assertions.size
        end

        def failed_count : Int32
          @failed_assertions.size
        end

        def has_milestone?(m : Milestone) : Bool
          @milestones.any? { |rec| rec.milestone == m }
        end

        def milestone_names : Array(String)
          @milestones.map(&.name)
        end

        def summary : String
          status_str = case @status
                       when ExecutionStatus::Passed      then "PASS"
                       when ExecutionStatus::Failed      then "FAIL"
                       when ExecutionStatus::TimedOut    then "TIMEOUT"
                       when ExecutionStatus::Panicked    then "PANIC"
                       when ExecutionStatus::Crashed     then "CRASH"
                       when ExecutionStatus::Unavailable then "UNAVAILABLE"
                       end
          sprintf("[%s] %-32s (%.2fs) | %d passed, %d failed", status_str, @name, @duration.total_seconds, passed_count, failed_count)
        end
      end

      # =========================================================================
      # Real-Time Streaming Log Parser
      # =========================================================================

      # High-performance, streaming diagnostic parser that analyzes PCSX2 emulog and stdout.
      # Identifies milestones, extracts assertions, detects crashes, and signals early completion.
      class LogStreamParser
        getter milestones : Array(MilestoneRecord) = [] of MilestoneRecord
        getter passed_assertions : Array(AssertionRecord) = [] of AssertionRecord
        getter failed_assertions : Array(AssertionRecord) = [] of AssertionRecord
        getter panic_message : String? = nil
        getter crash_report : Citrine::Debugger::CrashReport? = nil
        getter spram_canary_valid : Bool = true
        getter memory_leaks : Array(String) = [] of String
        getter memory_faults : Array(String) = [] of String
        getter raw_lines : Array(String) = [] of String
        getter test_closed : Bool = false
        getter close_status : Symbol? = nil
        getter start_time : Time::Instant

        def initialize(@start_time : Time::Instant = Time.instant)
        end

        # Feeds a single log line into the parser state machine.
        def feed(line : String) : Nil
          clean = line.strip
          return if clean.empty?
          @raw_lines << clean
          elapsed = Time.instant - @start_time

          # 1. Milestones
          if clean.includes?("CDVD: Opening media:") || clean.includes?("ISO-9660: Volume ID =")
            record_milestone(Milestone::IsoMounted, "ISO Mounted", elapsed, clean)
          elsif clean.includes?("ELF Loading:") && clean.includes?("EntryPoint =")
            record_milestone(Milestone::ElfLoaded, "ELF Loaded", elapsed, clean)
          elsif clean.includes?("is executing.") && clean.includes?("entry point")
            record_milestone(Milestone::EntryPoint, "Entry Point Reached", elapsed, clean)
          elsif clean.includes?("Set GS CRTC configuration")
            record_milestone(Milestone::GsCrtcConfigured, "GS CRTC Configured", elapsed, clean)
          elsif clean.includes?("PS2 EE Engine Initialized")
            record_milestone(Milestone::EngineInit, "EE Engine Initialized", elapsed, clean)
          end

          # 2. Test Harness Markers
          if clean.includes?("[CITRINE TEST] INIT")
            name = clean.split("[CITRINE TEST] INIT").last.strip.sub(/^:\s*/, "")
            record_milestone(Milestone::TestInit, name.empty? ? "Test Init" : "Test Init: #{name}", elapsed, clean)
          elsif clean.includes?("[CITRINE TEST] CLOSE")
            @test_closed = true
            if clean.includes?("FAILED")
              @close_status = :failed
              record_milestone(Milestone::TestClose, "Test Close: FAILED", elapsed, clean)
            else
              @close_status = :passed
              record_milestone(Milestone::TestClose, "Test Close: PASSED", elapsed, clean)
            end
          elsif clean.includes?("[CITRINE TEST]")
            if clean.ends_with?(": PASS") || clean.ends_with?("[CITRINE TEST] PASS")
              msg = clean.split("[CITRINE TEST]").last.strip.sub(/:\s*PASS$/, "")
              @passed_assertions << AssertionRecord.new(:pass, msg, elapsed, clean)
            elsif clean.ends_with?(": FAIL") || clean.ends_with?("[CITRINE TEST] FAIL")
              msg = clean.split("[CITRINE TEST]").last.strip.sub(/:\s*FAIL$/, "")
              @failed_assertions << AssertionRecord.new(:fail, msg, elapsed, clean)
            end
          end

          # 3. Faults & Crashes
          if clean.includes?("[CITRINE PANIC]")
            @panic_message ||= clean
          elsif clean.includes?("Instruction Watchdog Timeout")
            @panic_message ||= clean
          elsif clean.includes?("Unhandled Exception") || clean.includes?("TLB Miss") || clean.includes?("Bus Error")
            @panic_message ||= clean
          end

          # 4. Memory Health
          if clean.includes?("SPRAM Stack Canary Corrupted")
            @spram_canary_valid = false
          end
          if clean.includes?("[Citrine Leak]") || clean.includes?("Memory leak:")
            @memory_leaks << clean
          end
          if clean.includes?("[CITRINE MEMORY ERROR]") || clean.includes?("Use-after-free") || clean.includes?("Double free")
            @memory_faults << clean
          end
        end

        # Returns true when test execution has finished and the process can be safely halted early.
        def early_exit? : Bool
          @test_closed || @panic_message != nil
        end

        private def record_milestone(milestone : Milestone, name : String, elapsed : Time::Span, line : String)
          return if @milestones.any? { |m| m.milestone == milestone && m.name == name }
          @milestones << MilestoneRecord.new(milestone, name, elapsed, line)
        end
      end

      # =========================================================================
      # Headless Process Lifecycle & Watchdog Supervisor
      # =========================================================================

      # Manages launching PCSX2 in headless/batch mode, tracking execution deadlines,
      # enforcing active 60s watchdog monitoring, and ensuring clean process tree teardown.
      class HeadlessProcessManager
        getter pcsx2_path : String?

        def initialize(@pcsx2_path : String? = nil)
          @pcsx2_path ||= find_pcsx2_executable
        end

        def available? : Bool
          p = @pcsx2_path
          !p.nil? && File.exists?(p)
        end

        # Discovers the PCSX2 executable path on the current host.
        def find_pcsx2_executable : String?
          if env_path = ENV["PCSX2_PATH"]?
            return env_path if File.exists?(env_path)
          end

          home = Path.home
          candidates = [
            "C:\\Program Files\\PCSX2\\pcsx2-qt.exe",
            "C:\\Program Files\\PCSX2\\pcsx2-qtx64.exe",
            "C:\\Program Files\\PCSX2\\pcsx2-qtx64-avx2.exe",
            "C:\\Program Files\\PCSX2\\pcsx2.exe",
            "C:\\Program Files (x86)\\PCSX2\\pcsx2-qt.exe",
            "C:\\Program Files (x86)\\PCSX2\\pcsx2.exe",
            home.join("AppData", "Local", "Programs", "PCSX2", "pcsx2-qt.exe").to_s,
            home.join("AppData", "Local", "Programs", "PCSX2", "pcsx2-qtx64.exe").to_s,
            home.join("Documents", "PCSX2", "pcsx2-qt.exe").to_s,
            "/usr/bin/pcsx2",
            "/usr/bin/pcsx2-qt",
            "/Applications/PCSX2.app/Contents/MacOS/PCSX2"
          ]

          candidates.each do |c|
            return c if File.exists?(c)
          end

          Process.find_executable("pcsx2-qt") || Process.find_executable("pcsx2-qtx64") || Process.find_executable("pcsx2")
        end

        # Generates a collision-free temporary ISO filename incorporating PID and timestamp.
        def self.generate_temp_iso_path(prefix : String = "citrine_reg") : String
          sanitized = prefix.gsub(/[^a-zA-Z0-9_]/, "_")
          "tmp_#{sanitized}_#{Process.pid}_#{Time.utc.to_unix_ms}_#{Random.rand(1000..9999)}.iso"
        end

        # Builds standardized command-line arguments adhering to pcsx2-cli constraints.
        def build_args(iso_path : String, batch : Bool = true, nogui : Bool = true, fastboot : Bool = true, gdb_port : Int32? = nil) : Array(String)
          args = [] of String
          args << "-fastboot" if fastboot
          args << "-earlyconsolelog"
          args << "-batch" if batch
          args << "-nogui" if nogui
          if port = gdb_port
            args << "-gdb" << port.to_s
          end
          args << "--"
          args << File.expand_path(iso_path)
          args
        end

        # Executes an ISO image headlessly in PCSX2 under an active watchdog supervisor.
        # Terminates early as soon as the test completes or when timeout expires.
        def execute(
          iso_path : String,
          timeout : Time::Span = 10.seconds,
          watchdog_interval : Time::Span = 5.seconds,
          watchdog_callback : Proc(Time::Span, Nil)? = nil,
          early_exit : Bool = true
        ) : TestResult
          start_time = Time.instant
          parser = LogStreamParser.new(start_time)

          unless available?
            return TestResult.new(
              name: File.basename(iso_path),
              status: ExecutionStatus::Unavailable,
              duration: Time::Span.zero,
              raw_logs: ["PCSX2 executable not found in host environment"]
            )
          end

          pcsx2 = @pcsx2_path.not_nil!
          args = build_args(iso_path)

          # Ensure PCSX2 logging is configured
          Citrine::Debugger::Pcsx2Bridge.new.ensure_logging_configured rescue nil

          home = Path.home
          log_candidates = [
            home.join("Documents", "PCSX2", "logs", "emulog.txt").to_s,
            "C:\\Program Files\\PCSX2\\logs\\emulog.txt",
            home.join("AppData", "Roaming", "PCSX2", "logs", "emulog.txt").to_s,
            home.join("AppData", "Local", "PCSX2", "logs", "emulog.txt").to_s,
            File.expand_path("logs/emulog.txt")
          ].compact.uniq

          # Delete previous logs so test starts clean
          log_candidates.each do |cand|
            if File.exists?(cand)
              5.times do
                begin
                  File.delete(cand)
                  break
                rescue
                  sleep 0.05.seconds
                end
              end
            end
          end

          # Spawn PCSX2 process with pipes
          process = Process.new(
            pcsx2,
            args,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe
          )

          stop_tailing = false

          # Stdout reader fiber
          spawn do
            if out = process.output?
              out.each_line do |line|
                parser.feed(line)
              end
            end
          rescue
          end

          # Stderr reader fiber
          spawn do
            if err = process.error?
              err.each_line do |line|
                parser.feed(line)
              end
            end
          rescue
          end

          # Emulog.txt tailing fiber with partial line buffering (captures EE console output on Windows Qt build)
          current_offset = 0_i64
          partial_line = ""
          spawn do
            while !stop_tailing
              active_log = log_candidates.find { |cand| File.exists?(cand) }
              if active_log
                begin
                  fsize = File.size(active_log)
                  if fsize < current_offset
                    current_offset = 0_i64
                    partial_line = ""
                  end
                  if fsize > current_offset
                    File.open(active_log, "r") do |f|
                      f.seek(current_offset)
                      chunk = f.read_string(fsize - current_offset)
                      current_offset = fsize
                      combined = partial_line + chunk
                      lines = combined.split('\n')
                      if combined.ends_with?('\n')
                        partial_line = ""
                      else
                        partial_line = lines.pop? || ""
                      end
                      lines.each do |l|
                        parser.feed(l)
                      end
                    end
                  end
                rescue
                end
              end
              sleep 0.05.seconds
            end
            unless partial_line.empty?
              parser.feed(partial_line)
            end
          end

          # Active Watchdog Monitoring Loop (<60s heartbeat compliance)
          last_watchdog_ping = Time.instant
          timed_out = false

          while true
            sleep 0.05.seconds
            now = Time.instant
            elapsed = now - start_time

            # 1. Check early exit
            if early_exit && parser.early_exit?
              break
            end

            # 2. Check process termination
            if process.terminated?
              break
            end

            # 3. Check timeout
            if elapsed >= timeout
              timed_out = true
              break
            end

            # 4. Watchdog ping emission
            if (now - last_watchdog_ping) >= watchdog_interval
              last_watchdog_ping = now
              watchdog_callback.call(elapsed) if watchdog_callback
            end
          end

          # Teardown process tree cleanly
          stop_tailing = true
          exit_code = kill_process_tree(process)

          # Final log drain
          if active_log = log_candidates.find { |cand| File.exists?(cand) }
            begin
              fsize = File.size(active_log)
              if fsize > current_offset
                File.open(active_log, "r") do |f|
                  f.seek(current_offset)
                  chunk = f.read_string(fsize - current_offset)
                  chunk.split('\n').each do |l|
                    parser.feed(l)
                  end
                end
              end
            rescue
            end
          end

          duration = Time.instant - start_time

          # Determine outcome
          status = if timed_out
                     ExecutionStatus::TimedOut
                   elsif parser.panic_message
                     ExecutionStatus::Panicked
                   elsif !parser.spram_canary_valid
                     ExecutionStatus::Failed
                   elsif parser.close_status == :failed || parser.failed_assertions.size > 0
                     ExecutionStatus::Failed
                   elsif parser.close_status == :passed && parser.passed_assertions.size > 0
                     ExecutionStatus::Passed
                   elsif parser.milestones.any? { |m| m.milestone == Milestone::GsCrtcConfigured }
                     ExecutionStatus::Passed
                   else
                     ExecutionStatus::Failed
                   end

          TestResult.new(
            name: File.basename(iso_path),
            status: status,
            duration: duration,
            exit_code: exit_code,
            panic_message: parser.panic_message,
            crash_report: parser.crash_report,
            spram_canary_valid: parser.spram_canary_valid,
            milestones: parser.milestones,
            passed_assertions: parser.passed_assertions,
            failed_assertions: parser.failed_assertions,
            memory_leaks: parser.memory_leaks,
            memory_faults: parser.memory_faults,
            raw_logs: parser.raw_lines
          )
        end

        # Tears down the entire process tree to prevent orphaned child processes and ISO locks.
        def kill_process_tree(process : Process) : Int32?
          return process.wait.exit_code if process.terminated?

          pid = process.pid
          {% if flag?(:windows) %}
            Process.run("taskkill", ["/F", "/T", "/PID", pid.to_s], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
          {% else %}
            Process.run("pkill", ["-P", pid.to_s], output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
            process.terminate rescue nil
          {% end %}

          # Grace wait for termination
          10.times do
            break if process.terminated?
            sleep 0.05.seconds
          end

          process.wait.exit_code rescue nil
        end
      end

      # =========================================================================
      # Regression Suite Report Generator
      # =========================================================================

      # Summary report aggregating results across a headless regression test suite.
      class SuiteReport
        getter name : String
        getter results : Array(TestResult) = [] of TestResult
        getter total_duration : Time::Span = Time::Span.zero

        def initialize(@name : String, @results : Array(TestResult) = [] of TestResult, @total_duration : Time::Span = Time::Span.zero)
        end

        def total_tests : Int32
          @results.size
        end

        def passed_tests : Int32
          @results.count(&.passed?)
        end

        def failed_tests : Int32
          @results.count { |r| r.failed? || r.panicked? || r.crashed? }
        end

        def timed_out_tests : Int32
          @results.count(&.timed_out?)
        end

        def pass_rate : Float64
          return 0.0 if @results.empty?
          (passed_tests.to_f / total_tests.to_f) * 100.0
        end

        # Formats complete results into Sol-Vin QA Standard Markdown.
        def to_markdown : String
          io = IO::Memory.new
          io.puts "# Sol-Vin Headless PCSX2 Automated Regression Report"
          io.puts ""
          io.puts "- **Suite**: `#{@name}`"
          io.puts "- **Timestamp**: `#{Time.utc.to_s("%Y-%m-%d %H:%M:%S UTC")}`"
          io.puts "- **Total Duration**: `#{sprintf("%.2fs", @total_duration.total_seconds)}`"
          io.puts "- **Pass Rate**: `#{sprintf("%.1f%%", pass_rate)}` (#{passed_tests}/#{total_tests})"
          io.puts ""
          io.puts "## 1. Test Execution Summary"
          io.puts ""
          io.puts "| Test Name | Status | Duration | Milestones | Passed | Failed |"
          io.puts "| :--- | :---: | :---: | :--- | :---: | :---: |"
          @results.each do |res|
            status_badge = case res.status
                           when ExecutionStatus::Passed   then "✅ PASS"
                           when ExecutionStatus::Failed   then "❌ FAIL"
                           when ExecutionStatus::TimedOut then "⏰ TIMEOUT"
                           when ExecutionStatus::Panicked then "💥 PANIC"
                           when ExecutionStatus::Crashed  then "🔥 CRASH"
                           else "⚠️ #{res.status}"
                           end
            milestone_str = res.milestones.map(&.name).join(", ")
            milestone_str = "None" if milestone_str.empty?
            io.puts "| `#{res.name}` | #{status_badge} | #{sprintf("%.2fs", res.duration.total_seconds)} | #{milestone_str} | #{res.passed_count} | #{res.failed_count} |"
          end

          # Failure section if any
          failures = @results.reject(&.passed?)
          if failures.size > 0
            io.puts ""
            io.puts "## 2. Failure Diagnostics & Traces"
            failures.each do |f|
              io.puts ""
              io.puts "### ❌ `#{f.name}` (#{f.status})"
              if f.panic_message
                io.puts "- **Panic Message**: `#{f.panic_message}`"
              end
              if !f.spram_canary_valid
                io.puts "- **Memory Integrity**: `SPRAM Canary 0x70000000 Corrupted`"
              end
              if f.failed_assertions.size > 0
                io.puts "- **Failed Assertions**:"
                f.failed_assertions.each do |fa|
                  io.puts "  - `#{fa.message}`"
                end
              end
              if f.memory_leaks.size > 0
                io.puts "- **Memory Leaks Detected**:"
                f.memory_leaks.each { |l| io.puts "  - `#{l}`" }
              end
              io.puts "- **Recent Logs**:"
              io.puts "```text"
              f.raw_logs.last(15).each { |l| io.puts l }
              io.puts "```"
            end
          end

          io.to_s
        end

        # Formats summary for terminal output.
        def to_terminal : String
          io = IO::Memory.new
          io.puts "\n" + ("=" * 72)
          io.puts "           PCSX2 HEADLESS AUTOMATED REGRESSION SUITE RESULTS           "
          io.puts ("=" * 72)
          io.puts sprintf("Suite: %s | Total: %d | Passed: %d | Failed: %d | Time: %.2fs", @name, total_tests, passed_tests, failed_tests, @total_duration.total_seconds)
          io.puts ("-" * 72)
          @results.each do |r|
            io.puts r.summary
          end
          io.puts ("=" * 72)
          io.to_s
        end
      end
    end
  end
end
