require "../src/citrine/iso/elf_builder"
require "../src/citrine/runner/runner"

bytes = Citrine::ElfBuilder.build_default_runner_elf
File.write("runtime/bin/citrine_runner.elf", bytes)
puts "Updated runtime/bin/citrine_runner.elf (#{bytes.size} bytes)."

# Recompile 01_hello_world
runner = Citrine::Runner.new
runner.compile_game("examples/01_hello_world/main.cr", "examples/01_hello_world/game.cbc")
runner.build_iso("examples/01_hello_world/game.cbc", "examples/01_hello_world/game.iso")
puts "Rebuilt examples/01_hello_world/game.iso."

# Recompile hello world
runner.compile_game("examples/05_hello_world/main.cr", "examples/05_hello_world/main.cbc")
runner.build_iso("examples/05_hello_world/main.cbc", "examples/05_hello_world/game.iso")
puts "Rebuilt examples/05_hello_world/game.iso."

# Recompile 02_shapes_and_text
runner.compile_game("examples/02_shapes_and_text/main.cr", "examples/02_shapes_and_text/main.cbc")
runner.build_iso("examples/02_shapes_and_text/main.cbc", "examples/02_shapes_and_text/game.iso")
puts "Rebuilt examples/02_shapes_and_text/game.iso."

