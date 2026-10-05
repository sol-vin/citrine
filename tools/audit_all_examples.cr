require "../src/citrine/spec/ps2_spec"

examples = [
  "examples/01_hello_world/main.cr",
  "examples/02_shapes_and_text/main.cr",
  "examples/03_entity_fibers/main.cr",
  "examples/04_safety_and_panic/main.cr",
  "examples/05_hello_world/main.cr",
  "examples/06_dvd_bounce/main.cr",
  "examples/07_primitives_2d_3d/main.cr",
  "examples/08_controller_tester/main.cr",
  "examples/09_concurrency_showcase/main.cr",
  "examples/10_cd_player/main.cr",
  "examples/11_macro_ecs_showcase/main.cr",
  "examples/12_immediate_ui/main.cr",
  "examples/13_physics_and_particles/main.cr",
  "examples/14_creative_coding/main.cr",
  "examples/15_rigid_body_physics/main.cr",
  "examples/16_shaders_and_postfx/main.cr",
]

b = Citrine::ElfBuilder.new
examples.each do |ex|
  tc = Citrine::Spec::Ps2TestCase.new("audit")
  tc.target(ex)
  bytes, _ = tc.compile
  phases, msgs, loop_start, is_anim = b.parse_cbc(bytes)
  puts "#{ex.split("/")[1]}: is_anim=#{is_anim} phases=#{phases.size}"
end
