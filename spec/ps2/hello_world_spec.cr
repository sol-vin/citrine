require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/iso/phase_extractor"
require "../../src/citrine/iso/elf_builder"

describe "Citrine PS2 Example 01: Hello World & Live Telemetry" do
  it "extracts 60-frame 1-second live blinking animation for 01_hello_world" do
    tc = Citrine::Spec::Ps2TestCase.new("01_hello_world_phase_spec")
    tc.target("examples/01_hello_world/main.cr")
    bytes, _ = tc.compile

    profile = Citrine::ISO::PhaseExtractor.extract(bytes)
    profile.phases.size.should eq(60)
    profile.is_animated.should be_true

    # Frame 0 (frame 1): circle is ON (Red), text includes "Hello World \n Frame: 1" and "[LIVE]"
    frame0 = profile.phases[0].commands
    frame0.any? { |c| c.type == Citrine::GS::DrawCommand::Type::Text && c.text.includes?("Hello World") }.should be_true
    frame0.any? { |c| c.type == Citrine::GS::DrawCommand::Type::Text && c.text.includes?("[LIVE]") }.should be_true
    circle0 = frame0.find { |c| c.type == Citrine::GS::DrawCommand::Type::Circle }
    circle0.should_not be_nil
    circle0.not_nil!.color.should eq(0xFF0000FF_u32) # Red (blink ON)

    # Frame 30 (frame 31): circle is OFF (DarkGray)
    frame30 = profile.phases[30].commands
    circle30 = frame30.find { |c| c.type == Citrine::GS::DrawCommand::Type::Circle }
    circle30.should_not be_nil
    circle30.not_nil!.color.should eq(0xFF505050_u32) # DarkGray (blink OFF)
  end

  it "boots 01_hello_world on PCSX2, runs 60 FPS animation, and preserves SPRAM" do
    tc = Citrine::Spec::Ps2TestCase.new("01_hello_world_hw_spec")
    tc.target("examples/01_hello_world/main.cr")

    result = tc.boot_pcsx2(timeout: 5.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] PS2 EE Engine Initialized")
  end

  it "detects and configures 5 dynamic frame digits in RodataSegmentBuilder" do
    tc = Citrine::Spec::Ps2TestCase.new("01_hello_world_rodata_spec")
    tc.target("examples/01_hello_world/main.cr")
    bytes, _ = tc.compile

    profile = Citrine::ISO::PhaseExtractor.extract(bytes)
    rodata = Citrine::ISO::RodataSegmentBuilder.build(profile)
    rodata.frame_text_present.should be_true
    rodata.frame_digit_offsets.size.should eq(5)
    rodata.digit_table_addr.should be > 0_u32
  end
end
