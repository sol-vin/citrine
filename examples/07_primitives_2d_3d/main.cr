require "citrine"
require "citrine/inputmap"

# 07 2D & 3D Primitives - Citrine PS2
# Demonstrates: 3D Perspective Camera, Floor Grid, Rotating 3D Cubes & Wireframes,
# combined with high-contrast 2D HUD overlays on Sony Graphics Synthesizer

input_map do
  action :orbit_left, Button::Left, port: 0
  action :orbit_right, Button::Right, port: 0
  action :toggle_wire, Button::Cross, port: 0
end

Citrine.init_window(640, 448, "07 2D & 3D Primitives - Citrine PS2")
Citrine.set_target_fps(60)

cam = Camera3D.new(
  position: Vector3.new(0.0_f32, 4.5_f32, 8.5_f32),
  target: Vector3.new(0.0_f32, 0.0_f32, 0.0_f32),
  up: Vector3.new(0.0_f32, 1.0_f32, 0.0_f32),
  fovy: 45.0_f32,
  projection: 0
)

cube_x = 0.0_f32
cube_y = 0.6_f32
cube_z = 0.0_f32
cube_dir = 0.04_f32
show_wires = true
cam_angle = 0.0_f32

Citrine.main_loop do
  pad = Citrine.player(0)

  # Interactive Camera Orbiting
  if Action.is_down?(Actions::OrbitLeft) || pad.button_down?(Button::Left)
    cam_angle -= 0.03_f32
  end
  if Action.is_down?(Actions::OrbitRight) || pad.button_down?(Button::Right)
    cam_angle += 0.03_f32
  end

  if Action.is_pressed?(Actions::ToggleWire) || pad.button_pressed?(Button::Cross)
    show_wires = !show_wires
  end

  # Oscillating Central 3D Cube
  cube_x += cube_dir
  if cube_x > 2.8_f32
    cube_x = 2.8_f32
    cube_dir = -0.04_f32
  elsif cube_x < -2.8_f32
    cube_x = -2.8_f32
    cube_dir = 0.04_f32
  end

  # Update Camera Orbital Trigonometry
  cam.position.x = Math.sin(cam_angle) * 8.5_f32
  cam.position.z = Math.cos(cam_angle) * 8.5_f32

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(10_u8, 12_u8, 20_u8, 255_u8))

  # =========================================================================
  # 3D SCENE PASS (Perspective Mode)
  # =========================================================================
  Citrine.begin_mode_3d(cam)

  # Ground Grid
  Citrine.draw_grid(16, 1.0_f32)

  # Dynamic Oscillating Center Cube
  Citrine.draw_cube(cube_x, cube_y, cube_z, 1.5_f32, 1.5_f32, 1.5_f32, Color::Red)
  if show_wires
    Citrine.draw_cube_wires(cube_x, cube_y, cube_z, 1.6_f32, 1.6_f32, 1.6_f32, Color::Yellow)
  end

  # Surrounding Stationary Landmark Cubes
  Citrine.draw_cube(-3.2_f32, 0.5_f32, -2.5_f32, 1.0_f32, 1.0_f32, 1.0_f32, Color::Blue)
  Citrine.draw_cube(3.2_f32, 0.5_f32, -2.5_f32, 1.0_f32, 1.0_f32, 1.0_f32, Color::Green)
  Citrine.draw_cube(0.0_f32, 0.5_f32, -4.0_f32, 1.2_f32, 1.2_f32, 1.2_f32, Color::Cyan)

  if show_wires
    Citrine.draw_cube_wires(-3.2_f32, 0.5_f32, -2.5_f32, 1.05_f32, 1.05_f32, 1.05_f32, Color::White)
    Citrine.draw_cube_wires(3.2_f32, 0.5_f32, -2.5_f32, 1.05_f32, 1.05_f32, 1.05_f32, Color::White)
  end

  Citrine.end_mode_3d

  # =========================================================================
  # 2D OVERLAY PASS (Screen Space HUD)
  # =========================================================================
  # Top Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color::Blue)
  Citrine.draw_text("CITRINE PS2: 2D & 3D PRIMITIVE RASTERIZATION", 70, 8, 18, Color::White)

  # Left Telemetry HUD Card
  Citrine.draw_rectangle(20, 50, 210, 165, Color::DarkGray)
  Citrine.draw_rectangle(22, 52, 206, 161, Color::Black)
  Citrine.draw_text("3D Camera Telemetry", 34, 62, 13, Color::Yellow)
  Citrine.draw_text("FOV: 45.0 deg | NTSC", 34, 82, 12, Color::White)
  Citrine.draw_text("Cam Pos X: #{cam.position.x.to_i32}", 34, 102, 12, Color::White)
  Citrine.draw_text("Cam Pos Z: #{cam.position.z.to_i32}", 34, 122, 12, Color::White)
  Citrine.draw_text("Cube Osc: #{cube_x.to_i32}", 34, 142, 12, Color::White)
  Citrine.draw_text("Wireframes: #{show_wires ? "ON" : "OFF"}", 34, 162, 12, Color::Yellow)

  # Right 2D Primitives Preview Card
  Citrine.draw_rectangle(410, 50, 210, 165, Color::DarkGray)
  Citrine.draw_rectangle(412, 52, 206, 161, Color::Black)
  Citrine.draw_text("Simultaneous 2D Pass", 424, 62, 13, Color::Yellow)
  Citrine.draw_rectangle(430, 90, 40, 40, Color::Red)
  Citrine.draw_circle(510, 110, 20.0_f32, Color::Green)
  Citrine.draw_triangle(550, 130, 575, 90, 600, 130, Color::Cyan)
  Citrine.draw_text("Mixed 2D/3D Rendering", 430, 150, 11, Color::White)

  # Footer Controls
  Citrine.draw_rectangle(20, 390, 600, 44, Color::DarkGray)
  Citrine.draw_rectangle(22, 392, 596, 40, Color::Black)
  Citrine.draw_text("D-Pad Left/Right: Orbit 3D Camera | Cross: Toggle Wireframe Overlay", 40, 404, 13, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
