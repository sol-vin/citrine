require "citrine"

Citrine.init_window(640, 448, "04 Safety & Panic - Citrine PS2")
Citrine.set_target_fps(60)

frames = 0

Citrine.main_loop do
  frames += 1

  # Trigger panic after 180 frames or when pressing Cross button
  if Citrine.button_pressed?(Button::Cross) || frames > 180
    Citrine.panic("Demonstrating Citrine On-Screen PS2 Crash Handler")
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  Citrine.draw_rectangle(120, 150, 400, 140, Color::Red)
  Citrine.draw_text("Safety & Hardware Crash Handler Test", 140, 180, 16, Color::White)
  Citrine.draw_text("Press CROSS on DualShock 2 or wait 3s...", 140, 210, 14, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
