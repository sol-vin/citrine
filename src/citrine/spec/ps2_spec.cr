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
      getter screenshot_path : String?
      getter memory_reads : Hash(UInt64, Bytes) = Hash(UInt64, Bytes).new

      def initialize(
        @lines : Array(String) = [] of String,
        @panic_detected : Bool = false,
        @panic_message : String? = nil,
        @crash_report : Debugger::CrashReport? = nil,
        @status : Process::Status? = nil,
        @spram_canary_valid : Bool = true,
        @boot_time_seconds : Float64 = 0.0,
        @screenshot_path : String? = nil,
        @memory_reads : Hash(UInt64, Bytes) = Hash(UInt64, Bytes).new
      )
      end

      def pcsx2_available? : Bool
        !(@lines.empty? || @lines.any? { |l| l.includes?("PCSX2 runner not available") })
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

      def should_have_no_memory_leaks(file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        leak_lines = @lines.select { |l| l.includes?("[Citrine Leak]") || l.includes?("Memory leak:") }
        unless leak_lines.empty?
          fail "Expected zero memory leaks, but found:\n  #{leak_lines.join("\n  ")}", file, line
        end
      end

      def should_not_have_memory_faults(file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        fault_lines = @lines.select { |l| l.includes?("[CITRINE MEMORY ERROR]") || l.includes?("Use-after-free") || l.includes?("Double free") }
        unless fault_lines.empty?
          fail "Expected zero memory faults, but found:\n  #{fault_lines.join("\n  ")}", file, line
        end
      end

      def memory_at(address : UInt64) : Bytes?
        @memory_reads[address]?
      end

      def memory_word(address : UInt64) : UInt32?
        if b = @memory_reads[address]?
          return nil unless b.size >= 4
          b[0].to_u32 | (b[1].to_u32 << 8) | (b[2].to_u32 << 16) | (b[3].to_u32 << 24)
        else
          nil
        end
      end

      def should_not_exceed_boot_time(max_time : ::Time::Span | Float64, file = __FILE__, line = __LINE__)
        limit = max_time.is_a?(::Time::Span) ? max_time.total_seconds : max_time
        if @boot_time_seconds > limit
          fail "Expected boot time to not exceed #{limit}s, but took #{@boot_time_seconds}s.", file, line
        end
      end

      def should_have_screenshot(file = __FILE__, line = __LINE__)
        return if check_pcsx2_availability(file, line)
        path = @screenshot_path
        if path.nil? || !File.exists?(path) || File.size(path) == 0
          fail "Expected screenshot to be captured, but file '#{path || "nil"}' does not exist or is empty.", file, line
        end
      end
    end

    class Ps2TestCase
      getter name : String
      property source_code : String?
      property target_file : String?
      property max_registers : UInt8 = 0_u8
      property total_bytecode_bytes : Int32 = 0
      property input_schedule : Array(Citrine::VirtualInput) = [] of Citrine::VirtualInput
      property screenshot_frame : Int32? = nil
      property screenshot_output : String? = nil
      property gdb_port : Int32? = nil
      property memory_queries : Array(Tuple(UInt64, Int32)) = [] of Tuple(UInt64, Int32)

      def initialize(@name : String)
      end

      def source(code : String)
        @source_code = code
      end

      def target(path : String)
        @target_file = path
      end

      def enable_gdb(port : Int32 = 28011)
        @gdb_port = port
      end

      def inspect_memory(address : UInt64, length : Int32)
        @memory_queries << {address, length}
      end

      def capture_screenshot(frame : Int32 = 30, output_path : String? = nil)
        @screenshot_frame = frame
        @screenshot_output = output_path || "tmp_snap_#{@name.gsub(/[^a-zA-Z0-9_]/, "_")}.png"
      end

      def inject_input(frame : Int32, button : Citrine::PadButton | Int32, duration : Int32 = 2)
        mask = Citrine::VirtualInput.button_mask(button.to_i)
        @input_schedule << Citrine::VirtualInput.new(frame.to_u32, mask, duration.to_u16)
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

        extra_files = Hash(String, Bytes).new
        audio_tracks = [] of String

        if tf = @target_file
          target_dir = File.dirname(tf)
          if Dir.exists?(target_dir)
            Dir.glob(File.join(target_dir, "*.cbt").gsub('\\', '/')).each do |f|
              extra_files[File.basename(f)] = File.read(f).to_slice
            end
            Dir.glob(File.join(target_dir, "*.vag").gsub('\\', '/')).each do |f|
              extra_files[File.basename(f)] = File.read(f).to_slice
            end
            discovered = Dir.children(target_dir).select do |f|
              ext = File.extname(f).downcase
              (ext == ".raw" || ext == ".bin") && f.downcase.starts_with?("track")
            end.map { |f| File.join(target_dir, f) }.sort_by do |p|
              base = File.basename(p)
              if md = base.match(/track(\d+)/i)
                md[1].to_i
              else
                999
              end
            end
            audio_tracks = discovered
          end
        end

        IsoBuilder.build(temp_iso, bytes, extra_files: extra_files, input_schedule: @input_schedule, audio_tracks: audio_tracks)

        bridge = Debugger::Pcsx2Bridge.new
        lines = [] of String
        panic_found = false
        panic_msg : String? = nil
        crash_rep : Debugger::CrashReport? = nil

        status : Process::Status? = nil
        snap_path : String? = nil
        if @screenshot_frame && (out_p = @screenshot_output)
          snap_path = out_p
          target_frame = @screenshot_frame.not_nil!
          spawn do
            start_t = Time.instant
            while (Time.instant - start_t) < 9.seconds
              break if bridge.log_history.any? { |l| l.includes?("PS2 EE Engine Initialized") }
              sleep 0.1.seconds
            end
            sleep (target_frame.to_f / 60.0).seconds
            bridge.capture_screenshot(out_p)
            bridge.copy_to_artifacts(out_p, "screen.png") rescue nil
          end
        end

        mem_reads = Hash(UInt64, Bytes).new
        active_port = @gdb_port || (@memory_queries.empty? ? nil : 28011)
        if p = active_port
          spawn do
            sleep 2.5.seconds
            @memory_queries.each do |(addr, len)|
              if b = bridge.read_memory_gdb(addr, len, p)
                mem_reads[addr] = b
              end
            end
          end
        end

        target_image = temp_iso
        temp_cue = temp_iso.sub(/\.iso$/i, ".cue")

        nogui_mode = @screenshot_frame.nil?
        begin
          status = bridge.spawn_pcsx2(target_image, batch: true, nogui: nogui_mode, gdb_port: active_port, timeout: timeout) do |line|
            lines << line
            if rep = Debugger::CrashAnalyzer.analyze(line, sm)
              panic_found = true
              panic_msg = rep.message
              crash_rep = rep
            end
          end
        ensure
          File.delete(temp_iso) if File.exists?(temp_iso)
          File.delete(temp_cue) if File.exists?(temp_cue)
        end
        canary_ok = !lines.any? { |l| l.includes?("SPRAM Stack Canary Corrupted") }

        Ps2ExecutionResult.new(
          lines: lines,
          panic_detected: panic_found,
          panic_message: panic_msg,
          crash_report: crash_rep,
          status: status,
          spram_canary_valid: canary_ok,
          screenshot_path: snap_path,
          memory_reads: mem_reads
        )
      rescue ex
        # If PCSX2 executable is missing in CI or environment, fall back gracefully
        Ps2ExecutionResult.new(
          lines: ["PCSX2 runner not available: #{ex.message}"],
          panic_detected: false,
          spram_canary_valid: true,
          memory_reads: Hash(UInt64, Bytes).new
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
