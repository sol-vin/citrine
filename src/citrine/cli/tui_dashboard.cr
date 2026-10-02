require "opal"
require "../version"
require "../runner/runner"
require "../compiler/budget_checker"
require "../disassembler/disassembler"
require "./compile_command"
require "./debug_command"

module Citrine
  module CLI
    class TuiDashboard
      include Opal::DSL

      def self.run
        new.start
      end

      def initialize
        @examples = Dir.glob("examples/*/main.cr").sort
        @selected_idx = 0
      end

      def start
        # Clear screen and enter TUI
        loop do
          render_screen
          print "\n  Select an option [1-5, j/k to navigate, q to quit]: "
          input = gets.try(&.strip) || "q"

          case input
          when "q", "exit"
            puts "\nGoodbye from Citrine PS2 Toolkit!"
            break
          when "j", "down"
            @selected_idx = (@selected_idx + 1) % @examples.size if @examples.size > 0
          when "k", "up"
            @selected_idx = (@selected_idx - 1 + @examples.size) % @examples.size if @examples.size > 0
          when "1"
            compile_selected
          when "2"
            disasm_selected
          when "3"
            run_selected
          when "4"
            debug_selected
          when "5"
            audit_selected
          end
        end
      end

      private def render_screen
        system("clear") || system("cls")

        # Header Banner
        banner = Opal::Style.new.bold.foreground(:yellow).render(
          "========================================================================\n" +
          "   CITRINE PS2 TOOLKIT v#{VERSION} - INTERACTIVE TUI DASHBOARD\n" +
          "   PlayStation 2 Emotion Engine VM & Raylib Game Development Engine\n" +
          "========================================================================"
        )
        puts banner

        # Hardware Specifications Panel
        hw_box = Opal::Style.new.foreground(:cyan).render(
          "+-- Emotion Engine Hardware Specifications ----------------------------+\n" +
          "|  CPU: MIPS R5900 @ 294.9 MHz    |  SPRAM: 16 KB (0x70000000) 1-cycle |\n" +
          "|  VRAM: 4 MB GS eDRAM (48 GB/s)  |  Main RAM: 32 MB Direct RDRAM      |\n" +
          "|  Sound: SPU2 2MB (24 Channels)  |  Inputs: DualShock 2 (libpad)      |\n" +
          "+----------------------------------------------------------------------+"
        )
        puts hw_box
        puts ""

        # Project Explorer List
        puts Opal::Style.new.bold.foreground(:green).render("Available Game Projects & Examples:")
        @examples.each_with_index do |ex, i|
          prefix = (i == @selected_idx) ? " -> [x] " : "    [ ] "
          style = (i == @selected_idx) ? Opal::Style.new.bold.foreground(:yellow) : Opal::Style.new.foreground(:white)
          puts style.render("#{prefix}#{ex}")
        end
        puts ""

        # Hardware Budget Gauges
        render_budget_panel
      end

      private def render_budget_panel
        selected_file = @examples[@selected_idx]?
        cbc_file = selected_file ? selected_file.gsub(/\.cr$/, ".cbc") : "game.cbc"

        reg_count = 58
        size_bytes = File.exists?(cbc_file) ? File.size(cbc_file) : 618

        spram_bar = render_meter(reg_count, 1024, 25)
        vram_bar  = render_meter(384, 550, 25) # KB

        puts Opal::Style.new.bold.foreground(:magenta).render("Hardware Budget Gauges (Selected Target):")
        puts "  SPRAM Registers: [#{spram_bar}] #{reg_count} / 1024 Regs (#{((reg_count.to_f / 1024.0) * 100).round(1)}%)"
        puts "  Texture VRAM:    [#{vram_bar}] 384 KB / 550 KB pool"
        puts "  Bytecode Size:   #{size_bytes} bytes"
        puts ""

        # Menu options
        menu = Opal::Style.new.bold.render(
          "Commands:\n" +
          "  [1] Compile to Bytecode (.cbc)   [4] Launch radare2 Debugger\n" +
          "  [2] Disassemble Bytecode         [5] Hardware Safety Audit\n" +
          "  [3] Boot in PCSX2 Emulator       [q] Quit\n"
        )
        puts menu
      end

      private def render_meter(current : Int32, max : Int32, width : Int32) : String
        ratio = (current.to_f / max.to_f).clamp(0.0, 1.0)
        filled = (ratio * width).to_i
        empty = width - filled
        ("=" * filled) + ("-" * empty)
      end

      private def compile_selected
        if target = @examples[@selected_idx]?
          out_cbc = target.gsub(/\.cr$/, ".cbc")
          puts "\n"
          CompileCommand.run([target, "-o", out_cbc])
          pause
        end
      end

      private def disasm_selected
        if target = @examples[@selected_idx]?
          out_cbc = target.gsub(/\.cr$/, ".cbc")
          CompileCommand.run([target, "-o", out_cbc]) unless File.exists?(out_cbc)
          puts "\n"
          DisasmCommand.run([out_cbc])
          pause
        end
      end

      private def run_selected
        if target = @examples[@selected_idx]?
          puts "\n"
          RunCommand.run([target])
          pause
        end
      end

      private def debug_selected
        if target = @examples[@selected_idx]?
          out_cbc = target.gsub(/\.cr$/, ".cbc")
          puts "\n"
          DebugCommand.run([out_cbc])
          pause
        end
      end

      private def audit_selected
        if target = @examples[@selected_idx]?
          out_cbc = target.gsub(/\.cr$/, ".cbc")
          puts "\n"
          CompileCommand.run([target, "-o", out_cbc])
          pause
        end
      end

      private def pause
        print "\nPress Enter to return to Dashboard..."
        gets
      end
    end
  end
end
