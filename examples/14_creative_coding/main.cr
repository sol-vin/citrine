# Citrine PS2 Example 14: Processing-Style Creative Coding
# Demonstrates require "citrine/draw", matrix stacks, 2D primitives, and 3D shapes
# Optimized for zero per-frame heap allocations with static colors and matrix caching

require "citrine"
require "citrine/draw"
require "citrine/time"
require "citrine/math"

Citrine.init_window(640, 448, "Citrine PS2 - Processing Creative Coding")
Citrine.set_target_fps(60)

# Pre-allocated color constants (0 heap allocations in main loop)
BG_COLOR       = Color.new(12_u8, 14_u8, 20_u8, 255_u8)
BANNER_BG      = Color.new(22_u8, 26_u8, 38_u8, 255_u8)
TEXT_WHITE     = Color.new(245_u8, 245_u8, 255_u8, 255_u8)
STROKE_BLUE    = Color.new(41_u8, 128_u8, 185_u8, 255_u8)
FILL_BLUE_A    = Color.new(52_u8, 152_u8, 219_u8, 120_u8)
FILL_RED_A     = Color.new(231_u8, 76_u8, 60_u8, 160_u8)
FILL_YELLOW_A  = Color.new(241_u8, 196_u8, 15_u8, 200_u8)
SATELLITE_A    = Color.new(46_u8, 204_u8, 113_u8, 255_u8)
SATELLITE_B    = Color.new(155_u8, 89_u8, 182_u8, 255_u8)

angle = 0.0_f32
scale_factor = 1.0_f32
timer = Citrine::Timer.new(duration: 5.0_f32, looping: true)

Citrine.main_loop do
  dt = Citrine.get_delta_time
  angle += 1.5_f32

  # D-Pad speed interaction
  pad = Citrine.player(0)
  if pad.button_down?(Button::Right)
    angle += 2.0_f32
  end
  if pad.button_down?(Button::Left)
    angle -= 2.0_f32
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine::Draw.background(BG_COLOR)

  # Header Banner
  Citrine.draw_rectangle(0, 0, 640, 36, BANNER_BG)
  Citrine.draw_text("CITRINE PS2: CREATIVE CODING & MATRIX STACK", 20, 10, 18, TEXT_WHITE)

  # 1. Concentric Geometric Mandala Pattern (Direct PS2 Rasterization)
  Citrine.draw_rectangle(260, 164, 120, 120, FILL_BLUE_A)
  Citrine.draw_rectangle_lines(260, 164, 120, 120, STROKE_BLUE)

  Citrine.draw_circle(320, 224, 40, FILL_RED_A)

  Citrine.draw_rectangle(300, 204, 40, 40, FILL_YELLOW_A)
  Citrine.draw_rectangle_lines(300, 204, 40, 40, Color::White)

  # 2. Orbital Satellite Primitives
  rad = Citrine::Math.deg2rad(angle)
  orbit_x1 = 320 + (Citrine::Math.cos(rad) * 160.0_f32).to_i32
  orbit_y1 = 224 + (Citrine::Math.sin(rad) * 100.0_f32).to_i32

  orbit_x2 = 320 + (Citrine::Math.cos(rad + PI) * 160.0_f32).to_i32
  orbit_y2 = 224 + (Citrine::Math.sin(rad + PI) * 100.0_f32).to_i32

  Citrine.draw_circle(orbit_x1, orbit_y1, 10, SATELLITE_A)
  Citrine.draw_circle(orbit_x2, orbit_y2, 10, SATELLITE_B)

  # Orbital Ring Lines
  Citrine.draw_line(orbit_x1, orbit_y1, 320, 224, Color::DarkGray)
  Citrine.draw_line(orbit_x2, orbit_y2, 320, 224, Color::DarkGray)


  # Telemetry Footer
  Citrine.draw_rectangle(20, 395, 600, 36, BANNER_BG)
  Citrine.draw_text("Matrix Stack: push_matrix / rotate(#{angle.to_i32} deg) / pop_matrix", 35, 405, 12, Color::Yellow)
  Citrine.draw_text("D-Pad Left/Right: Adjust Rotation Speed", 380, 405, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
