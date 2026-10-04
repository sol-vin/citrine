require "citrine"
require "citrine/inputmap"

# 06 DVD Bounce - Citrine PS2
# Authentic DVD-Video bouncing screensaver with corner-hit detection and velocity controls
# Demonstrates: Accurate boundary collisions, visual particle effects, and 60 FPS GS rendering

input_map do
  action :speed_up, Button::Up, port: 0
  action :slow_down, Button::Down, port: 0
  action :toggle_trail, Button::Cross, port: 0
end

Citrine.init_window(640, 448, "06 DVD Bounce - Citrine PS2")
Citrine.set_target_fps(60)

pos_x = 120.0_f32
pos_y = 100.0_f32
vel_x = 3.2_f32
vel_y = 2.4_f32
logo_w = 140.0_f32
logo_h = 64.0_f32

bounces = 0
corner_hits = 0
color_idx = 0
corner_flash = 0
show_trail = true

colors = [
  Color::White,
  Color::Cyan,
  Color::Yellow,
  Color::Magenta,
  Color::Green,
  Color::Orange
]

Citrine.main_loop do
  pad = Citrine.player(0)

  # Interactive Speed Adjustments
  if Action.is_pressed?(Actions::SpeedUp) || pad.button_pressed?(Button::Up)
    vel_x = (vel_x * 1.15_f32).clamp(-12.0_f32, 12.0_f32)
    vel_y = (vel_y * 1.15_f32).clamp(-10.0_f32, 10.0_f32)
  elsif Action.is_pressed?(Actions::SlowDown) || pad.button_pressed?(Button::Down)
    vel_x = (vel_x * 0.85_f32)
    vel_y = (vel_y * 0.85_f32)
  end

  if Action.is_pressed?(Actions::ToggleTrail) || pad.button_pressed?(Button::Cross)
    show_trail = !show_trail
  end

  # Position Integration
  pos_x += vel_x
  pos_y += vel_y

  hit_x = false
  hit_y = false

  # Left & Right Boundaries (Screen: 640x448, playable region: 12..628)
  if pos_x <= 12.0_f32
    pos_x = 12.0_f32
    vel_x = -vel_x
    hit_x = true
  elsif pos_x + logo_w >= 628.0_f32
    pos_x = 628.0_f32 - logo_w
    vel_x = -vel_x
    hit_x = true
  end

  # Top & Bottom Boundaries (Playable region: 12..436)
  if pos_y <= 12.0_f32
    pos_y = 12.0_f32
    vel_y = -vel_y
    hit_y = true
  elsif pos_y + logo_h >= 436.0_f32
    pos_y = 436.0_f32 - logo_h
    vel_y = -vel_y
    hit_y = true
  end

  if hit_x || hit_y
    bounces += 1
    color_idx = (color_idx + 1) % 6
    if hit_x && hit_y
      corner_hits += 1
      corner_flash = 30 # Flash gold border for 30 frames
    end
  end

  if corner_flash > 0
    corner_flash -= 1
  end

  current_color = colors[color_idx]

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Screen CRT Frame Border
  border_col = corner_flash > 0 ? Color::Yellow : Color::DarkGray
  Citrine.draw_rectangle(0, 0, 640, 8, border_col)
  Citrine.draw_rectangle(0, 440, 640, 8, border_col)
  Citrine.draw_rectangle(0, 0, 8, 448, border_col)
  Citrine.draw_rectangle(632, 0, 8, 448, border_col)

  # Motion Trail
  if show_trail
    trail_x = pos_x - (vel_x * 1.5_f32)
    trail_y = pos_y - (vel_y * 1.5_f32)
    Citrine.draw_rectangle(trail_x.to_i32, trail_y.to_i32, logo_w.to_i32, logo_h.to_i32, Color::DarkGray)
  end

  # Logo Drop Shadow
  Citrine.draw_rectangle((pos_x + 5.0_f32).to_i32, (pos_y + 5.0_f32).to_i32, logo_w.to_i32, logo_h.to_i32, Color.new(20_u8, 20_u8, 20_u8, 255_u8))

  # Main Logo Chassis
  ix = pos_x.to_i32
  iy = pos_y.to_i32
  Citrine.draw_rectangle(ix, iy, logo_w.to_i32, logo_h.to_i32, current_color)
  Citrine.draw_rectangle(ix + 3, iy + 3, logo_w.to_i32 - 6, logo_h.to_i32 - 6, Color::Black)
  Citrine.draw_rectangle(ix + 5, iy + 5, logo_w.to_i32 - 10, logo_h.to_i32 - 10, current_color)
  Citrine.draw_rectangle(ix + 7, iy + 7, logo_w.to_i32 - 14, logo_h.to_i32 - 14, Color::Black)

  # Optical Disc Icon Geometry
  Citrine.draw_circle(ix + 28, iy + 32, 14.0_f32, current_color)
  Citrine.draw_circle(ix + 28, iy + 32, 4.0_f32, Color::Black)

  # DVD VIDEO Typography
  Citrine.draw_text("DVD", ix + 52, iy + 14, 20, current_color)
  Citrine.draw_text("VIDEO", ix + 52, iy + 36, 13, current_color)

  # Telemetry HUD
  Citrine.draw_text("BOUNCES: #{bounces}  |  CORNER HITS: #{corner_hits}", 24, 18, 13, Color::Yellow)
  Citrine.draw_text("D-Pad Up/Down: Velocity (#{vel_x.abs.to_i32} px/f) | Cross: Toggle Trail", 24, 420, 12, Color::Gray)

  Citrine.end_drawing
end

Citrine.close_window
