module Citrine
  module Debugger
    class Radare2Bridge
      # Locates radare2 executable on PATH or known directories
      def self.r2_path : String?
        # Check environment override
        if env_path = ENV["RADARE2_PATH"]?
          return env_path if File.exists?(env_path)
        end

        candidates = [
          "r2",
          "r2.exe",
          File.expand_path("~/scoop/shims/r2.exe"),
          "C:\\Users\\Ian\\scoop\\shims\\r2.exe",
          "C:\\Program Files\\radare2\\bin\\r2.exe",
          "/usr/bin/r2",
          "/usr/local/bin/r2"
        ]

        candidates.each do |c|
          if File.exists?(c)
            return c
          end
          # Check command lookup via system PATH
          found = Process.run(
            {% if flag?(:windows) %} "where" {% else %} "which" {% end %},
            [c],
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Close
          ) do |p|
            if p.wait.success?
              p.output.gets.try(&.strip)
            else
              nil
            end
          end rescue nil
          return found if found && File.exists?(found)
        end

        nil
      end

      # Returns true if radare2 is installed and reachable
      def self.available? : Bool
        !r2_path.nil?
      end

      # Executes non-interactive radare2 command batch against an ELF or ISO
      def self.run_command(target_path : String, commands : String, extra_args : Array(String) = [] of String) : String
        bin = r2_path || raise "radare2 (r2) executable not found on system PATH"
        args = ["-q", "-c", commands]
        args.concat(extra_args)
        args << File.expand_path(target_path)

        output_io = IO::Memory.new
        error_io = IO::Memory.new

        status = Process.run(
          bin,
          args,
          input: Process::Redirect::Close,
          output: output_io,
          error: error_io
        )

        output_io.to_s
      end

      # Analyzes symbol table and returns symbol names
      def self.analyze_symbols(target_path : String) : Array(String)
        output = run_command(target_path, "is")
        lines = [] of String
        output.each_line do |l|
          line = l.strip
          lines << line unless line.empty?
        end
        lines
      end

      # Disassembles MIPS instructions from the given address or function symbol
      def self.disassemble(target_path : String, symbol_or_addr : String = "main", count : Int32 = 25) : Array(String)
        cmd = "e scr.color = 0; e asm.pseudo = 0; e asm.arch = mips; e asm.bits = 32; pd #{count} @ #{symbol_or_addr}"
        output = run_command(target_path, cmd)
        lines = [] of String
        output.each_line do |l|
          line = l.strip
          lines << line unless line.empty?
        end
        lines
      end

      # Audits branch delay slot utilization in disassembled code
      def self.audit_delay_slots(target_path : String, symbol_or_addr : String = "main", count : Int32 = 40) : NamedTuple(branches: Int32, delay_slots_filled: Int32, delay_slots_nop: Int32)
        lines = disassemble(target_path, symbol_or_addr, count)
        branches = 0
        filled = 0
        nops = 0

        branch_keywords = ["j ", "jal ", "jalr ", "jr ", "bal ", "beq ", "bne ", "beqz ", "bnez ", "bgez ", "bltz "]

        (0...lines.size - 1).each do |i|
          curr = lines[i].downcase
          is_br = branch_keywords.any? { |kw| curr.includes?(kw) }
          if is_br
            branches += 1
            delay_slot = lines[i + 1].downcase
            if delay_slot.includes?("nop")
              nops += 1
            else
              filled += 1
            end
          end
        end

        {branches: branches, delay_slots_filled: filled, delay_slots_nop: nops}
      end
    end
  end
end
