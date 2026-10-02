require "citrine"

# 01 Hello Pad - Citrine PS2
# Interactive DualShock 2 Button Demo: Press Cross (X) to cycle background color
# Sequence: Black -> Red -> Blue -> Green -> Black

Citrine.init_window(640, 448, "01 Hello Pad - Citrine PS2")
Citrine.set_target_fps(60)

puts "Hello, world! sol.vin here!"
puts "1234567890ABCDEF"
debug_puts "[CITRINE DEBUG] Hello World booted on PlayStation 2 EE!"

bg_color = 0

Citrine.main_loop do
  if Citrine.button_pressed?(Button::Cross)
    bg_color = bg_color + 1
    if bg_color > 3
      bg_color = 0
    end
    debug_puts "[CITRINE] Button Cross (X) pressed! Background cycled."
  end

  Citrine.begin_drawing

  if bg_color == 0
    Citrine.clear_background(Color::Black)
  elsif bg_color == 1
    Citrine.clear_background(Color::Red)
  elsif bg_color == 2
    Citrine.clear_background(Color::Blue)
  else
    Citrine.clear_background(Color::Green)
  end

  # Title Header Box
  Citrine.draw_rectangle(40, 30, 560, 70, Color::Blue)
  Citrine.draw_text("HELLO PLAYSTATION 2!", 160, 52, 22, Color::Yellow)

  # Central Status Display
  Citrine.draw_rectangle(40, 120, 560, 240, Color::Black)
  Citrine.draw_text("Press CROSS (X) on DualShock 2 to cycle background:", 60, 140, 16, Color::White)
  Citrine.draw_text("Black -> Red -> Blue -> Green -> Black", 120, 175, 18, Color::Yellow)

  if bg_color == 0
    Citrine.draw_rectangle(220, 220, 200, 50, Color::Black)
    Citrine.draw_text("CURRENT: BLACK", 235, 235, 18, Color::White)
  elsif bg_color == 1
    Citrine.draw_rectangle(220, 220, 200, 50, Color::Red)
    Citrine.draw_text("CURRENT: RED", 250, 235, 18, Color::White)
  elsif bg_color == 2
    Citrine.draw_rectangle(220, 220, 200, 50, Color::Blue)
    Citrine.draw_text("CURRENT: BLUE", 245, 235, 18, Color::White)
  else
    Citrine.draw_rectangle(220, 220, 200, 50, Color::Green)
    Citrine.draw_text("CURRENT: GREEN", 240, 235, 18, Color::White)
  end

  Citrine.draw_text("Hardware Target: Emotion Engine R5900 | Graphic Synthesizer", 60, 320, 14, Color::Green)

  Citrine.end_drawing
end

Citrine.close_window
