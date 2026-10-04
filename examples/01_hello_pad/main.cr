require "citrine"
require "citrine/inputmap"

# 01 Hello Pad - Citrine PS2
# Interactive DualShock 2 Button Demo: Cycle background and monitor pad telemetry
# Demonstrates: InputMap Actions, zero-allocation structs, and GS 2D rendering

input_map do
  action :cycle_color, Button::Cross, port: 0
  action :cycle_prev, Button::Square, port: 0
  action :reset, Button::Triangle, port: 0
end

struct ColorCycleState
  property index : Int32
  property press_count : Int32

  def initialize(@index : Int32 = 0, @press_count : Int32 = 0)
  end

  def next_color
    @index = (@index + 1) % 5
    @press_count += 1
  end

  def prev_color
    @index = (@index + 4) % 5
    @press_count += 1
  end

  def reset
    @index = 0
    @press_count = 0
  end
end

Citrine.init_window(640, 448, "01 Hello Pad - Citrine PS2")
Citrine.set_target_fps(60)

state = ColorCycleState.new(0, 0)
colors = [Color::Black, Color::Red, Color::Blue, Color::Green, Color::Purple]

Citrine.main_loop do
  pad = Citrine.player(0)

  if Action.is_pressed?(Actions::CycleColor) || pad.button_pressed?(Button::Cross)
    state.next_color
  elsif Action.is_pressed?(Actions::CyclePrev) || pad.button_pressed?(Button::Square)
    state.prev_color
  elsif Action.is_pressed?(Actions::Reset) || pad.button_pressed?(Button::Triangle)
    state.reset
  end

  Citrine.begin_drawing
  Citrine.clear_background(colors[state.index])

  # --- Outer Decorative Frame & Shadow ---
  Citrine.draw_rectangle(20, 16, 600, 416, Color::DarkGray)
  Citrine.draw_rectangle(24, 20, 592, 408, Color::Black)

  # --- Title Header Bar ---
  Citrine.draw_rectangle(24, 20, 592, 48, Color::Blue)
  Citrine.draw_text("CITRINE PS2: DUALSHOCK 2 CONTROLLER", 110, 32, 20, Color::White)

  # --- Central Diagnostic Display Card ---
  Citrine.draw_rectangle(50, 85, 540, 245, Color::Gray)
  Citrine.draw_rectangle(54, 89, 532, 237, Color::Black)

  Citrine.draw_text("Interactive DualShock 2 Button Mapping", 70, 105, 16, Color::Yellow)
  Citrine.draw_text("Press CROSS (X)  -> Cycle Forward", 90, 135, 14, Color::White)
  Citrine.draw_text("Press SQUARE ([]) -> Cycle Backward", 90, 160, 14, Color::White)
  Citrine.draw_text("Press TRIANGLE   -> Reset Palette", 90, 185, 14, Color::White)

  # Active Color Swatch Display
  Citrine.draw_rectangle(170, 220, 300, 46, Color::White)
  Citrine.draw_rectangle(172, 222, 296, 42, colors[state.index])

  if state.index == 0
    Citrine.draw_text("PALETTE: 0 / BLACK", 230, 234, 16, Color::White)
  elsif state.index == 1
    Citrine.draw_text("PALETTE: 1 / RED", 242, 234, 16, Color::White)
  elsif state.index == 2
    Citrine.draw_text("PALETTE: 2 / BLUE", 238, 234, 16, Color::White)
  elsif state.index == 3
    Citrine.draw_text("PALETTE: 3 / GREEN", 232, 234, 16, Color::White)
  else
    Citrine.draw_text("PALETTE: 4 / PURPLE", 228, 234, 16, Color::White)
  end

  # Press Counter Bar
  Citrine.draw_text("Total Button Transitions: #{state.press_count}", 70, 290, 14, Color::Yellow)

  # --- Footer Hardware Telemetry Bar ---
  Citrine.draw_rectangle(24, 385, 592, 43, Color::DarkGray)
  Citrine.draw_text("EE MIPS R5900 @ 294.9 MHz | GS 4MB eDRAM | DualShock 2 Port 0", 65, 399, 13, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
