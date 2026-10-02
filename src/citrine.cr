require "./citrine/version"
require "./citrine/cli/compile_command"
require "./citrine/cli/run_command"
require "./citrine/cli/disasm_command"
require "./citrine/cli/monitor_command"
require "./citrine/cli/new_command"

module Citrine
  def self.print_help
    puts <<-HELP
    Citrine PS2 Toolkit v#{VERSION}
    Crystal Virtual Machine & Raylib-style Game Engine for PlayStation 2

    Usage:
      citrine <command> [options] [arguments]

    Commands:
      compile <file.cr> [-o <out.cbc>]  Compile Crystal game code to Citrine Bytecode
      run <file.cr> [--watch]           Compile and boot game in PCSX2 with hot-reloading
      disasm <file.cbc>                 Disassemble bytecode and inspect symbols
      monitor [--port <port>]           Connect live telemetry monitor to PS2 / PCSX2
      new <project_name>                Scaffold a new Citrine PS2 project
      version                           Display Citrine version
      help                              Display this help message

    Examples:
      citrine new my_game
      citrine run examples/01_hello_pad/main.cr --watch
      citrine compile src/main.cr -o build/game.cbc
      citrine disasm build/game.cbc
    HELP
  end

  def self.main(args = ARGV)
    cmd = args.first?

    case cmd
    when "compile"
      CLI::CompileCommand.run(args[1..])
    when "run"
      CLI::RunCommand.run(args[1..])
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

Citrine.main unless PROGRAM_NAME.includes?("spec")
