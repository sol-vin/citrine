require "citrine"

# 08 DualShock 2 Controller Diagnostic Suite - Citrine PS2
# Demonstrates: Multi-port DualShock 2 hardware inspection, analog stick telemetry (-1.0..1.0),
# digital button bitmasks, and dual vibration motor (rumble) control

Citrine.init_window(640, 448, "08 DualShock 2 Controller Tester - Citrine PS2")
Citrine.set_target_fps(60)

puts "[CITRINE] 08 Controller Tester Initialized"
puts "[CITRINE] Ready for controller input: Press any button on Port 0 or Port 1"

active_port = 0
rumble_active = false

Citrine.main_loop do
  # Switch active port with L1 or Select
  pad = Citrine.player(active_port)

  if pad.button_pressed?(Button::Select)
    active_port = (active_port == 0) ? 1 : 0
    pad = Citrine.player(active_port)
    puts "[CITRINE] Active Port toggled to Port #{active_port}"
  end

  # Read 4 Analog Axes (-1.0 to 1.0)
  lx = Citrine.get_analog(active_port, 0)
  ly = Citrine.get_analog(active_port, 1)
  rx = Citrine.get_analog(active_port, 2)
  ry = Citrine.get_analog(active_port, 3)

  # Read All 16 Physical Buttons
  btn_up = pad.button_down?(Button::Up)
  btn_down = pad.button_down?(Button::Down)
  btn_left = pad.button_down?(Button::Left)
  btn_right = pad.button_down?(Button::Right)

  btn_triangle = pad.button_down?(Button::Triangle)
  btn_circle = pad.button_down?(Button::Circle)
  btn_cross = pad.button_down?(Button::Cross)
  btn_square = pad.button_down?(Button::Square)

  btn_l1 = pad.button_down?(Button::L1)
  btn_r1 = pad.button_down?(Button::R1)
  btn_l2 = pad.button_down?(Button::L2)
  btn_r2 = pad.button_down?(Button::R2)

  btn_select = pad.button_down?(Button::Select)
  btn_start = pad.button_down?(Button::Start)
  btn_l3 = pad.button_down?(Button::L3)
  btn_r3 = pad.button_down?(Button::R3)

  # Vibration testing: Cross activates small motor, Circle activates large motor
  if btn_cross && btn_circle
    Citrine.set_rumble(active_port, 255_u8, 255_u8)
    rumble_active = true
  elsif btn_cross
    Citrine.set_rumble(active_port, 200_u8, 0_u8)
    rumble_active = true
  elsif btn_circle
    Citrine.set_rumble(active_port, 0_u8, 255_u8)
    rumble_active = true
  else
    Citrine.set_rumble(active_port, 0_u8, 0_u8)
    rumble_active = false
  end

  if pad.button_pressed?(Button::Cross) && pad.button_pressed?(Button::Circle)
    puts "[CITRINE] Dual Rumble Motors Triggered (Small=255, Large=255)"
  elsif pad.button_pressed?(Button::Cross)
    puts "[CITRINE] Small Rumble Motor Triggered (200)"
  elsif pad.button_pressed?(Button::Circle)
    puts "[CITRINE] Large Rumble Motor Triggered (255)"
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(14_u8, 16_u8, 26_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 42, Color::Blue)
  Citrine.draw_text("DUALSHOCK 2 HARDWARE CALIBRATION & DIAGNOSTIC GUI", 35, 12, 16, Color::White)

  # Active Port Badge
  badge_col = (active_port == 0) ? Color::Green : Color::Cyan
  Citrine.draw_rectangle(520, 8, 100, 26, badge_col)
  Citrine.draw_text(active_port == 0 ? "PORT 1 (P1)" : "PORT 2 (P2)", 530, 14, 12, Color::Black)

  # --- Controller Chassis Silhouette ---
  Citrine.draw_rectangle(120, 60, 400, 210, Color::DarkGray)
  Citrine.draw_rectangle(122, 62, 396, 206, Color::Black)

  # Left & Right Grips
  Citrine.draw_rectangle(75, 120, 60, 170, Color::DarkGray)
  Citrine.draw_rectangle(77, 122, 56, 166, Color.new(20_u8, 22_u8, 30_u8, 255_u8))
  Citrine.draw_rectangle(505, 120, 60, 170, Color::DarkGray)
  Citrine.draw_rectangle(507, 122, 56, 166, Color.new(20_u8, 22_u8, 30_u8, 255_u8))

  # D-Pad Cross (Left Cluster)
  Citrine.draw_rectangle(170, 115, 24, 24, btn_up ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(170, 165, 24, 24, btn_down ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(145, 140, 24, 24, btn_left ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(195, 140, 24, 24, btn_right ? Color::Green : Color::DarkGray)

  # Action Buttons (Right Cluster: Triangle, Circle, Cross, Square)
  Citrine.draw_rectangle(440, 115, 24, 24, btn_triangle ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(465, 140, 24, 24, btn_circle ? Color::Red : Color::DarkGray)
  Citrine.draw_rectangle(440, 165, 24, 24, btn_cross ? Color::Blue : Color::DarkGray)
  Citrine.draw_rectangle(415, 140, 24, 24, btn_square ? Color::Magenta : Color::DarkGray)

  # Center Buttons (Select, Start, Mode)
  Citrine.draw_rectangle(270, 146, 36, 16, btn_select ? Color::Yellow : Color::DarkGray)
  Citrine.draw_text("SELECT", 268, 128, 10, Color::White)
  Citrine.draw_rectangle(334, 146, 36, 16, btn_start ? Color::Green : Color::DarkGray)
  Citrine.draw_text("START", 336, 128, 10, Color::White)

  # --- Analog Sticks (Left Stick & Right Stick Wells) ---
  # Left Stick Well (x: 240, y: 210, radius: 36)
  Citrine.draw_circle(240, 210, 36.0_f32, btn_l3 ? Color::Cyan : Color::DarkGray)
  Citrine.draw_circle(240, 210, 34.0_f32, Color::Black)
  # Left Stick Axis Markers (Crosshairs)
  Citrine.draw_rectangle(214, 210, 52, 1, Color::Gray)
  Citrine.draw_rectangle(240, 184, 1, 52, Color::Gray)
  ls_x = 240 + (lx * 24.0_f32).to_i32
  ls_y = 210 + (ly * 24.0_f32).to_i32
  Citrine.draw_rectangle(ls_x - 8, ls_y - 8, 16, 16, btn_l3 ? Color::Cyan : Color::White)
  # L3 Button Click Badge
  Citrine.draw_rectangle(222, 250, 36, 16, btn_l3 ? Color::Cyan : Color::DarkGray)
  Citrine.draw_text("L3", 234, 252, 10, btn_l3 ? Color::Black : Color::White)

  # Right Stick Well (x: 400, y: 210, radius: 36)
  Citrine.draw_circle(400, 210, 36.0_f32, btn_r3 ? Color::Cyan : Color::DarkGray)
  Citrine.draw_circle(400, 210, 34.0_f32, Color::Black)
  # Right Stick Axis Markers (Crosshairs)
  Citrine.draw_rectangle(374, 210, 52, 1, Color::Gray)
  Citrine.draw_rectangle(400, 184, 1, 52, Color::Gray)
  rs_x = 400 + (rx * 24.0_f32).to_i32
  rs_y = 210 + (ry * 24.0_f32).to_i32
  Citrine.draw_rectangle(rs_x - 8, rs_y - 8, 16, 16, btn_r3 ? Color::Cyan : Color::White)
  # R3 Button Click Badge
  Citrine.draw_rectangle(382, 250, 36, 16, btn_r3 ? Color::Cyan : Color::DarkGray)
  Citrine.draw_text("R3", 394, 252, 10, btn_r3 ? Color::Black : Color::White)

  # Shoulder Buttons L1/L2 and R1/R2
  Citrine.draw_rectangle(140, 48, 50, 10, btn_l1 ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(140, 34, 50, 10, btn_l2 ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(450, 48, 50, 10, btn_r1 ? Color::Green : Color::DarkGray)
  Citrine.draw_rectangle(450, 34, 50, 10, btn_r2 ? Color::Green : Color::DarkGray)

  # --- Lower Telemetry Readout Panel ---
  Citrine.draw_rectangle(30, 280, 580, 150, Color::DarkGray)
  Citrine.draw_rectangle(32, 282, 576, 146, Color::Black)

  Citrine.draw_text(active_port == 0 ? "HARDWARE REGISTER TELEMETRY - PORT 0 (P1)" : "HARDWARE REGISTER TELEMETRY - PORT 1 (P2)", 46, 292, 13, Color::Yellow)

  # Visual Stick Axis Meters
  Citrine.draw_text("LX:", 46, 314, 11, Color::Yellow)
  Citrine.draw_rectangle(75, 317, 80, 6, Color::DarkGray)
  Citrine.draw_rectangle(115, 314, 2, 12, Color::Yellow)
  Citrine.draw_rectangle(113, 315, 6, 10, Color::Cyan) # LX cursor marker

  Citrine.draw_text("LY:", 185, 314, 11, Color::Yellow)
  Citrine.draw_rectangle(215, 317, 80, 6, Color::DarkGray)
  Citrine.draw_rectangle(255, 314, 2, 12, Color::Yellow)
  Citrine.draw_rectangle(253, 315, 6, 10, Color::Cyan) # LY cursor marker

  Citrine.draw_text("RX:", 325, 314, 11, Color::Yellow)
  Citrine.draw_rectangle(355, 317, 80, 6, Color::DarkGray)
  Citrine.draw_rectangle(395, 314, 2, 12, Color::Yellow)
  Citrine.draw_rectangle(393, 315, 6, 10, Color::Cyan) # RX cursor marker

  Citrine.draw_text("RY:", 465, 314, 11, Color::Yellow)
  Citrine.draw_rectangle(495, 317, 80, 6, Color::DarkGray)
  Citrine.draw_rectangle(535, 314, 2, 12, Color::Yellow)
  Citrine.draw_rectangle(533, 315, 6, 10, Color::Cyan) # RY cursor marker

  # Vibration Motor Gauges
  Citrine.draw_text("Dual Shock Vibration Motors:", 46, 360, 12, Color::Yellow)
  Citrine.draw_text(btn_cross ? "Small Motor: ACTIVE (200)" : "Small Motor: IDLE", 46, 380, 11, btn_cross ? Color::Green : Color::Gray)
  Citrine.draw_text(btn_circle ? "Large Motor: ACTIVE (255)" : "Large Motor: IDLE", 280, 380, 11, btn_circle ? Color::Green : Color::Gray)

  Citrine.draw_text("SELECT: Switch Port | CROSS: Small Motor | CIRCLE: Large Motor", 46, 408, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
