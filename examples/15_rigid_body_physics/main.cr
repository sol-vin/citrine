# Citrine PS2 Example 15: 2D Rigid Body Physics Engine (Box2D Architecture)
# Demonstrates require "citrine/physics/box2d", SAT collision, impulse solver, and raycasting

require "citrine"
require "citrine/physics/box2d"
require "citrine/physics/collision"
require "citrine/time"
require "citrine/math"

Citrine.init_window(640, 448, "Citrine PS2 - Rigid Body Physics (Box2D)")
Citrine.set_target_fps(60)

# 1. Initialize Physics World
world = Citrine::Physics::PhysicsWorld2D.new(Vector2.new(0.0_f32, 380.0_f32))

# 2. Add Static Boundaries (Floor & Walls)
floor = Citrine::Physics::RigidBody2D.new(
  position: Vector2.new(320.0_f32, 400.0_f32),
  width: 580.0_f32,
  height: 24.0_f32,
  mass: 0.0_f32,
  body_type: Citrine::Physics::BodyType::Static
)
floor.restitution = 0.3_f32
world.add_body(floor)

wall_left = Citrine::Physics::RigidBody2D.new(
  position: Vector2.new(30.0_f32, 220.0_f32),
  width: 20.0_f32,
  height: 360.0_f32,
  mass: 0.0_f32,
  body_type: Citrine::Physics::BodyType::Static
)
world.add_body(wall_left)

wall_right = Citrine::Physics::RigidBody2D.new(
  position: Vector2.new(610.0_f32, 220.0_f32),
  width: 20.0_f32,
  height: 360.0_f32,
  mass: 0.0_f32,
  body_type: Citrine::Physics::BodyType::Static
)
world.add_body(wall_right)

# 3. Add Dynamic Crates
crate1 = Citrine::Physics::RigidBody2D.new(
  position: Vector2.new(280.0_f32, 100.0_f32),
  width: 36.0_f32,
  height: 36.0_f32,
  mass: 1.5_f32,
  body_type: Citrine::Physics::BodyType::Dynamic
)
crate1.restitution = 0.4_f32
world.add_body(crate1)

crate2 = Citrine::Physics::RigidBody2D.new(
  position: Vector2.new(340.0_f32, 50.0_f32),
  width: 32.0_f32,
  height: 32.0_f32,
  mass: 1.0_f32,
  body_type: Citrine::Physics::BodyType::Dynamic
)
crate2.restitution = 0.5_f32
world.add_body(crate2)

crate3 = Citrine::Physics::RigidBody2D.new(
  position: Vector2.new(300.0_f32, 20.0_f32),
  width: 42.0_f32,
  height: 42.0_f32,
  mass: 2.0_f32,
  body_type: Citrine::Physics::BodyType::Dynamic
)
crate3.restitution = 0.25_f32
world.add_body(crate3)

# Filter setup
layer_filter = Citrine::Collision::Filter.new(layer: 1_u16, mask: 0xFFFF_u16)

