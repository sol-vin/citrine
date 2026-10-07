require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Examples Runner Suite" do
  it "boots and verifies Example 01: Hello World" do
    tc = Citrine::Spec::Ps2TestCase.new("01_hello_world")
    tc.target("examples/01_hello_world/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 02: Shapes and Text" do
    tc = Citrine::Spec::Ps2TestCase.new("02_shapes_and_text")
    tc.target("examples/02_shapes_and_text/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 03: Entity Fibers" do
    tc = Citrine::Spec::Ps2TestCase.new("03_entity_fibers")
    tc.target("examples/03_entity_fibers/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 04: Safety and Panic" do
    tc = Citrine::Spec::Ps2TestCase.new("04_safety_and_panic")
    tc.target("examples/04_safety_and_panic/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_preserve_spram
  end

  it "boots and verifies Example 05: Hello World" do
    tc = Citrine::Spec::Ps2TestCase.new("05_hello_world")
    tc.target("examples/05_hello_world/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 06: DVD Bounce" do
    tc = Citrine::Spec::Ps2TestCase.new("06_dvd_bounce")
    tc.target("examples/06_dvd_bounce/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 07: Primitives 2D & 3D" do
    tc = Citrine::Spec::Ps2TestCase.new("07_primitives_2d_3d")
    tc.target("examples/07_primitives_2d_3d/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 08: Controller Tester" do
    tc = Citrine::Spec::Ps2TestCase.new("08_controller_tester")
    tc.target("examples/08_controller_tester/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 09: Concurrency Showcase" do
    tc = Citrine::Spec::Ps2TestCase.new("09_concurrency_showcase")
    tc.target("examples/09_concurrency_showcase/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 10: CD Player" do
    tc = Citrine::Spec::Ps2TestCase.new("10_cd_player")
    tc.target("examples/10_cd_player/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 6.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 11: Macro & ECS Showcase" do
    tc = Citrine::Spec::Ps2TestCase.new("11_macro_ecs_showcase")
    tc.target("examples/11_macro_ecs_showcase/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 12: Immediate-Mode UI" do
    tc = Citrine::Spec::Ps2TestCase.new("12_immediate_ui")
    tc.target("examples/12_immediate_ui/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 13: Physics & Verlet Particles" do
    tc = Citrine::Spec::Ps2TestCase.new("13_physics_and_particles")
    tc.target("examples/13_physics_and_particles/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 14: Creative Coding" do
    tc = Citrine::Spec::Ps2TestCase.new("14_creative_coding")
    tc.target("examples/14_creative_coding/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 15: Rigid Body Physics" do
    tc = Citrine::Spec::Ps2TestCase.new("15_rigid_body_physics")
    tc.target("examples/15_rigid_body_physics/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 16: Shaders and Post-FX" do
    tc = Citrine::Spec::Ps2TestCase.new("16_shaders_and_postfx")
    tc.target("examples/16_shaders_and_postfx/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end

  it "boots and verifies Example 17: Inline Assembly & COP0 Telemetry" do
    tc = Citrine::Spec::Ps2TestCase.new("17_inline_assembly")
    tc.target("examples/17_inline_assembly/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 2.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
  end
end

