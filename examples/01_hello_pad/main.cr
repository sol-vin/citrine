require "../../src/stubs/citrine"

Citrine.init_window(640, 448, "01 Hello Pad - Citrine PS2")
Citrine.set_target_fps(60)

pos = Vector2.new(320.0, 224.0)
speed = 4.0

Citrine.main_loop do
  # DualShock 2 D-Pad & Analog Stick Input
  if Citrine.button_down?(Button::Right)
    pos.x += speed
  elsif Citrine.button_down?(Button::Left)
    pos.x -= speed
  end

  if Citrine.button_down?(Button::Down)
    pos.y += speed
  elsif Citrine.button_down?(Button::Up)
    pos.y -= speed
  end

  # Screen boundaries (640x448)
  if pos.x < 20.0
    pos.x = 20.0
  elsif pos.x > 580.0
    pos.x = 580.0
  end

  if pos.y < 20.0
    pos.y = 20.0
  elsif pos.y > 380.0
    pos.y = 380.0
  end

  # Rendering
  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  Citrine.draw_rectangle(pos.x, pos.y, 40, 40, Color::Red)
  Citrine.draw_circle(pos.x + 20.0, pos.y + 20.0, 10.0, Color::Yellow)
  Citrine.draw_text("DualShock 2 Pad Demo: Use D-Pad to move", 30, 30, 16, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
