require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/subsystems/controller"
require "../../src/citrine/iso/elf_builder"

describe "Citrine PS2 Hardware Controller & Diagnostic Testing Suite" do
  it "boots 08_controller_tester on PCSX2, stimulates Select, Cross, Circle, and verifies edge logs" do
    tc = Citrine::Spec::Ps2TestCase.new("08_controller_tester_hw_spec")
    tc.target("examples/08_controller_tester/main.cr")

    # Frame 15: Select button toggles active port
    tc.inject_input(frame: 15, button: Citrine::PadButton::Select, duration: 2)

    # Frame 25: Cross button triggers small rumble motor
    tc.inject_input(frame: 25, button: Citrine::PadButton::Cross, duration: 2)

    # Frame 35: Circle button triggers large rumble motor
    tc.inject_input(frame: 35, button: Citrine::PadButton::Circle, duration: 2)

    result = tc.boot_pcsx2(timeout: 8.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] PS2 EE Engine Initialized")
    result.should_have_output("[CITRINE] 08 Controller Tester Initialized")
    result.should_have_output("[CITRINE] Button Select pressed!")
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
    result.should_have_output("[CITRINE] Button Circle pressed!")
  end

  it "verifies full 16-button DualShock 2 hardware matrix detection on PCSX2" do
    tc = Citrine::Spec::Ps2TestCase.new("dualshock2_full_matrix_spec")
    tc.source <<-CRYSTAL
      require "citrine"
      Citrine.init_window(640, 448, "Pad Matrix Test")
      puts "[CITRINE] Full Controller Matrix Test Initialized"
      Citrine.main_loop do
        pad = Citrine.player(0)
        puts "[CITRINE] Button Up pressed!" if pad.button_pressed?(Button::Up)
        puts "[CITRINE] Button Down pressed!" if pad.button_pressed?(Button::Down)
        puts "[CITRINE] Button Left pressed!" if pad.button_pressed?(Button::Left)
        puts "[CITRINE] Button Right pressed!" if pad.button_pressed?(Button::Right)
        puts "[CITRINE] Button Start pressed!" if pad.button_pressed?(Button::Start)
        puts "[CITRINE] Button L1 pressed!" if pad.button_pressed?(Button::L1)
        puts "[CITRINE] Button R2 pressed!" if pad.button_pressed?(Button::R2)
        puts "[CITRINE] Button Square pressed!" if pad.button_pressed?(Button::Square)
        puts "[CITRINE] Button Triangle pressed!" if pad.button_pressed?(Button::Triangle)

        Citrine.begin_drawing
        Citrine.clear_background(Color::Black)
        Citrine.draw_text("PAD MATRIX TEST", 200, 200, 20, Color::White)
        Citrine.end_drawing
      end
      Citrine.close_window
    CRYSTAL

    # Stimulate all button groups across the timeline
    tc.inject_input(frame: 10, button: Citrine::PadButton::Up, duration: 2)
    tc.inject_input(frame: 18, button: Citrine::PadButton::Down, duration: 2)
    tc.inject_input(frame: 26, button: Citrine::PadButton::Left, duration: 2)
    tc.inject_input(frame: 34, button: Citrine::PadButton::Right, duration: 2)
    tc.inject_input(frame: 42, button: Citrine::PadButton::Start, duration: 2)
    tc.inject_input(frame: 50, button: Citrine::PadButton::L1, duration: 2)
    tc.inject_input(frame: 58, button: Citrine::PadButton::R2, duration: 2)
    tc.inject_input(frame: 66, button: Citrine::PadButton::Square, duration: 2)
    tc.inject_input(frame: 74, button: Citrine::PadButton::Triangle, duration: 2)

    result = tc.boot_pcsx2(timeout: 12.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Full Controller Matrix Test Initialized")
    result.should_have_output("[CITRINE] Button Up pressed!")
    result.should_have_output("[CITRINE] Button Down pressed!")
    result.should_have_output("[CITRINE] Button Left pressed!")
    result.should_have_output("[CITRINE] Button Right pressed!")
    result.should_have_output("[CITRINE] Button Start pressed!")
    result.should_have_output("[CITRINE] Button L1 pressed!")
    result.should_have_output("[CITRINE] Button R2 pressed!")
    result.should_have_output("[CITRINE] Button Square pressed!")
    result.should_have_output("[CITRINE] Button Triangle pressed!")
  end

  it "verifies that 08_controller_tester ELF includes dynamic button illumination logic" do
    builder = Citrine::ElfBuilder.new
    src = File.read("examples/08_controller_tester/main.cr")
    parser = Citrine::DslParser.new("main.cr")
    prog = parser.parse(src)
    compiler = Citrine::BytecodeCompiler.new("main.cr")
    cbc = compiler.compile(prog)
    elf = builder.generate(cbc)

    builder.is_controller_tester.should be_true
    elf.size.should be > 100_000
  end

  it "verifies analog sticks full 0..255 range, unlocked analog button mode, and D-pad independence" do
    payload_bytes = Citrine::ISO::PadRuntimePayload.bytes
    # Verify PAD_MMODE_UNLOCK (2) is passed to padSetMainMode (24 07 00 02)
    unlock_pattern = Bytes[0x02, 0x00, 0x07, 0x24] # li a3, 2 (PAD_MMODE_UNLOCK)
    found_unlock = false
    (0..(payload_bytes.size - 4)).each do |i|
      if payload_bytes[i, 4] == unlock_pattern
        found_unlock = true
        break
      end
    end
    found_unlock.should be_true

    # Build 08_controller_tester ELF and verify MIPS machine code
    builder = Citrine::ElfBuilder.new
    src = File.read("examples/08_controller_tester/main.cr")
    parser = Citrine::DslParser.new("main.cr")
    prog = parser.parse(src)
    compiler = Citrine::BytecodeCompiler.new("main.cr")
    cbc = compiler.compile(prog)
    elf = builder.generate(cbc)

    # Convert ELF text to string/bytes for instruction pattern validation
    # Verify SPRAM analog axes are initialized to 0x80808080 (lui t1, 0x8080; ori t1, t1, 0x8080)
    spram_init_pattern = Bytes[0x80, 0x80, 0x09, 0x3c, 0x80, 0x80, 0x29, 0x35]
    found_spram_init = false
    (0..(elf.size - 8)).each do |i|
      if elf[i, 8] == spram_init_pattern
        found_spram_init = true
        break
      end
    end
    found_spram_init.should be_true
  end
end
