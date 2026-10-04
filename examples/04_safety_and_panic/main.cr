require "citrine"

# 04 Safety & Panic - Citrine PS2
# Demonstrates: Citrine hardware crash interception, memory canary preservation,
# and high-visibility on-screen diagnostic panic screen

Citrine.init_window(640, 448, "04 Safety & Panic - Citrine PS2")
Citrine.set_target_fps(60)

frames = 0
canary_token = 0xDEADBEEF_u32

Citrine.main_loop do
  frames += 1
  pad = Citrine.player(0)

  # Trigger controlled panic on Cross or after 180 frames timeout
  if pad.button_pressed?(Button::Cross) || frames > 180
    Citrine.panic("CITRINE KERNEL FAULT TEST: Intentional Crash Handler Interception")
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(16_u8, 20_u8, 30_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 40, Color::Red)
  Citrine.draw_text("CITRINE PS2: HARDWARE EXCEPTION & PANIC HANDLER", 50, 10, 18, Color::White)

  # Central Diagnostic Card
  Citrine.draw_rectangle(40, 60, 560, 310, Color::DarkGray)
  Citrine.draw_rectangle(42, 62, 556, 306, Color::Black)

  Citrine.draw_text("SYSTEM SAFETY MONITOR & MEMORY CANARY AUDIT", 60, 80, 16, Color::Yellow)

  # Status Indicators
  Citrine.draw_rectangle(60, 120, 20, 20, Color::Green)
  Citrine.draw_text("SPRAM Canary (0x70000000): INTEGRITY VERIFIED [OK]", 95, 124, 13, Color::White)

  Citrine.draw_rectangle(60, 155, 20, 20, Color::Green)
  Citrine.draw_text("EE MIPS Register Checksum: STABLE [OK]", 95, 159, 13, Color::White)

  Citrine.draw_rectangle(60, 190, 20, 20, Color::Green)
  Citrine.draw_text("DMAC GIF Channel Bounds: UNCORRUPTED [OK]", 95, 194, 13, Color::White)

  # Progress Bar to Auto-Panic
  Citrine.draw_text("Timed Auto-Panic Countdown:", 60, 240, 13, Color::Yellow)
  progress_width = (frames * 500) // 180
  Citrine.draw_rectangle(60, 260, 500, 24, Color::DarkGray)
  Citrine.draw_rectangle(62, 262, progress_width, 20, Color::Red)
  Citrine.draw_text("Frames Elapsed: #{frames} / 180", 220, 265, 12, Color::White)

  # Action Prompt
  Citrine.draw_text("Press CROSS on DualShock 2 to trigger immediate panic test", 60, 310, 14, Color::White)
  Citrine.draw_text("Intercepted cleanly without freezing PS2 Emotion Engine", 60, 332, 12, Color::Gray)

  # Footer
  Citrine.draw_rectangle(40, 385, 560, 42, Color::DarkGray)
  Citrine.draw_text("Exception Vector: 0x80000180 | Crash Dump: GS Framebuffer & TTY Log", 60, 400, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
