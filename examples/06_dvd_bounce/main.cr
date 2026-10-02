require "../../src/stubs/citrine"

Citrine.init_window(640, 448, "06 DVD Bounce - Citrine PS2")
Citrine.set_target_fps(60)

# DVD logo state
pos = Vector2.new(100.0, 100.0)
vel = Vector2.new(3.0, 2.0)
logo_w = 130.0
logo_h = 60.0
bounces = 0
color_idx = 0

Citrine.main_loop do
  # Update position
  pos.x += vel.x
  pos.y += vel.y

  hit = false

  # Horizontal bounce
  if pos.x <= 10.0
    pos.x = 10.0
    vel.x = -vel.x
    hit = true
  elsif pos.x + logo_w >= 630.0
    pos.x = 630.0 - logo_w
    vel.x = -vel.x
    hit = true
  end

  # Vertical bounce
  if pos.y <= 10.0
    pos.y = 10.0
    vel.y = -vel.y
    hit = true
  elsif pos.y + logo_h >= 438.0
    pos.y = 438.0 - logo_h
    vel.y = -vel.y
    hit = true
  end

  if hit
    bounces += 1
    color_idx = (color_idx + 1) % 4
  end

  # Controller input to speed up / slow down
  if Citrine.button_pressed?(Button::Up)
    vel.x = vel.x * 1.2
    vel.y = vel.y * 1.2
  elsif Citrine.button_pressed?(Button::Down)
    vel.x = vel.x * 0.8
    vel.y = vel.y * 0.8
  end

  # Rendering
  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Determine current color based on color_idx
  current_color = Color::White
  if color_idx == 1
    current_color = Color::Red
  elsif color_idx == 2
    current_color = Color::Green
  elsif color_idx == 3
    current_color = Color::Yellow
  end

  # Draw logo shadow
  Citrine.draw_rectangle(pos.x + 4.0, pos.y + 4.0, logo_w, logo_h, Color::Gray)

  # Draw main logo body
  Citrine.draw_rectangle(pos.x, pos.y, logo_w, logo_h, current_color)
  Citrine.draw_rectangle(pos.x + 4.0, pos.y + 4.0, logo_w - 8.0, logo_h - 8.0, Color::Black)

  # Draw DVD text inside body
  Citrine.draw_text("DVD", pos.x + 36.0, pos.y + 12.0, 22, current_color)
  Citrine.draw_text("VIDEO", pos.x + 32.0, pos.y + 36.0, 14, current_color)

  # Screen status overlay
  Citrine.draw_text("DVD Bouncing Screensaver - Citrine PS2", 20, 20, 14, Color::Gray)
  Citrine.draw_text("Bounces:", 20, 40, 14, Color::Gray)
  Citrine.draw_rectangle(85, 42, bounces * 2, 10, Color::Yellow)
  Citrine.draw_text("D-Pad Up/Down: Adjust Speed", 20, 415, 12, Color::Gray)

  Citrine.end_drawing
end

Citrine.close_window
