require "../compiler/source_map"

module Citrine
  module Debugger
    struct CrashReport
      property fault_type : String
      property message : String
      property pc : UInt32?
      property file : String?
      property line : Int32?
      property column : Int32?
      property code_frame : String?
      property remedy : String

      def initialize(
        @fault_type : String,
        @message : String,
        @pc : UInt32? = nil,
        @file : String? = nil,
        @line : Int32? = nil,
        @column : Int32? = nil,
        @code_frame : String? = nil,
        @remedy : String = ""
      )
      end

      def render : String
        io = IO::Memory.new
        sep = "=" * 78
        io.puts "\n" + sep
        io.puts "                      CITRINE HARDWARE CRASH REPORT                           "
        io.puts sep
        io.puts "Fault Type:   #{@fault_type}"
        io.puts "Message:      #{@message}"
        if p = @pc
          io.puts "Bytecode PC:  0x#{p.to_s(16).rjust(4, '0').upcase} (Instruction ##{p})"
        end
        if f = @file
          io.puts "Source File:  #{f}:#{@line || 1}:#{@column || 1}"
        end

        if cf = @code_frame
          io.puts "\nCode Snippet:"
          io.puts cf
        end

        unless @remedy.empty?
          io.puts "\nRemedy Recommendation:"
          io.puts "  #{@remedy}"
        end
        io.puts sep + "\n"
        io.to_s
      end
    end

    class CrashAnalyzer
      def self.analyze(log_line : String, source_map : SourceMap? = nil) : CrashReport?
        # 1. Hardware Panic
        if log_line.includes?("[CITRINE PANIC]")
          msg = log_line.gsub(/.*\[CITRINE PANIC\]\s*/, "").strip
          pc = nil
          if match = msg.match(/\(at PC:\s*(\d+)\)/i)
            pc = match[1].to_u32?
          end

          fault_type = "Citrine-VM Hardware Panic"
          remedy = "Review application logic leading to panic invocation."

          if msg.includes?("Watchdog Timeout")
            fault_type = "Instruction Watchdog Timeout (> 5M instructions without yield)"
            remedy = "Ensure cooperative fibers invoke 'Citrine.yield' or 'Citrine.sleep(seconds)' inside long-running loops to prevent starving other fibers."
          elsif msg.includes?("Stack Overflow")
            fault_type = "Call Stack Overflow (> 64 frames)"
            remedy = "Avoid deep or infinite recursion. Flatten recursive algorithms into loops or iterative fibers."
          elsif msg.includes?("SPRAM")
            fault_type = "Scratchpad RAM (SPRAM) Memory Corruption"
            remedy = "Ensure register allocator frame size does not exceed 1024 registers and SPRAM canary 0xDEADBEEF is preserved."
          end

          loc = pc && source_map ? source_map.find(pc.to_i32) : nil
          file = loc ? loc.file : nil
          line = loc ? loc.line : nil
          col = loc ? loc.column : nil

          code_frame = file && line ? build_code_frame(file, line) : nil

          return CrashReport.new(
            fault_type: fault_type,
            message: msg,
            pc: pc,
            file: file,
            line: line,
            column: col,
            code_frame: code_frame,
            remedy: remedy
          )
        end

        # 2. Memory Safety Error
        if log_line.includes?("[CITRINE MEMORY ERROR]")
          msg = log_line.gsub(/.*\[CITRINE MEMORY ERROR\]\s*/, "").strip
          fault_type = "Citrine Memory Safety Violation"
          remedy = "Verify pointer lifetime, check for double frees, use-after-free, or out-of-bounds pointer arithmetic."
          if msg.includes?("Double free")
            fault_type = "Heap Double Free Detected"
            remedy = "Ensure Pointer.free is called at most once per allocated buffer, or rely on VM context arenas."
          elsif msg.includes?("Use-after-free")
            fault_type = "Heap Use-After-Free Detected"
            remedy = "Do not access pointer or object fields after freeing the memory block or exiting the context arena."
          elsif msg.includes?("unallocated")
            fault_type = "Free on Unallocated Pointer"
            remedy = "Pointer.free was called on an invalid or already remapped memory address."
          end

          return CrashReport.new(
            fault_type: fault_type,
            message: msg,
            remedy: remedy
          )
        end

        # 3. EE Hardware Exception
        if log_line.includes?("Unhandled Exception") || log_line.includes?("TLB Miss") || log_line.includes?("Bus Error")
          return CrashReport.new(
            fault_type: "Emotion Engine Hardware Exception",
            message: log_line,
            remedy: "Verify valid memory access addresses and aligned memory transfers on PS2 hardware."
          )
        end

        nil
      end

      private def self.build_code_frame(filepath : String, line_num : Int32) : String?
        return nil unless File.exists?(filepath)

        lines = File.read_lines(filepath)
        start_idx = Math.max(0, line_num - 3)
        end_idx = Math.min(lines.size - 1, line_num + 2)

        buf = IO::Memory.new
        (start_idx..end_idx).each do |idx|
          curr_line = idx + 1
          marker = (curr_line == line_num) ? "-->" : "   "
          line_text = lines[idx]
          buf.puts sprintf("%s %4d | %s", marker, curr_line, line_text)
          if curr_line == line_num
            leading_spaces = line_text[/^\s*/].size
            buf.puts sprintf("       | %s%s", " " * leading_spaces, "^" * Math.max(1, line_text.strip.size))
          end
        end

        buf.to_s
      rescue
        nil
      end
    end
  end
end
