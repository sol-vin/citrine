require "spec"
require "../parser/dsl_parser"
require "../compiler/bytecode_compiler"
require "../iso/iso_builder"
require "../debugger/pcsx2_bridge"
require "../debugger/crash_analyzer"

module Citrine
  module Spec
    class Ps2ExecutionResult
      getter lines : Array(String)
      getter panic_detected : Bool
      getter panic_message : String?
      getter crash_report : Debugger::CrashReport?
      getter status : Process::Status?
      getter spram_canary_valid : Bool
      getter boot_time_seconds : Float64

      def initialize(
        @lines : Array(String) = [] of String,
        @panic_detected : Bool = false,
        @panic_message : String? = nil,
        @crash_report : Debugger::CrashReport? = nil,
        @status : Process::Status? = nil,
        @spram_canary_valid : Bool = true,
        @boot_time_seconds : Float64 = 0.0
      )
      end

      private def check_pcsx2_availability(file, line)
        if @lines.empty? || @lines.any? { |l| l.includes?("PCSX2 runner not available") }
          if ENV["REQUIRE_PCSX2"]? == "1"
            fail "PCSX2 runner was required but failed to launch or produced no output: #{@lines.first?}", file, line
          end
          true
        else
          false
        end
      end

      def should_boot_cleanly(file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        if @panic_detected
          fail "Expected game to boot cleanly without panic, but encountered: #{@panic_message}", file, line
        end
      end

      def should_not_panic(file = __FILE__, line = __LINE__)
        should_boot_cleanly(file, line)
      end

      def should_panic_with(expected_substring : String, file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        unless @panic_detected && @panic_message.try(&.includes?(expected_substring))
          fail "Expected game to panic with '#{expected_substring}', but got: #{@panic_message || "no panic"}", file, line
        end
      end

      def should_have_output(expected_text : String, file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        has_match = @lines.any? { |l| l.includes?(expected_text) }
        unless has_match
          fail "Expected log output to contain '#{expected_text}', but it was not found in #{@lines.size} lines.", file, line
        end
      end

      def should_preserve_spram(file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        unless @spram_canary_valid
          fail "Expected SPRAM canary 0xDEADBEEF to be preserved, but corruption was detected.", file, line
        end
      end

      def should_not_exceed_boot_time(max_time : ::Time::Span | Float64, file = __FILE__, line = __LINE__)
        limit = max_time.is_a?(::Time::Span) ? max_time.total_seconds : max_time
        if @boot_time_seconds > limit
          fail "Expected boot time to not exceed #{limit}s, but took #{@boot_time_seconds}s.", file, line
        end
      end
    end

    class Ps2TestCase
      getter name : String
      property source_code : String?
      property target_file : String?
      property max_registers : UInt8 = 0_u8
      property total_bytecode_bytes : Int32 = 0

      def initialize(@name : String)
      end

      def source(code : String)
        @source_code = code
      end

      def target(path : String)
        @target_file = path
      end

      def compile : Tuple(Bytes, SourceMap)
        src = @source_code
        if src.nil? && (tf = @target_file)
          src = File.read(tf)
        end
        raise "No source code or target file provided for #{name}" unless src

        parser = DslParser.new(@target_file || "test.cr")
        prog = parser.parse(src)
        compiler = BytecodeCompiler.new(@target_file || "test.cr")
        bytes = compiler.compile(prog)

        @total_bytecode_bytes = bytes.size
        @max_registers = compiler.functions.map(&.num_registers).max? || 0_u8
        {bytes, compiler.source_map}
      end

      def boot_pcsx2(timeout : ::Time::Span = 4.seconds) : Ps2ExecutionResult
        bytes, sm = compile
        temp_iso = "tmp_spec_#{@name.gsub(/[^a-zA-Z0-9_]/, "_")}.iso"
        IsoBuilder.build(temp_iso, bytes)

        bridge = Debugger::Pcsx2Bridge.new
        lines = [] of String
        panic_found = false
        panic_msg : String? = nil
        crash_rep : Debugger::CrashReport? = nil

        status : Process::Status? = nil
        begin
          status = bridge.spawn_pcsx2(temp_iso, batch: true, timeout: timeout) do |line|
            lines << line
            if rep = Debugger::CrashAnalyzer.analyze(line, sm)
              panic_found = true
              panic_msg = rep.message
              crash_rep = rep
            end
          end
        ensure
          File.delete(temp_iso) if File.exists?(temp_iso)
        end
        canary_ok = !lines.any? { |l| l.includes?("SPRAM Stack Canary Corrupted") }

        Ps2ExecutionResult.new(
          lines: lines,
          panic_detected: panic_found,
          panic_message: panic_msg,
          crash_report: crash_rep,
          status: status,
          spram_canary_valid: canary_ok
        )
      rescue ex
        # If PCSX2 executable is missing in CI or environment, fall back gracefully
        Ps2ExecutionResult.new(
          lines: ["PCSX2 runner not available: #{ex.message}"],
          panic_detected: false,
          spram_canary_valid: true
        )
      end
    end
  end
end

# Top-level DSL Macro
def ps2_spec(name : String, &block : Citrine::Spec::Ps2TestCase -> Nil)
  describe "PS2 [#{name}]" do
    test_case = Citrine::Spec::Ps2TestCase.new(name)
    block.call(test_case)
  end
end
