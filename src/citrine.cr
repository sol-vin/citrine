require "./citrine/version"
require "./citrine/cli/compile_command"
require "./citrine/cli/run_command"
require "./citrine/cli/disasm_command"
require "./citrine/cli/monitor_command"
require "./citrine/cli/new_command"
require "./citrine/cli/debug_command"
require "./citrine/cli/tui_dashboard"
require "./citrine/cli/iso_command"
require "./citrine/cli/test_command"
require "./citrine/cli/import_command"
require "./citrine/cli/mem_check_command"
require "./citrine/docs"

# The `Citrine` module is the primary namespace and entry point for the Citrine PlayStation 2 toolkit.
#
# Citrine allows writing games in Crystal targeting the Sony PlayStation 2 Emotion Engine (MIPS R5900 @ 294MHz)
# and Graphic Synthesizer (GS). It provides:
# - A Raylib-style ergonomic 2D/3D immediate-mode rendering API
# - Direct-to-GS hardware rasterization via DMA Channel 2 (GIF)
# - DualShock 2 gamepad input with pressure sensitivity and vibration
# - 4-Tier Hybrid Console Memory Architecture (zero-leak per-frame scratch pool, context arenas, explicit pointers, idle mark-sweep)
# - Cooperative fibers and CSP concurrency channels
# - Citrine GL (OpenGL 1.1-style immediate mode pipeline)
#
# ## Getting Started Example
# ```crystal
# require "citrine"
#
# Citrine.init_window(640, 448, "My Citrine Game")
# Citrine.set_target_fps(60)
#
# while Citrine.window_open?
#   Citrine.begin_drawing
#   Citrine.clear_background(Citrine::Color::BLACK)
#
#   Citrine.draw_text("Hello PlayStation 2!", 180, 200, 20, Citrine::Color::RAYWHITE)
#   Citrine.draw_rectangle(100, 100, 50, 50, Citrine::Color::RED)
#
#   Citrine.end_drawing
# end
#
# Citrine.close_window
# ```
#
# ## DualShock 2 Controller Input Example
# ```crystal
# require "citrine"
#
# Citrine.init_window(640, 448, "Pad Input")
#
# player_x = 320
# player_y = 224
#
# while Citrine.window_open?
#   Citrine.begin_drawing
#   Citrine.clear_background(Citrine::Color::BLACK)
#
#   player_x -= 5 if Citrine.button_down?(Citrine::Button::Left)
#   player_x += 5 if Citrine.button_down?(Citrine::Button::Right)
#   player_y -= 5 if Citrine.button_down?(Citrine::Button::Up)
#   player_y += 5 if Citrine.button_down?(Citrine::Button::Down)
#
#   if Citrine.button_pressed?(Citrine::Button::Cross)
#     Citrine.set_rumble(small: 0, large: 128)
#   end
#
#   Citrine.draw_circle(player_x, player_y, 16, Citrine::Color::GREEN)
#   Citrine.end_drawing
# end
# ```
#
# ## 4-Tier Memory Management & Context Arenas Example
# ```crystal
# require "citrine"
#
# # Tier 2 Context Arena: all memory allocated inside is wiped on exit in O(1)
# Citrine.make_vm_context(:inventory_menu) do
#   items = ["Potion", "Ether", "Elixir"]
#   # Render inventory UI...
# end
# # All inventory memory reclaimed with zero fragmentation!
# ```
module Citrine
  def self.print_help
    puts <<-HELP
    Citrine PS2 Toolkit v#{VERSION}
    Crystal Virtual Machine & Raylib-style Game Engine for PlayStation 2

    Usage:
      citrine <command> [options] [arguments]

    Commands:
      ui, tui                           Launch interactive Opal Terminal Dashboard
      compile <file.cr> [-o <out.cbc>]  Compile Crystal game code to Citrine Bytecode
      iso <file.cr | file.cbc> [-o iso] Package bytecode into bootable PS2 ISO9660 disc
      run [file.cr | file.cbc | iso]    Compile, build ISO, and boot in PCSX2
      debug <file.cbc> [--port <port>]  Launch radare2 debugging session on PCSX2 GDB stub
      mem-check [file] [--gdb <port>]   Audit memory leaks, canary integrity, and safety
      test [spec_path]                  Run PS2 automated test suite & PCSX2 hardware specs
      import <type> <file> [options]    Import & optimize media via Fluorite (video, audio, textures)
      disasm <file.cbc>                 Disassemble bytecode and inspect symbols
      monitor [--port <port>]           Connect live telemetry monitor to PS2 / PCSX2
      new <project_name>                Scaffold a new Citrine PS2 project
      version                           Display Citrine version
      help                              Display this help message

    Examples:
      citrine ui
      citrine new my_game
      citrine run examples/01_hello_pad/main.cr --watch
      citrine test spec/ps2/
      citrine import video cutscene.mp4 --fps 15 --dvd-track
      citrine debug build/game.cbc
      citrine compile src/main.cr -o build/game.cbc
      citrine disasm build/game.cbc
    HELP
  end

  def self.main(args = ARGV)
    cmd = args.first?

    case cmd
    when "ui", "tui"
      CLI::TuiDashboard.run
    when "compile"
      CLI::CompileCommand.run(args[1..])
    when "iso", "build-iso"
      CLI::IsoCommand.run(args[1..])
    when "run"
      CLI::RunCommand.run(args[1..])
    when "debug"
      CLI::DebugCommand.run(args[1..])
    when "mem-check", "memcheck"
      CLI::MemCheckCommand.run(args[1..])
    when "test"
      CLI::TestCommand.run(args[1..])
    when "import"
      CLI::ImportCommand.run(args[1..])
    when "disasm"
      CLI::DisasmCommand.run(args[1..])
    when "monitor"
      CLI::MonitorCommand.run(args[1..])
    when "new"
      CLI::NewCommand.run(args[1..])
    when "version", "-v", "--version"
      puts "Citrine PS2 Toolkit v#{VERSION}"
    when "help", "-h", "--help", nil
      print_help
    else
      puts "Unknown command: '#{cmd}'. Run 'citrine help' for usage."
      exit(1)
    end
  end
end

Citrine.main if Path[PROGRAM_NAME].stem.includes?("citrine")
