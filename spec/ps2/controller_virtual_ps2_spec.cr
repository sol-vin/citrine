require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/subsystems/controller"

describe "Citrine PS2 Virtual Controller & Button Testing Suite" do
  it "injects Cross (X) button press at frame 15 and verifies hardware edge detection" do
    tc = Citrine::Spec::Ps2TestCase.new("virtual_cross_press")
    tc.source <<-CRYSTAL
      require "citrine"
      Citrine.init_window(640, 448, "Virtual Pad Test")
      puts "Virtual Pad Test Initialized"
      Citrine.main_loop do
        Citrine.begin_drawing
        Citrine.clear_background(Color::Black)
        Citrine.draw_text("VIRTUAL PAD TEST", 200, 200, 20, Color::White)
        Citrine.end_drawing
      end
      Citrine.close_window
    CRYSTAL

    tc.inject_input(frame: 15, button: Citrine::PadButton::Cross, duration: 2)

    result = tc.boot_pcsx2(timeout: 6.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
  end

  it "injects multi-button sequence (Cross, Triangle, Square) across timeline" do
    tc = Citrine::Spec::Ps2TestCase.new("virtual_button_sequence")
    tc.source <<-CRYSTAL
      require "citrine"
      Citrine.init_window(640, 448, "Sequence Test")
      Citrine.main_loop do
        Citrine.begin_drawing
        Citrine.clear_background(Color::Blue)
        Citrine.draw_text("SEQUENCE TEST", 200, 200, 20, Color::Yellow)
        Citrine.end_drawing
      end
      Citrine.close_window
    CRYSTAL

    tc.inject_input(frame: 10, button: Citrine::PadButton::Cross, duration: 2)
    tc.inject_input(frame: 25, button: Citrine::PadButton::Triangle, duration: 2)
    tc.inject_input(frame: 40, button: Citrine::PadButton::Square, duration: 2)

    result = tc.boot_pcsx2(timeout: 6.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
    result.should_have_output("[CITRINE] Button Triangle pressed!")
    result.should_have_output("[CITRINE] Button Square pressed!")
  end

  it "boots Example 01: Hello Pad and cycles background via virtual Cross button injection" do
    tc = Citrine::Spec::Ps2TestCase.new("01_hello_pad_virtual_input")
    tc.target("examples/01_hello_pad/main.cr")

    # Inject Cross button at frames 10-15
    tc.inject_input(frame: 10, button: Citrine::PadButton::Cross, duration: 5)

    result = tc.boot_pcsx2(timeout: 8.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
  end

  it "verifies button hold behavior does not trigger spurious edge re-triggers" do
    tc = Citrine::Spec::Ps2TestCase.new("virtual_button_hold")
    tc.source <<-CRYSTAL
      require "citrine"
      Citrine.init_window(640, 448, "Hold Test")
      Citrine.main_loop do
        Citrine.begin_drawing
        Citrine.clear_background(Color::Green)
        Citrine.draw_text("HOLD TEST", 200, 200, 20, Color::White)
        Citrine.end_drawing
      end
      Citrine.close_window
    CRYSTAL

    # Hold Circle button for 15 full frames (frames 10 through 25)
    tc.inject_input(frame: 10, button: Citrine::PadButton::Circle, duration: 15)

    result = tc.boot_pcsx2(timeout: 6.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Button Circle pressed!")
    
    # Assert that the edge trigger fired on only one distinct frame (not repeated across the 15 held frames)
    circle_press_lines = result.lines.select { |l| l.includes?("[CITRINE] Button Circle pressed!") }
    clean_lines = circle_press_lines.map { |l| l.sub(/^\[\s*\d+\.\d+\]\s*/, "") }
    clean_lines.uniq.size.should eq(1)
    clean_lines.size.should be <= 2 # stdout and emulog dual capture
  end
end