# Main Simulation Loop
Citrine.main_loop do
  dt = Citrine.get_delta_time
  clamped_dt = dt > 0.033_f32 ? 0.016_f32 : dt

  # Controller Inputs
  if Citrine.button_pressed?(Button::Cross)
    # Explosive upward impulse
    crate1.apply_impulse(Vector2.new(10.0_f32, -220.0_f32))
    crate2.apply_impulse(Vector2.new(-15.0_f32, -260.0_f32))
    crate3.apply_impulse(Vector2.new(5.0_f32, -200.0_f32))
  end

  if Citrine.button_down?(Button::Left)
    crate1.apply_impulse(Vector2.new(-12.0_f32, 0.0_f32))
    crate2.apply_impulse(Vector2.new(-12.0_f32, 0.0_f32))
    crate3.apply_impulse(Vector2.new(-12.0_f32, 0.0_f32))
  end

  if Citrine.button_down?(Button::Right)
    crate1.apply_impulse(Vector2.new(12.0_f32, 0.0_f32))
    crate2.apply_impulse(Vector2.new(12.0_f32, 0.0_f32))
    crate3.apply_impulse(Vector2.new(12.0_f32, 0.0_f32))
  end

  if Citrine.button_pressed?(Button::Square)
    crate1.position = Vector2.new(280.0_f32, 100.0_f32)
    crate1.velocity = Vector2.new(0.0_f32, 0.0_f32)
    crate2.position = Vector2.new(340.0_f32, 50.0_f32)
    crate2.velocity = Vector2.new(0.0_f32, 0.0_f32)
    crate3.position = Vector2.new(300.0_f32, 20.0_f32)
    crate3.velocity = Vector2.new(0.0_f32, 0.0_f32)
  end

  # Step Physics (Impulse solver & Baumgarte stabilization)
  world.step(clamped_dt, 4, 2)

  # Raycast check down from top center
  ray_origin = Vector2.new(320.0_f32, 50.0_f32)
  ray_dir = Vector2.new(0.0_f32, 1.0_f32)
  ray = Citrine::Collision::Ray2D.new(ray_origin, ray_dir, 350.0_f32)
  hit1 = Citrine::Collision.raycast_aabb(
    ray,
    crate1.position.x - crate1.width * 0.5_f32,
    crate1.position.y - crate1.height * 0.5_f32,
    crate1.width, crate1.height
  )

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(15_u8, 18_u8, 26_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color.new(24_u8, 28_u8, 40_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: 2D RIGID BODY PHYSICS (BOX2D)", 20, 10, 18, Color.new(245_u8, 245_u8, 255_u8, 255_u8))

  # Draw Floor & Walls
  Citrine.draw_rectangle(30, 388, 580, 24, Color.new(44_u8, 62_u8, 80_u8, 255_u8))
  Citrine.draw_rectangle(20, 40, 20, 360, Color.new(44_u8, 62_u8, 80_u8, 255_u8))
  Citrine.draw_rectangle(600, 40, 20, 360, Color.new(44_u8, 62_u8, 80_u8, 255_u8))

  # Draw Dynamic Crates
  c1_x = (crate1.position.x - crate1.width * 0.5_f32).to_i32
  c1_y = (crate1.position.y - crate1.height * 0.5_f32).to_i32
  Citrine.draw_rectangle(c1_x, c1_y, crate1.width.to_i32, crate1.height.to_i32, Color.new(230_u8, 126_u8, 34_u8, 255_u8))

  c2_x = (crate2.position.x - crate2.width * 0.5_f32).to_i32
  c2_y = (crate2.position.y - crate2.height * 0.5_f32).to_i32
  Citrine.draw_rectangle(c2_x, c2_y, crate2.width.to_i32, crate2.height.to_i32, Color.new(241_u8, 196_u8, 15_u8, 255_u8))

  c3_x = (crate3.position.x - crate3.width * 0.5_f32).to_i32
  c3_y = (crate3.position.y - crate3.height * 0.5_f32).to_i32
  Citrine.draw_rectangle(c3_x, c3_y, crate3.width.to_i32, crate3.height.to_i32, Color.new(231_u8, 76_u8, 60_u8, 255_u8))

  # Draw Raycast Beam
  ray_end_y = hit1.hit ? hit1.point.y : 388.0_f32
  Citrine.draw_line(320, 50, 320, ray_end_y.to_i32, Color.new(52_u8, 152_u8, 219_u8, 180_u8))
  if hit1.hit
    Citrine.draw_circle(hit1.point.x.to_i32, hit1.point.y.to_i32, 4.0_f32, Color.new(46_u8, 204_u8, 113_u8, 255_u8))
  end

  # Footer Telemetry & Controls
  Citrine.draw_rectangle(20, 400, 600, 36, Color.new(22_u8, 26_u8, 38_u8, 240_u8))
  Citrine.draw_text("Bodies: 6 | Solver: Impulse + Baumgarte | Cross: Blast | D-Pad: Push", 32, 410, 14, Color.new(255_u8, 255_u8, 255_u8, 255_u8))

  Citrine.end_drawing
end

Citrine.close_window
