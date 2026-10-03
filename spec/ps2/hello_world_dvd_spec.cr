require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/subsystems/controller"

describe "Citrine PS2 Example 05: Hello World DVD Bouncing Screensaver" do
  it "boots 05_hello_world on PCSX2, injects Cross and R1 to spawn logos, and Triangle to reset" do
    tc = Citrine::Spec::Ps2TestCase.new("05_hello_world_dvd_bounce")
    tc.target("examples/05_hello_world/main.cr")

    # Inject Cross button at frame 15 (spawns 1 logo)
    tc.inject_input(frame: 15, button: Citrine::PadButton::Cross, duration: 2)

    # Inject R1 button at frame 25 (stress tests: spawns 10 logos)
    tc.inject_input(frame: 25, button: Citrine::PadButton::R1, duration: 2)

    # Inject Triangle button at frame 45 (resets back to 1 logo)
    tc.inject_input(frame: 45, button: Citrine::PadButton::Triangle, duration: 2)

    result = tc.boot_pcsx2(timeout: 12.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] PS2 EE Engine Initialized")
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
    result.should_have_output("[CITRINE] Button R1 pressed!")
    result.should_have_output("[CITRINE] Button Triangle pressed!")
  end
end
