require "citrine"

# 01 Hello World - Citrine PS2
# Renders "Hello World \n Frame: #{current_frame_number}" on screen with a live blinking badge
# Demonstrates: Frame loop execution, dynamic frame counting, and GS 2D primitives

Citrine.init_window(640, 448, "01 Hello World - Citrine PS2")
Citrine.set_target_fps(60)

current_frame_number = 0

Citrine.main_loop do
  current_frame_number += 1

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Centered Hello World & Frame Counter
  Citrine.draw_text("Hello World \n Frame: #{current_frame_number}", 180, 190, 20, Color::White)

  # [LIVE] Indicator with Blinking Circle (toggles every second: 60 frames)
  is_blink_on = (current_frame_number % 60) < 30
  circle_col = is_blink_on ? Color::Red : Color::DarkGray

  # Little circle in front of the [LIVE] badge that blinks every second
  Citrine.draw_circle(466, 35, 5, circle_col)

  # Small rectangle that says "[LIVE]"
  Citrine.draw_rectangle(480, 24, 76, 22, Color::DarkGray)
  Citrine.draw_text("[LIVE]", 492, 28, 14, is_blink_on ? Color::White : Color::LightGray)

  Citrine.end_drawing
end

Citrine.close_window
