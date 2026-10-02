require "citrine"

Citrine.init_window(640, 448, "05 Hello World - Citrine PS2")
Citrine.set_target_fps(60)

Citrine.main_loop do
  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Title card border and background
  Citrine.draw_rectangle(40, 40, 560, 368, Color::Blue)
  Citrine.draw_rectangle(44, 44, 552, 360, Color::Black)

  # Text header & subheader
  Citrine.draw_text("CITRINE PS2 TOOLKIT", 180, 80, 24, Color::Yellow)
  Citrine.draw_text("Crystal Virtual Machine for Sony PlayStation 2", 110, 120, 16, Color::White)

  # Centered Hello World banner
  Citrine.draw_rectangle(120, 180, 400, 70, Color::Red)
  Citrine.draw_text("HELLO PLAYSTATION 2!", 150, 205, 20, Color::White)

  # Hardware stats & instructions
  Citrine.draw_text("Target: Sony Emotion Engine (R5900 @ 294MHz)", 110, 280, 14, Color::Green)
  Citrine.draw_text("Renderer: Graphic Synthesizer (GS 4MB eDRAM @ 147MHz)", 110, 305, 14, Color::Green)
  Citrine.draw_text("Memory: 32MB Main RAM | 16KB Scratchpad RAM (SPRAM)", 110, 330, 14, Color::Green)
  Citrine.draw_text("Press START to proceed", 230, 370, 14, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
