# Citrine PS2 Example 12: Immediate-Mode UI & DualShock 2 Navigation
# Demonstrates require "citrine/ui", panel, button, slider_float, slider_int, checkbox, progress_bar
# Optimized for zero per-frame heap allocations with static colors and controller navigation

require "citrine"
require "citrine/ui"

Citrine.init_window(640, 448, "Citrine PS2 - Immediate-Mode UI")
Citrine.set_target_fps(60)

# Pre-allocated color constants (0 heap allocations inside main loop)
BG_COLOR       = Color.new(20_u8, 24_u8, 35_u8, 255_u8)
HEADER_COLOR   = Color.new(30_u8, 38_u8, 55_u8, 255_u8)
TEXT_WHITE     = Color.new(240_u8, 245_u8, 255_u8, 255_u8)
FOOTER_BG      = Color.new(25_u8, 32_u8, 45_u8, 240_u8)
STATUS_GOLD    = Color.new(255_u8, 215_u8, 0_u8, 255_u8)
STATUS_MUTED   = Color.new(170_u8, 180_u8, 200_u8, 255_u8)
FOCUS_OUTLINE  = Color.new(52_u8, 152_u8, 219_u8, 220_u8)

sound_vol = 0.8_f32
rumble_enabled = true
difficulty = 2
mana = 75.0_f32
dialog_status = "Status: READY"
selected_element = 0 # 0: Vol, 1: Rumble, 2: Diff, 3: Save, 4: Reset

Citrine.main_loop do
  pad = Citrine.player(0)

  # DualShock 2 Controller UI Navigation
  if pad.button_pressed?(Button::Down)
    selected_element = (selected_element + 1) % 5
  elsif pad.button_pressed?(Button::Up)
    selected_element = (selected_element + 4) % 5
  end

  # Adjust selected value with Left / Right
  if selected_element == 0 # Volume slider
    if pad.button_down?(Button::Right)
      sound_vol = Math.min(sound_vol + 0.02_f32, 1.0_f32)
    elsif pad.button_down?(Button::Left)
      sound_vol = Math.max(sound_vol - 0.02_f32, 0.0_f32)
    end
  elsif selected_element == 1 # Checkbox
    if pad.button_pressed?(Button::Cross)
      rumble_enabled = !rumble_enabled
    end
  elsif selected_element == 2 # Difficulty slider
    if pad.button_pressed?(Button::Right)
      difficulty = Math.min(difficulty + 1, 5)
    elsif pad.button_pressed?(Button::Left)
      difficulty = Math.max(difficulty - 1, 1)
    end
  elsif selected_element == 3 # Save button
    if pad.button_pressed?(Button::Cross)
      dialog_status = "Settings Saved Successfully!"
    end
  elsif selected_element == 4 # Reset button
    if pad.button_pressed?(Button::Cross)
      sound_vol = 0.5_f32
      rumble_enabled = false
      difficulty = 1
      dialog_status = "Settings Reset to Default!"
    end
  end

  # UI Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(BG_COLOR)

  # Top Banner
  Citrine.draw_rectangle(0, 0, 640, 32, HEADER_COLOR)
  Citrine.draw_text("CITRINE PS2: IMMEDIATE-MODE UI (RAYGUI STYLE)", 20, 8, 18, TEXT_WHITE)

  # Immediate-Mode Dialog Panel
  Citrine::UI.scope do |ui|
    ui.panel(140, 56, 360, 324, "SYSTEM CONFIGURATION")

    # Item 0: Volume Slider
    ui.label("Audio & DualShock Settings:", 160, 90, 14)
    sound_vol = ui.slider_float("SFX Volume", sound_vol, 0.0_f32, 1.0_f32, 160, 110, 200)

    # Item 1: Rumble Checkbox
    rumble_enabled = ui.checkbox("DualShock Vibration", rumble_enabled, 160, 145)

    # Item 2: Difficulty Slider
    ui.label("Gameplay Parameters:", 160, 178, 14)
    difficulty = ui.slider_int("Difficulty Tier", difficulty, 1, 5, 160, 198, 200)

    # Mana Reserve Progress Bar
    ui.label("Player Mana Reserve:", 160, 235, 14)
    ui.progress_bar(mana, 100.0_f32, 160, 255, 200, 16)

    # Item 3 & 4: Action Buttons
    if ui.button("Apply & Save", 160, 290, 140, 30)
      dialog_status = "Settings Saved Successfully!"
    end

    if ui.button("Reset Defaults", 320, 290, 140, 30)
      sound_vol = 0.5_f32
      rumble_enabled = false
      difficulty = 1
      dialog_status = "Settings Reset to Default!"
    end
  end

  # Draw Active Focus Highlight Rectangle
  case selected_element
  when 0
    Citrine.draw_rectangle(156, 106, 328, 26, FOCUS_OUTLINE)
  when 1
    Citrine.draw_rectangle(156, 141, 240, 24, FOCUS_OUTLINE)
  when 2
    Citrine.draw_rectangle(156, 194, 328, 26, FOCUS_OUTLINE)
  when 3
    Citrine.draw_rectangle(156, 286, 148, 38, FOCUS_OUTLINE)
  when 4
    Citrine.draw_rectangle(316, 286, 148, 38, FOCUS_OUTLINE)
  end

  # Footer Status Banner
  Citrine.draw_rectangle(20, 395, 600, 36, FOOTER_BG)
  Citrine.draw_text(dialog_status, 36, 404, 14, STATUS_GOLD)
  Citrine.draw_text("D-Pad Up/Down: Navigate | Left/Right: Adjust | Cross: Toggle", 220, 405, 12, STATUS_MUTED)

  Citrine.end_drawing
end

Citrine.close_window
