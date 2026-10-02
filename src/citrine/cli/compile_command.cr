require "../runner/runner"
require "../compiler/budget_checker"

module Citrine
  module CLI
    class CompileCommand
      def self.run(args : Array(String))
        input_file = args.first?
        unless input_file && File.exists?(input_file)
          puts "Usage: citrine compile <input.cr> [-o <output.cbc>]"
          exit(1)
        end

        output_file = "game.cbc"
        if idx = args.index("-o")
          output_file = args[idx + 1]? || "game.cbc"
        end

        puts "[Citrine] Compiling #{input_file} -> #{output_file}..."
        runner = Runner.new
        t0 = Time.instant
        compiler = runner.compile_game(input_file, output_file)
        dt = (Time.instant - t0).total_milliseconds

        size = File.size(output_file)
        puts "[Citrine] Success: #{output_file} generated (#{size} bytes) in #{dt.round(1)} ms."

        # Safety Budget Audit
        fn_regs = {} of String => UInt8
        compiler.functions.each { |f| fn_regs[f.name] = f.num_registers }
        report = BudgetChecker.check(fn_regs, size.to_i32)

        puts "\n=== PS2 Hardware Resource Audit ==="
        puts "Total Functions:       #{report.total_functions}"
        puts "Peak SPRAM Frame:      #{report.max_frame_registers} / 1024 registers (#{report.max_frame_func_name})"
        puts "Bytecode Size:         #{size} bytes"

        if report.warnings.size > 0
          puts "\n[Warnings]"
          report.warnings.each { |w| puts "  * #{w}" }
        end

        if report.errors.size > 0
          puts "\n[Errors]"
          report.errors.each { |e| puts "  ! #{e}" }
          exit(1)
        end

        puts "\nBudget Status: PASSED (Hardware limits verified)."
      end
    end
  end
end
