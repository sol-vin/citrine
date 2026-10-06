# Citrine PS2 Example 14: Processing-Style Creative Coding & 2D Graphics DSL
# Demonstrates require "citrine/draw2d", affine matrix stack, rotated primitives & text,
# rounded rectangles, star polygons, and zero-allocation frame batching on the Sony GS.

require "citrine"
require "citrine/draw2d"
require "citrine/time"
require "citrine/math"

Citrine.init_window(640, 448, "Citrine PS2 - 2D Graphics DSL & Creative Coding")
Citrine.set_target_fps(60)

# Pre-allocated color constants (0 heap allocations in main loop)
BG_COLOR       = Color.new(12_u8, 14_u8, 20_u8, 255_u8)
BANNER_BG      = Color.new(22_u8, 26_u8, 38_u8, 255_u8)
COLOR_BORDER   = Color.new(45_u8, 55_u8, 75_u8, 255_u8)
TEXT_WHITE     = Color.new(245_u8, 245_u8, 255_u8, 255_u8)
STROKE_BLUE    = Color.new(41_u8, 128_u8, 185_u8, 255_u8)
FILL_BLUE_A    = Color.new(52_u8, 152_u8, 219_u8, 120_u8)
FILL_RED_A     = Color.new(231_u8, 76_u8, 60_u8, 160_u8)
FILL_YELLOW_A  = Color.new(241_u8, 196_u8, 15_u8, 200_u8)
SATELLITE_A    = Color.new(46_u8, 204_u8, 113_u8, 255_u8)
SATELLITE_B    = Color.new(155_u8, 89_u8, 182_u8, 255_u8)

angle = 0.0_f32

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

  # Render Pass via Scoped Citrine.draw_2d DSL
  Citrine.draw_2d do |d|
    d.clear(BG_COLOR)

    # 1. Header Card with rounded corners
    d.card(0, 0, 640, 36, radius: 0.0, fill: BANNER_BG, stroke: COLOR_BORDER) do
      d.text("CITRINE PS2: 2D GRAPHICS DSL & ROTATED PRIMITIVES", 20, 10, size: 18, color: TEXT_WHITE)
    end

    # 2. Concentric Geometric Mandala with Scoped Matrix Transformation
    d.transform(x: 320, y: 224, rotation: angle, origin: Vector2.new(0, 0)) do
      # Outer rounded rotating square
      d.rect(-60, -60, 120, 120, radius: 14.0, fill: FILL_BLUE_A, stroke: STROKE_BLUE, weight: 2.0)
      # Inner pulsating circle
      d.circle(0, 0, 42, fill: FILL_RED_A)
      # Diamond square
      d.rect(-20, -20, 40, 40, fill: FILL_YELLOW_A, stroke: Color::White)
      # Central 6-pointed star
      d.star(0, 0, points: 6, inner_r: 8, outer_r: 24, fill: Color::Yellow)
    end

    # 3. Dynamic Rotated Text Orbiting the Center
    d.text("ROTATED TEXT DSL", 320, 224, size: 14, color: Color::Yellow, rotation: -angle * 1.5_f32, origin: Vector2.new(70, 7), align: :center)

    # 4. Orbital Satellite Primitives
    rad = Citrine::Math.deg2rad(angle)
    orbit_x1 = 320 + (Citrine::Math.cos(rad) * 160.0_f32).to_i32
    orbit_y1 = 224 + (Citrine::Math.sin(rad) * 100.0_f32).to_i32

    orbit_x2 = 320 + (Citrine::Math.cos(rad + PI) * 160.0_f32).to_i32
    orbit_y2 = 224 + (Citrine::Math.sin(rad + PI) * 100.0_f32).to_i32

    d.circle(orbit_x1, orbit_y1, 10, fill: SATELLITE_A)
    d.circle(orbit_x2, orbit_y2, 10, fill: SATELLITE_B)

    # Orbital Ring Lines
    d.line(orbit_x1, orbit_y1, 320, 224, color: Color::DarkGray)
    d.line(orbit_x2, orbit_y2, 320, 224, color: Color::DarkGray)

    # 5. Telemetry Footer with Card Container
    d.card(20, 395, 600, 38, radius: 6.0, fill: BANNER_BG, stroke: COLOR_BORDER) do
      d.text("Draw2D: transform(rot: #{angle.to_i32} deg) | Card & Star Primitives", 15, 12, size: 12, color: Color::Yellow)
      d.text("D-Pad Left/Right: Adjust Speed", 360, 12, size: 12, color: Color::White)
    end
  end
end

Citrine.close_window
