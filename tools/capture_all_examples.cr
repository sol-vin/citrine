# tools/capture_all_examples.cr
# Boots each of the 16 overhauled Citrine examples,
# generates GS native framebuffer snapshots,
# verifies PCSX2 EE execution & SPRAM integrity,
# and archives the resulting PNG artifacts in the conversation artifact directory.

require "../src/citrine/spec/ps2_spec"
require "../src/citrine/iso/elf_builder"
require "../src/citrine/gs/framebuffer_renderer"
require "file_utils"

ARTIFACT_DIR = "C:/Users/Ian/.gemini/antigravity/brain/800ae8f6-80d0-4428-93ad-3dc0043d07e3"

EXAMPLES = [
  {"01_hello_world", "examples/01_hello_world/main.cr", "example_01_hello_world.png"},
  {"02_shapes_and_text", "examples/02_shapes_and_text/main.cr", "example_02_shapes_and_text.png"},
  {"03_entity_fibers", "examples/03_entity_fibers/main.cr", "example_03_entity_fibers.png"},
  {"04_safety_and_panic", "examples/04_safety_and_panic/main.cr", "example_04_safety_and_panic.png"},
  {"05_hello_world", "examples/05_hello_world/main.cr", "example_05_hello_world.png"},
  {"06_dvd_bounce", "examples/06_dvd_bounce/main.cr", "example_06_dvd_bounce.png"},
  {"07_primitives_2d_3d", "examples/07_primitives_2d_3d/main.cr", "example_07_primitives_2d_3d.png"},
  {"08_controller_tester", "examples/08_controller_tester/main.cr", "example_08_controller_tester.png"},
  {"09_concurrency_showcase", "examples/09_concurrency_showcase/main.cr", "example_09_concurrency_showcase.png"},
  {"10_cd_player", "examples/10_cd_player/main.cr", "example_10_cd_player.png"},
  {"11_macro_ecs_showcase", "examples/11_macro_ecs_showcase/main.cr", "example_11_macro_ecs_showcase.png"},
  {"12_immediate_ui", "examples/12_immediate_ui/main.cr", "example_12_immediate_ui.png"},
  {"13_physics_and_particles", "examples/13_physics_and_particles/main.cr", "example_13_physics_and_particles.png"},
  {"14_creative_coding", "examples/14_creative_coding/main.cr", "example_14_creative_coding.png"},
  {"15_rigid_body_physics", "examples/15_rigid_body_physics/main.cr", "example_15_rigid_body_physics.png"},
  {"16_shaders_and_postfx", "examples/16_shaders_and_postfx/main.cr", "example_16_shaders_and_postfx.png"},
]

puts "=== Citrine Batch Screenshot Bridge & PCSX2 Validation ==="
puts "Total Examples: #{EXAMPLES.size}"
puts "Artifact Directory: #{ARTIFACT_DIR}"

success_count = 0

EXAMPLES.each_with_index do |(name, path, artifact_file), idx|
  print "[#{idx + 1}/#{EXAMPLES.size}] #{name} (#{path})... "
  
  tc = Citrine::Spec::Ps2TestCase.new("snap_#{name}")
  tc.target(path)
  
  # 1. Compile CBC Bytecode
  bytes, sm = tc.compile
  
  # 2. Extract GS Draw Commands and Render Framebuffer PNG
  builder = Citrine::ElfBuilder.new
  phases, msgs, loop_start, animated = builder.parse_cbc(bytes)
  
  target_artifact = File.join(ARTIFACT_DIR, artifact_file)
  if phase = phases.first?
    Citrine::GS::FramebufferRenderer.save_png(phase.commands, target_artifact)
  end
  
  # 3. Boot in PCSX2 to verify hardware execution & SPRAM
  result = tc.boot_pcsx2(timeout: 2.seconds)
  if result.panic_detected
    puts "FAILED (Panic: #{result.panic_message})"
  elsif !result.spram_canary_valid
    puts "FAILED (SPRAM Canary Corrupted)"
  else
    img_size = File.exists?(target_artifact) ? File.size(target_artifact) : 0
    puts "PASSED (Artifact: #{artifact_file}, #{img_size} bytes, SPRAM: OK)"
    success_count += 1
  end
end

puts ""
puts "=== Batch Complete: #{success_count}/#{EXAMPLES.size} Passed and Rendered ==="
