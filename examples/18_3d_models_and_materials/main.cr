require "citrine"
require "citrine/inputmap"
require "citrine/draw3d"

# 18 3D Models, Materials, Meshes & Procedural Generation - Citrine PS2
# Demonstrates:
# - Procedural mesh generators: Cube, UV Sphere, Ground Plane, Torus
# - Material definitions: diffuse colors, textures, cull modes, blend modes
# - 3D Models: composite meshes and materials
# - Model rendering: draw_model, draw_model_ex (with rotation and scaling)
# - 3D primitives: draw_triangle_3d, billboards
# - Interactive camera orbit with DualShock 2 controller
# - Real-time 2D HUD telemetry overlay

input_map do
  action :orbit_left, Button::Left, port: 0
  action :orbit_right, Button::Right, port: 0
  action :orbit_up, Button::Up, port: 0
  action :orbit_down, Button::Down, port: 0
  action :toggle_wire, Button::Cross, port: 0
  action :toggle_rot, Button::Triangle, port: 0
end

Citrine.init_window(640, 448, "18 3D Models & Materials - Citrine PS2")
Citrine.set_target_fps(60)

cam = Camera3D.new(
  position: Vector3.new(0.0_f32, 5.0_f32, 10.0_f32),
  target: Vector3.new(0.0_f32, 0.0_f32, 0.0_f32),
  up: Vector3.new(0.0_f32, 1.0_f32, 0.0_f32),
  fovy: 45.0_f32,
  projection: 0
)

# 1. Procedural 3D Meshes
cube_mesh = Mesh.gen_cube(1.6_f32, 1.6_f32, 1.6_f32)
sphere_mesh = Mesh.gen_sphere(1.1_f32, 10, 10)
torus_mesh = Mesh.gen_torus(1.4_f32, 0.35_f32, 10, 10)
ground_mesh = Mesh.gen_plane(18.0_f32, 18.0_f32, 4, 4)

# 2. Material Definitions
mat_ruby = Material.from_color(Color::Red)
mat_gold = Material.from_color(Color::Yellow)
mat_emerald = Material.from_color(Color::Green)
mat_cyan = Material.from_color(Color::Cyan)
mat_ground = Material.from_color(Color.new(35_u8, 40_u8, 55_u8, 255_u8))

# 3. Composite 3D Models
center_model = Model.new("center_cube", [cube_mesh], [mat_ruby], [0])
orbit_model_a = Model.new("orbit_sphere", [sphere_mesh], [mat_emerald], [0])
orbit_model_b = Model.new("orbit_torus", [torus_mesh], [mat_gold], [0])

total_verts = cube_mesh.vertex_count + sphere_mesh.vertex_count + torus_mesh.vertex_count + ground_mesh.vertex_count
total_tris = cube_mesh.triangle_count + sphere_mesh.triangle_count + torus_mesh.triangle_count + ground_mesh.triangle_count

cam_angle_h = 0.0_f32
cam_radius = 11.0_f32
cam_height = 5.0_f32
model_rot = 0.0_f32
rotating = true
show_wires = false

