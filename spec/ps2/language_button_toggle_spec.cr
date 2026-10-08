require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/subsystems/controller"

describe "Citrine Button Toggle Spec" do
  it "toggles boolean state with Square and Triangle multiple times" do
    tc = Citrine::Spec::Ps2TestCase.new("toggle_buttons_spec")
    tc.source <<-CRYSTAL
      require "citrine"
      Citrine.init_window(640, 448, "Toggle Test")
      pad = Citrine.player(0)
      is_looping = false
      art_showcase = false

      Citrine.main_loop do
        if pad.button_pressed?(Button::Square)
          if is_looping
            debug_puts "[TEST] before toggle: TRUE"
          else
            debug_puts "[TEST] before toggle: FALSE"
          end
          is_looping = !is_looping
          if is_looping
            debug_puts "[TEST] after toggle: TRUE"
          else
            debug_puts "[TEST] after toggle: FALSE"
          end
        end

        if pad.button_pressed?(Button::Triangle)
          art_showcase = !art_showcase
          if art_showcase
            debug_puts "[TEST] Showcase toggled ON"
          else
            debug_puts "[TEST] Showcase toggled OFF"
          end
        end

        Citrine.begin_drawing
        Citrine.clear_background(Color::Black)
        Citrine.end_drawing
      end
      Citrine.close_window
    CRYSTAL

    # Square ON at frame 10, OFF at frame 25
    tc.inject_input(frame: 10, button: Citrine::PadButton::Square, duration: 2)
    tc.inject_input(frame: 25, button: Citrine::PadButton::Square, duration: 2)

    # Triangle ON at frame 15, OFF at frame 30
    tc.inject_input(frame: 15, button: Citrine::PadButton::Triangle, duration: 2)
    tc.inject_input(frame: 30, button: Citrine::PadButton::Triangle, duration: 2)

    result = tc.boot_pcsx2(timeout: 8.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[TEST] before toggle: FALSE")
    result.should_have_output("[TEST] after toggle: TRUE")
    result.should_have_output("[TEST] before toggle: TRUE")
    result.should_have_output("[TEST] after toggle: FALSE")
    result.should_have_output("[TEST] Showcase toggled ON")
    result.should_have_output("[TEST] Showcase toggled OFF")
  end

  it "verifies CD Player example boots, preserves SPRAM, and processes Square and Triangle toggles" do
    tc = Citrine::Spec::Ps2TestCase.new("10_cd_player_toggle_spec")
    tc.target("examples/10_cd_player/main.cr")

    # Frame 15: Toggle Loop Mode ON (Square)
    tc.inject_input(frame: 15, button: Citrine::PadButton::Square, duration: 2)

    # Frame 25: Toggle High-Res Album Art Showcase ON (Triangle)
    tc.inject_input(frame: 25, button: Citrine::PadButton::Triangle, duration: 2)

    # Frame 35: Toggle High-Res Album Art Showcase OFF / Return to Player (Triangle)
    tc.inject_input(frame: 35, button: Citrine::PadButton::Triangle, duration: 2)

    # Frame 45: Toggle Loop Mode OFF (Square)
    tc.inject_input(frame: 45, button: Citrine::PadButton::Square, duration: 2)

    result = tc.boot_pcsx2(timeout: 8.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Button Square pressed!")
    result.should_have_output("[CITRINE] Button Triangle pressed!")
  end
end
