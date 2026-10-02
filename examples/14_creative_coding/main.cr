# Citrine PS2 Example 14: Processing-Style Creative Coding
# Demonstrates require "citrine/draw", matrix stacks, 2D primitives, and 3D shapes

require "citrine"
require "citrine/draw"
require "citrine/time"
require "citrine/math"

Citrine.init_window(640, 448, "Citrine PS2 - Processing Creative Coding")
Citrine.set_target_fps(60)

angle = 0.0_f32
scale_factor = 1.0_f32
timer = Citrine::Timer.new(duration: 5.0_f32, looping: true)

Citrine.main_loop do
  dt = Citrine.get_delta_time
  angle += 1.5_f32

  # D-Pad interaction
  if Citrine.button_down?(Button::Right)
    angle += 2.0_f32
  end
  if Citrine.button_down?(Button::Left)
    angle -= 2.0_f32
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine::Draw.background(Color.new(12_u8, 14_u8, 20_u8, 255_u8))

  # Header Banner
  Citrine.draw_rectangle(0, 0, 640, 36, Color.new(22_u8, 26_u8, 38_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: CREATIVE CODING & MATRIX STACK", 20, 10, 18, Color.new(245_u8, 245_u8, 255_u8, 255_u8))

  # 1. Processing-Style 2D Shapes with Matrix Transformations
  Citrine::Draw.push_matrix
  Citrine::Draw.translate(320.0_f32, 224.0_f32)
  Citrine::Draw.rotate(angle)

  # Draw concentric geometric pattern
  Citrine::Draw.stroke(Color.new(41_u8, 128_u8, 185_u8, 255_u8))
  Citrine::Draw.stroke_weight(2.0_f32)
  Citrine::Draw.fill(Color.new(52_u8, 152_u8, 219_u8, 120_u8))
  Citrine::Draw.rect(-60.0_f32, -60.0_f32, 120.0_f32, 120.0_f32)

  Citrine::Draw.fill(Color.new(231_u8, 76_u8, 60_u8, 160_u8))
  Citrine::Draw.ellipse(0.0_f32, 0.0_f32, 80.0_f32, 80.0_f32)

  Citrine::Draw.fill(Color.new(241_u8, 196_u8, 15_u8, 200_u8))
  Citrine::Draw.rect(-20.0_f32, -20.0_f32, 40.0_f32, 40.0_f32)

  Citrine::Draw.pop_matrix

  # 2. Orbital Satellite Primitives
  rad = Citrine::Math.deg2rad(angle)
  orbit_x = 320.0_f32 + Citrine::Math.cos(rad) * 160.0_f32
  orbit_y = 224.0_f32 + Citrine::Math.sin(rad) * 100.0_f32

  Citrine::Draw.fill(Color.new(46_u8, 204_u8, 113_u8, 255_u8))
  Citrine::Draw.circle(orbit_x, orbit_y, 14.0_f32)
  Citrine::Draw.line(320.0_f32, 224.0_f32, orbit_x, orbit_y)

  # Telemetry Footer
  Citrine.draw_rectangle(20, 396, 600, 36, Color.new(22_u8, 26_u8, 38_u8, 240_u8))
  Citrine.draw_text("Matrix Stack: 2 Transforms | Orbital Radians: Active", 36, 406, 14, Color.new(255_u8, 255_u8, 255_u8, 255_u8))
  Citrine.draw_text("D-Pad Left/Right: Spin", 420, 406, 14, Color.new(160_u8, 175_u8, 200_u8, 255_u8))

  Citrine.end_drawing
end

Citrine.close_window