Citrine.main_loop do
  pad = Citrine.player(0)

  # Interactive Camera Orbiting
  if Action.is_down?(Actions::OrbitLeft) || pad.button_down?(Button::Left)
    cam_angle_h -= 0.03_f32
  end
  if Action.is_down?(Actions::OrbitRight) || pad.button_down?(Button::Right)
    cam_angle_h += 0.03_f32
  end
  if Action.is_down?(Actions::OrbitUp) || pad.button_down?(Button::Up)
    cam_height += 0.1_f32 if cam_height < 12.0_f32
  end
  if Action.is_down?(Actions::OrbitDown) || pad.button_down?(Button::Down)
    cam_height -= 0.1_f32 if cam_height > 1.0_f32
  end

  # Analog stick orbit control
  stick_x = pad.analog_x
  cam_angle_h += stick_x * 0.04_f32 if stick_x.abs > 0.15_f32

  # Toggles
  if Action.is_pressed?(Actions::ToggleWire) || pad.button_pressed?(Button::Cross)
    show_wires = !show_wires
  end
  if Action.is_pressed?(Actions::ToggleRot) || pad.button_pressed?(Button::Triangle)
    rotating = !rotating
  end

  # Update rotation
  if rotating
    model_rot += 0.025_f32
  end

  # Camera orbital trigonometry
  cam.position.x = Math.sin(cam_angle_h) * cam_radius
  cam.position.y = cam_height
  cam.position.z = Math.cos(cam_angle_h) * cam_radius

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12_u8, 14_u8, 24_u8, 255_u8))

  # =========================================================================
  # 3D PERSPECTIVE PASS
  # =========================================================================
  Citrine.begin_mode_3d(cam)

  # 1. Ground Grid
  Citrine.draw_grid(18, 1.0_f32)

  # 2. Central Model (Ex with rotation axis)
  Citrine.draw_model_ex(
    center_model,
    Vector3.new(0.0_f32, 1.2_f32, 0.0_f32),
    Vector3.new(0.0_f32, 1.0_f32, 0.0_f32),
    model_rot,
    Vector3.new(1.0_f32, 1.0_f32, 1.0_f32),
    Color::White
  )

  # Optional wireframe overlay
  if show_wires
    Citrine.draw_cube_wires(0.0_f32, 1.2_f32, 0.0_f32, 1.65_f32, 1.65_f32, 1.65_f32, Color::Yellow)
  end

  # 3. Orbiting Sphere Model
  sphere_x = Math.cos(model_rot * 1.5_f32) * 3.8_f32
  sphere_z = Math.sin(model_rot * 1.5_f32) * 3.8_f32
  Citrine.draw_model(
    orbit_model_a,
    Vector3.new(sphere_x, 1.1_f32, sphere_z),
    1.0_f32,
    Color::Green
  )

  # 4. Orbiting Torus Model
  torus_x = -sphere_x
  torus_z = -sphere_z
  Citrine.draw_model_ex(
    orbit_model_b,
    Vector3.new(torus_x, 1.3_f32, torus_z),
    Vector3.new(1.0_f32, 0.5_f32, 0.0_f32),
    model_rot * 2.0_f32,
    Vector3.new(1.0_f32, 1.0_f32, 1.0_f32),
    Color::Yellow
  )

  # 5. Direct 3D Triangles (floating markers)
  Citrine.draw_triangle_3d(
    Vector3.new(-4.5_f32, 0.1_f32, -4.5_f32),
    Vector3.new(-3.5_f32, 0.1_f32, -4.5_f32),
    Vector3.new(-4.0_f32, 1.2_f32, -4.5_f32),
    Color::Cyan
  )
  Citrine.draw_triangle_3d(
    Vector3.new(4.5_f32, 0.1_f32, 4.5_f32),
    Vector3.new(3.5_f32, 0.1_f32, 4.5_f32),
    Vector3.new(4.0_f32, 1.2_f32, 4.5_f32),
    Color::Magenta
  )

  Citrine.end_mode_3d

  # =========================================================================
  # 2D HUD OVERLAY PASS
  # =========================================================================
  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color.new(20_u8, 30_u8, 60_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: 3D MODELS, MATERIALS & PROCEDURAL MESHES", 45, 8, 18, Color::White)

  # Left Telemetry Card
  Citrine.draw_rectangle(20, 50, 240, 160, Color::DarkGray)
  Citrine.draw_rectangle(22, 52, 236, 156, Color::Black)
  Citrine.draw_text("3D Scene Telemetry", 34, 62, 14, Color::Yellow)
  Citrine.draw_text("Total Vertices: #{total_verts}", 34, 86, 12, Color::White)
  Citrine.draw_text("Total Triangles: #{total_tris}", 34, 106, 12, Color::White)
  Citrine.draw_text("Camera Radius: #{cam_radius.to_i}", 34, 126, 12, Color::White)
  Citrine.draw_text("Wireframes: #{show_wires ? "ON" : "OFF"}", 34, 146, 12, Color::Cyan)
  Citrine.draw_text("Rotation: #{rotating ? "ACTIVE" : "PAUSED"}", 34, 166, 12, Color::Green)

  # Bottom Control Legend
  Citrine.draw_rectangle(20, 395, 600, 38, Color.new(20_u8, 25_u8, 40_u8, 230_u8))
  Citrine.draw_text("D-Pad / Left Stick: Orbit Camera | Cross: Wireframes | Triangle: Toggle Rotation", 40, 406, 13, Color::LightGray)

  Citrine.end_drawing
end
