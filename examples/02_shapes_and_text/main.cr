require "../../src/stubs/citrine"

Citrine.init_window(640, 448, "02 Shapes & Text - Citrine PS2")
Citrine.set_target_fps(60)

hud_enabled = true
Citrine.debug_overlay = hud_enabled

angle = 0.0

Citrine.main_loop do
  # Toggle diagnostic HUD with Select
  if Citrine.button_pressed?(Button::Select)
    hud_enabled = !hud_enabled
    Citrine.debug_overlay = hud_enabled
  end

  angle += 1.0

  Citrine.begin_drawing
  Citrine.clear_background(Color::Blue)

  # Draw 2D primitives
  Citrine.draw_rectangle(60, 100, 120, 80, Color::Red)
  Citrine.draw_circle(300, 140, 40, Color::Yellow)
  Citrine.draw_line(420, 100, 560, 180, Color::Green)

  # Draw loop of shapes
  8.times do |i|
    Citrine.draw_rectangle(60 + (i * 65), 240, 50, 40, Color::White)
  end

  Citrine.draw_text("Press SELECT on DualShock 2 to toggle Profiler HUD", 40, 360, 14, Color::Yellow)
  Citrine.draw_text("Citrine PS2 2D Drawing Demo", 40, 390, 16, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
