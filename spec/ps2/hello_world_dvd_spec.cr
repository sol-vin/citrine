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

    result = tc.boot_pcsx2(timeout: 18.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] PS2 EE Engine Initialized")
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
    result.should_have_output("[CITRINE] Button R1 pressed!")
    result.should_have_output("[CITRINE] Button Triangle pressed!")
  end

  it "chunks payloads exceeding the 15-bit NLOOP limit (32767 QWs) into valid GIFTag sequences" do
    # Each Rect command produces 1 quad = 4 QWs (64 bytes).
    # 9,000 Rect commands = 36,000 QWs (> 32,767 NLOOP hardware limit).
    cmds = (0...9000).map do |i|
      Citrine::GS::DrawCommand.new(Citrine::GS::DrawCommand::Type::Rect, i % 640, (i * 2) % 448, 10, 10, color: 0xFFFFFFFF_u32)
    end

    packet = Citrine::GS::GifPacketBuilder.build_draw_packet(cmds)
    # Total QWs: 36,000 vertex QWs + 2 GIFTag header QWs = 36,002 QWs = 576,032 bytes
    packet.size.should eq(576_032)

    # First GIFTag: NLOOP = 32767, EOP = 0
    tag1_lo = IO::ByteFormat::LittleEndian.decode(UInt64, packet[0, 8])
    (tag1_lo & 0x7FFF_u64).should eq(32767_u64)
    ((tag1_lo >> 15) & 1_u64).should eq(0_u64) # EOP = 0

    # Second GIFTag: offset = 16 + 32767 * 16 = 524,288
    tag2_offset = 16 + (32767 * 16)
    tag2_lo = IO::ByteFormat::LittleEndian.decode(UInt64, packet[tag2_offset, 8])
    (tag2_lo & 0x7FFF_u64).should eq(3233_u64) # 36000 - 32767 = 3233
    ((tag2_lo >> 15) & 1_u64).should eq(1_u64) # EOP = 1
  end

  it "verifies 05_hello_world compiles and builds with dynamic DVD screensaver engine" do
    tc = Citrine::Spec::Ps2TestCase.new("05_phase_audit")
    tc.target("examples/05_hello_world/main.cr")
    bytes, _ = tc.compile

    builder = Citrine::ElfBuilder.new
    phases, messages, loop_start, is_animated = builder.parse_cbc(bytes)

    # Must enable dynamic DVD screensaver mode
    builder.is_dvd_screensaver.should be_true

    # Frame 0 must be captured for screenshot bridge
    phases.size.should be >= 1

    # Frame 0 contains border and HUD commands
    frame0 = phases[0].commands
    frame0.any? { |c| c.type == Citrine::GS::DrawCommand::Type::Rect }.should be_true
    frame0.any? { |c| c.text.try(&.includes?("CROSS")) }.should be_true
  end
end
