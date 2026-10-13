# Citrine PlayStation 2 Declarative Regression Test DSL (Tier 2)
# Ergonomic, block-scoped test builders wrapping `Citrine::Core::Regression` with
# yield-context receivers, fluent expectations, collision-free ISO packaging,
# active watchdog monitoring, and seamless Spec macro integration.

require "../core/regression"
require "../parser/dsl_parser"
require "../compiler/bytecode_compiler"
require "../iso/iso_builder"

module Citrine
  module DSL
    module Regression
      alias Milestone = Citrine::Core::Regression::Milestone
      alias ExecutionStatus = Citrine::Core::Regression::ExecutionStatus
      alias TestResult = Citrine::Core::Regression::TestResult
      alias SuiteReport = Citrine::Core::Regression::SuiteReport
      alias LogStreamParser = Citrine::Core::Regression::LogStreamParser
      alias HeadlessProcessManager = Citrine::Core::Regression::HeadlessProcessManager

      # =========================================================================
      # Test Expectation Set
      # =========================================================================

      # Configurable criteria that a test result must satisfy to be deemed passing.
      class TestExpectation
        property clean_boot : Bool = true
        property required_milestones : Array(Milestone) = [] of Milestone
        property expected_pass_assertions : Array(String) = [] of String
        property expected_fail_assertions : Array(String) = [] of String
        property expect_spram_preserved : Bool = true
        property expect_no_leaks : Bool = true
        property expect_no_faults : Bool = true
        property max_boot_time : Time::Span? = nil
        property expected_outputs : Array(String) = [] of String
        property expected_panic : String? = nil

        def initialize
        end
      end

      # =========================================================================
      # Declarative Test Definition
      # =========================================================================

      # Configures a single regression test case within a suite.
      class TestDefinition
        getter name : String
        property description : String?
        property source_code : String?
        property target_iso : String?
        property timeout : Time::Span = 10.seconds
        property expectations : TestExpectation = TestExpectation.new
        property tags : Array(String) = [] of String

        def initialize(@name : String, @description : String? = nil)
        end

        # Sets human-readable description.
        def description(desc : String) : self
          @description = desc
          self
        end

        # Sets raw Crystal source code for the test case.
        def source(code : String) : self
          @source_code = code
          self
        end

        # Sets a pre-existing ISO disc image path.
        def iso(path : String) : self
          @target_iso = path
          self
        end

        # Sets a source or bytecode file path to compile into an ISO.
        def target(path : String) : self
          if path.ends_with?(".iso")
            @target_iso = path
          else
            @source_code = File.read(path)
          end
          self
        end

        # Sets supervisor execution timeout.
        def timeout(span : Time::Span) : self
          @timeout = span
          self
        end

        # Adds a classification tag.
        def tag(t : String) : self
          @tags << t unless @tags.includes?(t)
          self
        end

        # Fluent expectation: expects game to boot cleanly without panics.
        def expect_clean_boot : self
          @expectations.clean_boot = true
          self
        end

        # Fluent expectation: expects one or more Test.pass assertion messages.
        def expect_pass(*messages : String) : self
          messages.each { |m| @expectations.expected_pass_assertions << m }
          self
        end

        # Fluent expectation: expects one or more Test.fail assertion messages.
        def expect_fail(*messages : String) : self
          messages.each { |m| @expectations.expected_fail_assertions << m }
          self
        end

        # Fluent expectation: expects a specific hardware/runtime milestone.
        def expect_milestone(m : Milestone) : self
          @expectations.required_milestones << m unless @expectations.required_milestones.includes?(m)
          self
        end

        # Fluent expectation: expects SPRAM canary 0x70000000 to remain valid.
        def expect_spram_preserved : self
          @expectations.expect_spram_preserved = true
          self
        end

        # Fluent expectation: expects zero memory leaks.
        def expect_no_memory_leaks : self
          @expectations.expect_no_leaks = true
          self
        end

        # Fluent expectation: expects zero memory safety faults (UAF, double free).
        def expect_no_memory_faults : self
          @expectations.expect_no_faults = true
          self
        end

        # Fluent expectation: expects boot and test duration under specified span.
        def expect_boot_time_under(span : Time::Span) : self
          @expectations.max_boot_time = span
          self
        end

        # Fluent expectation: expects arbitrary substring in log output.
        def expect_output(text : String) : self
          @expectations.expected_outputs << text
          self
        end

        # Fluent expectation: expects a panic containing the given message.
        def expect_panic(text : String) : self
          @expectations.expected_panic = text
          @expectations.clean_boot = false
          self
        end

        # Wraps raw test source code in the canonical Citrine PS2 test harness if needed.
        def build_harnessed_source : String
          src = @source_code || ""
          return src if src.includes?("module Test")

          <<-CR
          boot_screen false

          module Test
            @@pass_count : Int32 = 0
            @@fail_count : Int32 = 0

            def self.init(name : String = "")
              @@pass_count = 0
              @@fail_count = 0
              if name != ""
                debug_puts "[CITRINE TEST] INIT: " + name
              else
                debug_puts "[CITRINE TEST] INIT"
              end
            end

            def self.pass(msg : String = "")
              @@pass_count += 1
              if msg != ""
                debug_puts "[CITRINE TEST] " + msg + ": PASS"
              else
                debug_puts "[CITRINE TEST] PASS"
              end
            end

            def self.fail(msg : String = "")
              @@fail_count += 1
              if msg != ""
                debug_puts "[CITRINE TEST] " + msg + ": FAIL"
              else
                debug_puts "[CITRINE TEST] FAIL"
              end
            end

            def self.assert(cond : Bool, msg : String = "")
              if cond
                Test.pass(msg)
              else
                Test.fail(msg)
              end
            end

            def self.assert_equal(expected, actual, msg : String = "")
              if expected == actual
                Test.pass(msg)
              else
                Test.fail(msg)
              end
            end

            def self.close
              if @@fail_count > 0
                debug_puts "[CITRINE TEST] CLOSE: FAILED"
              else
                debug_puts "[CITRINE TEST] CLOSE: PASSED"
              end
            end
          end

          Test.init("#{@name}")
          #{src}
          Test.close
          CR
        end

        # Compiles the test case into an ISO image at the destination path.
        def compile_to_iso(dest_iso_path : String) : Nil
          if existing_iso = @target_iso
            FileUtils.cp(existing_iso, dest_iso_path)
            return
          end

          full_source = build_harnessed_source
          parser = DslParser.new("#{@name}.cr")
          prog = parser.parse(full_source)
          compiler = BytecodeCompiler.new("#{@name}.cr")
          bytes = compiler.compile(prog)

          Citrine::IsoBuilder.build(dest_iso_path, bytes)
        end

        # Verifies actual test execution results against declared expectations.
        # Returns {passed?, failure_messages}.
        def verify(result : TestResult) : Tuple(Bool, Array(String))
          failures = [] of String

          if result.unavailable?
            return {true, [] of String} unless ENV["REQUIRE_PCSX2"]? == "1"
            return {false, ["PCSX2 runner is required but was unavailable on host"]}
          end

          if @expectations.clean_boot && (result.panicked? || result.crashed?)
            failures << "Expected clean boot, but encountered: #{result.panic_message || result.status}"
          end

          if ep = @expectations.expected_panic
            unless result.panic_message.try(&.includes?(ep))
              failures << "Expected panic containing '#{ep}', but got: #{result.panic_message || "no panic"}"
            end
          end

          if @expectations.expect_spram_preserved && !result.spram_canary_valid
            failures << "Expected SPRAM canary 0x70000000 to be preserved, but corruption detected"
          end

          if @expectations.expect_no_leaks && !result.memory_leaks.empty?
            failures << "Expected zero memory leaks, but found #{result.memory_leaks.size} leak(s)"
          end

          if @expectations.expect_no_faults && !result.memory_faults.empty?
            failures << "Expected zero memory faults, but found: #{result.memory_faults.join(", ")}"
          end

          @expectations.required_milestones.each do |req_m|
            unless result.has_milestone?(req_m)
              failures << "Expected milestone #{req_m} was not reached"
            end
          end

          @expectations.expected_pass_assertions.each do |msg|
            matched = result.passed_assertions.any? { |pa| pa.message.includes?(msg) }
            unless matched
              failures << "Expected passed assertion '#{msg}' was not recorded"
            end
          end

          @expectations.expected_fail_assertions.each do |msg|
            matched = result.failed_assertions.any? { |fa| fa.message.includes?(msg) }
            unless matched
              failures << "Expected failed assertion '#{msg}' was not recorded"
            end
          end

          @expectations.expected_outputs.each do |out_text|
            matched = result.raw_logs.any? { |l| l.includes?(out_text) }
            unless matched
              failures << "Expected output string '#{out_text}' was not found in execution logs"
            end
          end

          if max_time = @expectations.max_boot_time
            if result.duration > max_time
              failures << "Duration #{result.duration.total_seconds}s exceeded max allowed #{max_time.total_seconds}s"
            end
          end

          {failures.empty?, failures}
        end
      end

      # =========================================================================
      # Declarative Suite Builder
      # =========================================================================

      # Aggregates and runs a suite of declarative regression tests.
      class SuiteBuilder
        getter name : String
        getter tests : Array(TestDefinition) = [] of TestDefinition
        property default_timeout : Time::Span = 10.seconds
        property watchdog_interval : Time::Span = 5.seconds
        property early_exit_on_close : Bool = true

        def initialize(@name : String)
        end

        def default_timeout(span : Time::Span) : self
          @default_timeout = span
          self
        end

        def watchdog_interval(span : Time::Span) : self
          @watchdog_interval = span
          self
        end

        def early_exit_on_close(val : Bool) : self
          @early_exit_on_close = val
          self
        end

        # Adds a declarative test case to the suite.
        def test(name : String, description : String? = nil, &block : TestDefinition -> Nil) : self
          t = TestDefinition.new(name, description)
          t.timeout(@default_timeout)
          block.call(t)
          @tests << t
          self
        end

        # Executes all registered tests headlessly in PCSX2 under active watchdog supervision.
        def run(
          reporter : Proc(String, Nil)? = nil,
          watchdog_callback : Proc(Time::Span, Nil)? = nil,
        ) : SuiteReport
          manager = HeadlessProcessManager.new
          results = [] of TestResult
          start_time = Time.instant

          @tests.each_with_index do |t, idx|
            reporter.call(" [#{idx + 1}/#{@tests.size}] Running #{t.name}...") if reporter

            temp_iso = HeadlessProcessManager.generate_temp_iso_path(t.name)
            begin
              t.compile_to_iso(temp_iso)
              res = manager.execute(
                iso_path: temp_iso,
                timeout: t.timeout,
                watchdog_interval: @watchdog_interval,
                watchdog_callback: watchdog_callback,
                early_exit: @early_exit_on_close
              )
              res.name = t.name

              # Validate expectations against outcome
              passed, failures = t.verify(res)
              unless passed
                res.status = ExecutionStatus::Failed
                failures.each do |f|
                  res.failed_assertions << Core::Regression::AssertionRecord.new(:fail, f, res.duration, f)
                end
              end

              results << res
              reporter.call("   ↳ #{res.summary}") if reporter
            ensure
              File.delete(temp_iso) if File.exists?(temp_iso)
              cue = temp_iso.sub(/\.iso$/i, ".cue")
              File.delete(cue) if File.exists?(cue)
            end
          end

          total_time = Time.instant - start_time
          SuiteReport.new(@name, results, total_time)
        end
      end
    end
  end

  # =========================================================================
  # Top-Level Namespace Facade (`Citrine::Regression`)
  # =========================================================================

  module Regression
    # Builds and executes a headless PCSX2 automated regression suite.
    def self.suite(name : String, &block : Citrine::DSL::Regression::SuiteBuilder -> Nil) : Citrine::Core::Regression::SuiteReport
      builder = Citrine::DSL::Regression::SuiteBuilder.new(name)
      block.call(builder)
      builder.run
    end

    # Builds a suite definition without running immediately.
    def self.define_suite(name : String, &block : Citrine::DSL::Regression::SuiteBuilder -> Nil) : Citrine::DSL::Regression::SuiteBuilder
      builder = Citrine::DSL::Regression::SuiteBuilder.new(name)
      block.call(builder)
      builder
    end
  end
end

# Spec integration macro for declarative regression tests
macro regression_test(name, description = nil, &block)
  {% desc = description || name %}
  it {{desc}}, file: __FILE__, line: __LINE__ do
    manager = Citrine::Core::Regression::HeadlessProcessManager.new
    if !manager.available? && ENV["REQUIRE_PCSX2"]? != "1"
      next
    end

    __def = Citrine::DSL::Regression::TestDefinition.new({{name}})
    {% if block.args.size > 0 %}
      {{block.args.first}} = __def
    {% end %}
    {{block.body}}

    temp_iso = Citrine::Core::Regression::HeadlessProcessManager.generate_temp_iso_path({{name}})
    begin
      __def.compile_to_iso(temp_iso)
      res = manager.execute(temp_iso, timeout: __def.timeout, early_exit: true)
      passed, failures = __def.verify(res)
      unless passed
        fail "Regression test '#{ {{name}} }' failed:\n  #{failures.join("\n  ")}", __FILE__, __LINE__
      end
    ensure
      File.delete(temp_iso) if File.exists?(temp_iso)
      cue = temp_iso.sub(/\.iso$/i, ".cue")
      File.delete(cue) if File.exists?(cue)
    end
  end
end
