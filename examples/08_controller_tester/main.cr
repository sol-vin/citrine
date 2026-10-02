require "citrine"

Citrine.init_window(640, 448, "08 DualShock 2 Controller Tester - Citrine PS2")
Citrine.set_target_fps(60)

Citrine.main_loop do
  # Read Analog Sticks (-1.0 to 1.0)
  lx = Citrine.get_analog(0)
  ly = Citrine.get_analog(1)
  rx = Citrine.get_analog(2)
  ry = Citrine.get_analog(3)

  # Check buttons
  btn_up = Citrine.button_down?(Button::Up)
  btn_down = Citrine.button_down?(Button::Down)
  btn_left = Citrine.button_down?(Button::Left)
  btn_right = Citrine.button_down?(Button::Right)

  btn_triangle = Citrine.button_down?(Button::Triangle)
  btn_circle = Citrine.button_down?(Button::Circle)
  btn_cross = Citrine.button_down?(Button::Cross)
  btn_square = Citrine.button_down?(Button::Square)

  btn_l1 = Citrine.button_down?(Button::L1)
  btn_r1 = Citrine.button_down?(Button::R1)
  btn_l2 = Citrine.button_down?(Button::L2)
  btn_r2 = Citrine.button_down?(Button::R2)

  btn_select = Citrine.button_down?(Button::Select)
  btn_start = Citrine.button_down?(Button::Start)
  btn_l3 = Citrine.button_down?(Button::L3)
  btn_r3 = Citrine.button_down?(Button::R3)

  # Vibration test
  if btn_cross
    Citrine.set_rumble(128_u8, 0_u8)
  elsif btn_circle
    Citrine.set_rumble(0_u8, 255_u8)
  else
    Citrine.set_rumble(0_u8, 0_u8)
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Header
  Citrine.draw_rectangle(0, 0, 640, 40, Color::Blue)
  Citrine.draw_text("DUALSHOCK 2 CONTROLLER DIAGNOSTIC GUI", 130, 10, 16, Color::White)

  # Controller Chassis Silhouette
  Citrine.draw_rectangle(140, 100, 360, 200, Color::Gray)
  Citrine.draw_rectangle(90, 160, 80, 180, Color::Gray)  # Left grip
  Citrine.draw_rectangle(470, 160, 80, 180, Color::Gray) # Right grip
  Citrine.draw_rectangle(150, 110, 340, 180, Color::Black)
  Citrine.draw_rectangle(95, 170, 70, 160, Color::Black)
  Citrine.draw_rectangle(475, 170, 70, 160, Color::Black)

  # Shoulder Buttons L1/L2, R1/R2
  c_l2 = btn_l2 ? Color::Green : Color::Gray
  c_l1 = btn_l1 ? Color::Green : Color::Gray
  c_r1 = btn_r1 ? Color::Green : Color::Gray
  c_r2 = btn_r2 ? Color::Green : Color::Gray

  Citrine.draw_rectangle(120, 65, 50, 25, c_l2)
  Citrine.draw_text("L2", 135, 70, 14, Color::White)
  Citrine.draw_rectangle(120, 95, 50, 20, c_l1)
  Citrine.draw_text("L1", 135, 98, 14, Color::White)

  Citrine.draw_rectangle(470, 65, 50, 25, c_r2)
  Citrine.draw_text("R2", 485, 70, 14, Color::White)
  Citrine.draw_rectangle(470, 95, 50, 20, c_r1)
  Citrine.draw_text("R1", 485, 98, 14, Color::White)

  # D-Pad (Left side)
  dpad_center_x = 180
  dpad_center_y = 190

  c_up = btn_up ? Color::Green : Color::Gray
  c_down = btn_down ? Color::Green : Color::Gray
  c_left = btn_left ? Color::Green : Color::Gray
  c_right = btn_right ? Color::Green : Color::Gray

  Citrine.draw_rectangle(dpad_center_x - 10, dpad_center_y - 35, 20, 25, c_up)    # Up
  Citrine.draw_rectangle(dpad_center_x - 10, dpad_center_y + 10, 20, 25, c_down)  # Down
  Citrine.draw_rectangle(dpad_center_x - 35, dpad_center_y - 10, 25, 20, c_left)  # Left
  Citrine.draw_rectangle(dpad_center_x + 10, dpad_center_y - 10, 25, 20, c_right) # Right

  # Action Buttons (Right side diamond)
  face_center_x = 460
  face_center_y = 190

  c_tri = btn_triangle ? Color::Green : Color::Gray
  c_cir = btn_circle ? Color::Red : Color::Gray
  c_cro = btn_cross ? Color::Blue : Color::Gray
  c_squ = btn_square ? Color::Yellow : Color::Gray

  Citrine.draw_circle(face_center_x, face_center_y - 25, 12, c_tri) # Triangle
  Citrine.draw_text("^", face_center_x - 4, face_center_y - 32, 14, Color::White)

  Citrine.draw_circle(face_center_x + 25, face_center_y, 12, c_cir) # Circle
  Citrine.draw_text("O", face_center_x + 20, face_center_y - 7, 14, Color::White)

  Citrine.draw_circle(face_center_x, face_center_y + 25, 12, c_cro) # Cross
  Citrine.draw_text("X", face_center_x - 5, face_center_y + 18, 14, Color::White)

  Citrine.draw_circle(face_center_x - 25, face_center_y, 12, c_squ) # Square
  Citrine.draw_text("[]", face_center_x - 31, face_center_y - 7, 12, Color::White)

  # Center Buttons: Select & Start & Analog LED
  c_sel = btn_select ? Color::Green : Color::Gray
  c_sta = btn_start ? Color::Green : Color::Gray

  Citrine.draw_rectangle(270, 185, 30, 15, c_sel)
  Citrine.draw_text("SELECT", 262, 205, 10, Color::White)

  Citrine.draw_rectangle(340, 185, 30, 15, c_sta)
  Citrine.draw_text("START", 338, 205, 10, Color::White)

  Citrine.draw_circle(320, 220, 5, Color::Red) # Analog Mode LED
  Citrine.draw_text("ANALOG", 305, 230, 9, Color::Red)

  # Analog Sticks (Left stick @ 245, 255; Right stick @ 395, 255)
  ls_x = 245
  ls_y = 255
  rs_x = 395
  rs_y = 255

  # Left stick well & crosshair
  Citrine.draw_circle(ls_x, ls_y, 35, Color::Gray)
  Citrine.draw_circle(ls_x, ls_y, 33, Color::Black)
  Citrine.draw_line(ls_x - 30, ls_y, ls_x + 30, ls_y, Color::Gray)
  Citrine.draw_line(ls_x, ls_y - 30, ls_x, ls_y + 30, Color::Gray)

  # Left stick position
  stick_offset_lx = (lx * 24.0).to_i32
  stick_offset_ly = (ly * 24.0).to_i32
  c_l3 = btn_l3 ? Color::Yellow : Color::White
  Citrine.draw_circle(ls_x + stick_offset_lx, ls_y + stick_offset_ly, 18, c_l3)

  # Right stick well & crosshair
  Citrine.draw_circle(rs_x, rs_y, 35, Color::Gray)
  Citrine.draw_circle(rs_x, rs_y, 33, Color::Black)
  Citrine.draw_line(rs_x - 30, rs_y, rs_x + 30, rs_y, Color::Gray)
  Citrine.draw_line(rs_x, rs_y - 30, rs_x, rs_y + 30, Color::Gray)

  # Right stick position
  stick_offset_rx = (rx * 24.0).to_i32
  stick_offset_ry = (ry * 24.0).to_i32
  c_r3 = btn_r3 ? Color::Yellow : Color::White
  Citrine.draw_circle(rs_x + stick_offset_rx, rs_y + stick_offset_ry, 18, c_r3)

  # Telemetry status footer
  Citrine.draw_rectangle(0, 390, 640, 58, Color::Blue)
  Citrine.draw_text("Port 1: DUALSHOCK 2 Analog Controller Connected", 30, 400, 14, Color::Yellow)
  Citrine.draw_text("Press CROSS / CIRCLE to test DualShock rumble motors", 30, 422, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
