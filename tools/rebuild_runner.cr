require "../src/citrine/iso/elf_builder"
require "../src/citrine/runner/runner"

bytes = Citrine::ElfBuilder.build_default_runner_elf
File.write("runtime/bin/citrine_runner.elf", bytes)
puts "Updated runtime/bin/citrine_runner.elf (#{bytes.size} bytes)."

# Recompile 01_hello_pad
runner = Citrine::Runner.new
runner.compile_game("examples/01_hello_pad/main.cr", "examples/01_hello_pad/game.cbc")
runner.build_iso("examples/01_hello_pad/game.cbc", "examples/01_hello_pad/game.iso")
puts "Rebuilt examples/01_hello_pad/game.iso."

# Recompile hello world
runner.compile_game("examples/05_hello_world/main.cr", "examples/05_hello_world/main.cbc")
runner.build_iso("examples/05_hello_world/main.cbc", "examples/05_hello_world/game.iso")
puts "Rebuilt examples/05_hello_world/game.iso."

