# Citrine PS2 Example 12: Immediate-Mode UI & DualShock 2 Navigation
# Demonstrates require "citrine/ui", panel, button, slider_float, slider_int, checkbox, progress_bar

require "citrine"
require "citrine/ui"

Citrine.init_window(640, 448, "Citrine PS2 - Immediate-Mode UI")
Citrine.set_target_fps(60)

sound_vol = 0.8_f32
rumble_enabled = true
difficulty = 2
mana = 75.0_f32
dialog_status = "Status: READY"

Citrine.main_loop do
  # UI Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(20_u8, 24_u8, 35_u8, 255_u8))

  # Background retro grid pattern
  Citrine.draw_rectangle(0, 0, 640, 32, Color.new(30_u8, 38_u8, 55_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: IMMEDIATE-MODE UI (RAYGUI STYLE)", 20, 8, 18, Color.new(240_u8, 245_u8, 255_u8, 255_u8))

  # Immediate-Mode Dialog Panel
  Citrine::UI.scope do |ui|
    ui.panel(140, 60, 360, 320, "SYSTEM CONFIGURATION")

    ui.label("Audio & DualShock Settings:", 160, 96, 14)
    sound_vol = ui.slider_float("SFX Volume", sound_vol, 0.0_f32, 1.0_f32, 160, 116, 200)

    rumble_enabled = ui.checkbox("DualShock Vibration", rumble_enabled, 160, 150)

    ui.label("Gameplay Parameters:", 160, 180, 14)
    difficulty = ui.slider_int("Difficulty Tier", difficulty, 1, 5, 160, 200, 200)

    ui.label("Player Mana Reserve:", 160, 235, 14)
    ui.progress_bar(mana, 100.0_f32, 160, 255, 200, 16)

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

  # Footer Banner
  Citrine.draw_rectangle(20, 395, 600, 32, Color.new(25_u8, 32_u8, 45_u8, 240_u8))
  Citrine.draw_text(dialog_status, 36, 403, 14, Color.new(255_u8, 215_u8, 0_u8, 255_u8))
  Citrine.draw_text("D-Pad: Navigate | Cross: Select/Toggle", 320, 403, 13, Color.new(170_u8, 180_u8, 200_u8, 255_u8))

  Citrine.end_drawing
end

Citrine.close_window
