require "../../src/stubs/citrine"

Citrine.init_window(640, 448, "07 2D & 3D Primitives - Citrine PS2")
Citrine.set_target_fps(60)

cam = Camera3D.new(
  position: Vector3.new(0.0, 4.0, 8.0),
  target: Vector3.new(0.0, 0.0, 0.0),
  up: Vector3.new(0.0, 1.0, 0.0),
  fovy: 45.0_f32,
  projection: 0
)

cube_x = 0.0
cube_y = 0.5
cube_z = 0.0
cube_dir = 0.04

Citrine.main_loop do
  # Animate 3D cube oscillation
  cube_x += cube_dir
  if cube_x > 2.5
    cube_x = 2.5
    cube_dir = -0.04
  elsif cube_x < -2.5
    cube_x = -2.5
    cube_dir = 0.04
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # --- 3D SCENE PASS ---
  Citrine.begin_mode_3d(cam)

  # Draw 3D floor grid (XZ plane)
  Citrine.draw_grid(12, 1.0)

  # Draw dynamic oscillating 3D cube and wireframe
  Citrine.draw_cube(cube_x, cube_y, cube_z, 1.5, 1.5, 1.5, Color::Red)
  Citrine.draw_cube_wires(cube_x, cube_y, cube_z, 1.6, 1.6, 1.6, Color::Yellow)

  # Draw stationary reference cubes
  Citrine.draw_cube(-3.0, 0.5, -2.0, 1.0, 1.0, 1.0, Color::Blue)
  Citrine.draw_cube(3.0, 0.5, -2.0, 1.0, 1.0, 1.0, Color::Green)

  Citrine.end_mode_3d

  # --- 2D OVERLAY PASS ---
  # Draw top header bar
  Citrine.draw_rectangle(0, 0, 640, 42, Color::Blue)
  Citrine.draw_text("CITRINE 2D & 3D PRIMITIVES DEMO", 170, 12, 16, Color::White)

  # Draw 2D primitives HUD card on the left
  Citrine.draw_rectangle(16, 54, 210, 170, Color::Gray)
  Citrine.draw_rectangle(18, 56, 206, 166, Color::Black)
  Citrine.draw_text("2D GS Primitives", 28, 64, 14, Color::Yellow)

  # 2D Shapes inside the HUD card
  Citrine.draw_rectangle(30, 90, 50, 40, Color::Red)
  Citrine.draw_circle(120, 110, 20, Color::Green)
  Citrine.draw_triangle(160, 130, 185, 90, 210, 130, Color::Yellow)
  Citrine.draw_line(30, 150, 200, 150, Color::White)
  Citrine.draw_text("Rect, Circle, Tri, Line", 30, 162, 12, Color::White)
  Citrine.draw_text("Rasterized via GS Prim", 30, 180, 12, Color::Gray)

  # Instructions at bottom
  Citrine.draw_rectangle(0, 416, 640, 32, Color::Black)
  Citrine.draw_text("Perspective Camera3D | 3D Z-Buffer + 2D Ortho Overlay", 120, 422, 12, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
