require "citrine"
require "citrine/inputmap"

# 02 Shapes & Text - Citrine PS2
# High-performance 2D primitive rendering showcase on Sony Graphics Synthesizer
# Demonstrates: Triangles, Quads, Lines, Circles, Rectangles, and Dynamic Profiler HUD

input_map do
  action :toggle_hud, Button::Select, port: 0
  action :cycle_accent, Button::Cross, port: 0
end

struct ShapePalette
  property primary : Int32
  property secondary : Int32
  property accent : Int32

  def initialize(@primary : Int32 = Color::Red, @secondary : Int32 = Color::Yellow, @accent : Int32 = Color::Green)
  end
end

struct ShapeRow
  property count : Int32
  property width : Int32
  property height : Int32

  def initialize(@count : Int32 = 8, @width : Int32 = 50, @height : Int32 = 36)
  end

  def draw(x_start : Int32, y_offset : Int32, color : Int32)
    i = 0
    while i < @count
      px = x_start + (i * 64)
      Citrine.draw_rectangle(px, y_offset, @width, @height, color)
      Citrine.draw_rectangle(px + 4, y_offset + 4, @width - 8, @height - 8, Color::Black)
      i += 1
    end
  end
end

Citrine.init_window(640, 448, "02 Shapes & Text - Citrine PS2")
Citrine.set_target_fps(60)

hud_enabled = true
Citrine.debug_overlay = hud_enabled

palette_idx = 0
palettes = [
  ShapePalette.new(Color::Red, Color::Yellow, Color::Green),
  ShapePalette.new(Color::Cyan, Color::Magenta, Color::White),
  ShapePalette.new(Color::Orange, Color::Purple, Color::Blue)
]

row = ShapeRow.new(8, 50, 36)
pulse = 0

Citrine.main_loop do
  pad = Citrine.player(0)
  pulse = (pulse + 1) % 60

  # Toggle diagnostic HUD with Select or Action
  if Action.is_pressed?(Actions::ToggleHud) || pad.button_pressed?(Button::Select)
    hud_enabled = !hud_enabled
    Citrine.debug_overlay = hud_enabled
  end

  if Action.is_pressed?(Actions::CycleAccent) || pad.button_pressed?(Button::Cross)
    palette_idx = (palette_idx + 1) % 3
  end

  current_pal = palettes[palette_idx]

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12_u8, 18_u8, 32_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 40, Color::Blue)
  Citrine.draw_text("CITRINE PS2: 2D GRAPHICS SYNTHESIZER DEMO", 90, 10, 18, Color::White)

  # Section 1: Geometric Primitives Card
  Citrine.draw_rectangle(30, 56, 580, 150, Color::DarkGray)
  Citrine.draw_rectangle(32, 58, 576, 146, Color::Black)
  Citrine.draw_text("GS Primitive Rasterization Pipeline:", 46, 68, 14, Color::Yellow)

  # Solid Rectangle
  Citrine.draw_rectangle(50, 96, 90, 60, current_pal.primary)
  Citrine.draw_text("RECT", 72, 164, 12, Color::White)

  # Solid Circle
  Citrine.draw_circle(210, 126, 32, current_pal.secondary)
  Citrine.draw_text("CIRCLE", 188, 164, 12, Color::White)

  # Triangle
  Citrine.draw_triangle(310, 156, 350, 96, 390, 156, current_pal.accent)
  Citrine.draw_text("TRIANGLE", 318, 164, 12, Color::White)

  # Quad (Rotated diamond/parallelogram)
  Citrine.draw_quad(450, 96, 530, 106, 550, 156, 470, 146, Color::Cyan)
  Citrine.draw_text("QUAD", 488, 164, 12, Color::White)

  # Lines
  Citrine.draw_line(46, 192, 594, 192, Color::Gray)

  # Section 2: Primitive Array / Grid Pattern
  Citrine.draw_rectangle(30, 220, 580, 130, Color::DarkGray)
  Citrine.draw_rectangle(32, 222, 576, 126, Color::Black)
  Citrine.draw_text("Array Instancing (Zero-Allocation Struct Dispatch):", 46, 230, 14, Color::Yellow)

  # Draw row of shapes via struct method
  row.draw(52, 260, current_pal.secondary)

  # Dynamic Pulsing Accent Indicator
  pulse_w = 20 + (pulse // 3)
  Citrine.draw_rectangle(52, 312, pulse_w * 8, 12, current_pal.accent)

  # Section 3: Interactive Controls Footer
  Citrine.draw_rectangle(30, 365, 580, 60, Color::DarkGray)
  Citrine.draw_rectangle(32, 367, 576, 56, Color::Black)
  Citrine.draw_text("CROSS: Cycle Color Palette | SELECT: Toggle Diagnostic Overlay", 50, 378, 13, Color::White)
  Citrine.draw_text("Target: GS 48 GB/s eDRAM | Native 640x448 Framebuffer", 50, 400, 13, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
