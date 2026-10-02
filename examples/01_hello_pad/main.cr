require "citrine"

# 01 Hello Pad - Citrine PS2
# Interactive DualShock 2 Button Demo: Press Cross (X) to cycle background color
# Sequence: Black -> Red -> Blue -> Green -> Black

class ColorCycleApp
  property color_index : Int32
  property press_count : Int32

  def initialize
    @color_index = 0
    @press_count = 0
  end

  def next_color
    @color_index = @color_index + 1
    if @color_index > 3
      @color_index = 0
    end
    @press_count = @press_count + 1
  end
end

Citrine.init_window(640, 448, "01 Hello Pad - Citrine PS2")
Citrine.set_target_fps(60)

puts "Hello, world! sol.vin here!"
puts "1234567890ABCDEF"
debug_puts "[CITRINE DEBUG] Hello World booted on PlayStation 2 EE!"

app = ColorCycleApp.new
colors = [Color::Black, Color::Red, Color::Blue, Color::Green]

Citrine.main_loop do
  if Citrine.button_pressed?(Button::Cross)
    app.next_color
    debug_puts "[CITRINE] Button Cross (X) pressed! Background cycled."
  end

  Citrine.begin_drawing
  Citrine.clear_background(colors[app.color_index])

  # Title Header Box
  Citrine.draw_rectangle(40, 30, 560, 70, Color::Blue)
  Citrine.draw_text("HELLO PLAYSTATION 2!", 160, 52, 22, Color::Yellow)

  # Central Status Display
  Citrine.draw_rectangle(40, 120, 560, 240, Color::Black)
  Citrine.draw_text("Press CROSS (X) on DualShock 2 to cycle background:", 60, 140, 16, Color::White)
  Citrine.draw_text("Black -> Red -> Blue -> Green -> Black", 120, 175, 18, Color::Yellow)

  Citrine.draw_rectangle(220, 220, 200, 50, colors[app.color_index])
  if app.color_index == 0
    Citrine.draw_text("CURRENT: BLACK", 235, 235, 18, Color::White)
  elsif app.color_index == 1
    Citrine.draw_text("CURRENT: RED", 250, 235, 18, Color::White)
  elsif app.color_index == 2
    Citrine.draw_text("CURRENT: BLUE", 245, 235, 18, Color::White)
  else
    Citrine.draw_text("CURRENT: GREEN", 240, 235, 18, Color::White)
  end

  Citrine.draw_text("Hardware Target: Emotion Engine R5900 | Graphic Synthesizer", 60, 320, 14, Color::Green)

  Citrine.end_drawing
end

Citrine.close_window
