require "citrine"

class ShapeRow
  property count : Int32
  property color : Int32

  def initialize(@count, @color)
  end

  def draw(y_offset)
    i = 0
    while i < @count
      Citrine.draw_rectangle(60 + (i * 65), y_offset, 50, 40, @color)
      i = i + 1
    end
  end
end

Citrine.init_window(640, 448, "02 Shapes & Text - Citrine PS2")
Citrine.set_target_fps(60)

hud_enabled = true
Citrine.debug_overlay = hud_enabled

row = ShapeRow.new(8, Color::White)
shapes = [Color::Red, Color::Yellow, Color::Green]

Citrine.main_loop do
  # Toggle diagnostic HUD with Select
  if Citrine.button_pressed?(Button::Select)
    hud_enabled = !hud_enabled
    Citrine.debug_overlay = hud_enabled
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Blue)

  # Draw 2D primitives using array-indexed palette
  Citrine.draw_rectangle(60, 100, 120, 80, shapes[0])
  Citrine.draw_circle(300, 140, 40, shapes[1])
  Citrine.draw_line(420, 100, 560, 180, shapes[2])

  # Draw row of shapes via class method
  row.draw(240)

  Citrine.draw_text("Press SELECT on DualShock 2 to toggle Profiler HUD", 40, 360, 14, Color::Yellow)
  Citrine.draw_text("Citrine PS2 2D Drawing Demo", 40, 390, 16, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
