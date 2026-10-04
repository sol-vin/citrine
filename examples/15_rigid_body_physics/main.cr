# Citrine PS2 Example 15: 2D Rigid Body Physics Engine (Box2D Architecture)
# Demonstrates require "citrine/physics/box2d", SAT collision, impulse solver, and raycasting
# Optimized for zero per-frame heap allocations with static colors and preallocated vectors

require "citrine"
require "citrine/physics/box2d"
require "citrine/physics/collision"
require "citrine/time"
require "citrine/math"
require "citrine/inputmap"

input_map do
  action :blast_crates, Button::Cross, port: 0
  action :reverse_gravity, Button::Circle, port: 0
  action :reset_crates, Button::Square, port: 0
end

Citrine.init_window(640, 448, "Citrine PS2 - Rigid Body Physics (Box2D)")
Citrine.set_target_fps(60)

# Pre-allocated color constants (0 heap allocations in main loop)
BG_COLOR       = Color.new(15_u8, 18_u8, 26_u8, 255_u8)
HEADER_BG      = Color.new(24_u8, 28_u8, 40_u8, 255_u8)
HEADER_TEXT    = Color.new(245_u8, 245_u8, 255_u8, 255_u8)
WALL_COLOR     = Color.new(44_u8, 62_u8, 80_u8, 255_u8)
CRATE1_COLOR   = Color.new(230_u8, 126_u8, 34_u8, 255_u8)
CRATE2_COLOR   = Color.new(241_u8, 196_u8, 15_u8, 255_u8)
CRATE3_COLOR   = Color.new(231_u8, 76_u8, 60_u8, 255_u8)
RAY_COLOR      = Color.new(52_u8, 152_u8, 219_u8, 180_u8)
HIT_COLOR      = Color.new(46_u8, 204_u8, 113_u8, 255_u8)
FOOTER_BG      = Color.new(22_u8, 26_u8, 38_u8, 240_u8)

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

# Pre-allocated reusable vectors for impulses and raycasting (zero per-frame allocations)
IMPULSE_BLAST_1 = Vector2.new(10.0_f32, -220.0_f32)
IMPULSE_BLAST_2 = Vector2.new(-15.0_f32, -260.0_f32)
IMPULSE_BLAST_3 = Vector2.new(5.0_f32, -200.0_f32)
IMPULSE_LEFT    = Vector2.new(-12.0_f32, 0.0_f32)
IMPULSE_RIGHT   = Vector2.new(12.0_f32, 0.0_f32)

ray_origin = Vector2.new(320.0_f32, 50.0_f32)
ray_dir    = Vector2.new(0.0_f32, 1.0_f32)
ray        = Citrine::Collision::Ray2D.new(ray_origin, ray_dir, 350.0_f32)

gravity_inverted = false

Citrine.main_loop do
  dt = Citrine.get_delta_time
  clamped_dt = dt > 0.033_f32 ? 0.016_f32 : dt
  pad = Citrine.player(0)

  # Interactive Impulse Explosions
  if Action.is_pressed?(Actions::BlastCrates) || pad.button_pressed?(Button::Cross)
    crate1.apply_impulse(IMPULSE_BLAST_1)
    crate2.apply_impulse(IMPULSE_BLAST_2)
    crate3.apply_impulse(IMPULSE_BLAST_3)
  end

  if Action.is_pressed?(Actions::ReverseGravity) || pad.button_pressed?(Button::Circle)
    gravity_inverted = !gravity_inverted
    world.gravity = gravity_inverted ? Vector2.new(0.0_f32, -380.0_f32) : Vector2.new(0.0_f32, 380.0_f32)
  end

  if pad.button_down?(Button::Left)
    crate1.apply_impulse(IMPULSE_LEFT)
    crate2.apply_impulse(IMPULSE_LEFT)
    crate3.apply_impulse(IMPULSE_LEFT)
  end

  if pad.button_down?(Button::Right)
    crate1.apply_impulse(IMPULSE_RIGHT)
    crate2.apply_impulse(IMPULSE_RIGHT)
    crate3.apply_impulse(IMPULSE_RIGHT)
  end

  if Action.is_pressed?(Actions::ResetCrates) || pad.button_pressed?(Button::Square)
    crate1.position.x = 280.0_f32
    crate1.position.y = 100.0_f32
    crate1.velocity.x = 0.0_f32
    crate1.velocity.y = 0.0_f32

    crate2.position.x = 340.0_f32
    crate2.position.y = 50.0_f32
    crate2.velocity.x = 0.0_f32
    crate2.velocity.y = 0.0_f32

    crate3.position.x = 300.0_f32
    crate3.position.y = 20.0_f32
    crate3.velocity.x = 0.0_f32
    crate3.velocity.y = 0.0_f32
  end

  # Step Physics (Impulse solver & Baumgarte stabilization)
  world.step(clamped_dt, 4, 2)

  # Raycast check down from top center using preallocated ray
  hit1 = Citrine::Collision.raycast_aabb(
    ray,
    crate1.position.x - crate1.width * 0.5_f32,
    crate1.position.y - crate1.height * 0.5_f32,
    crate1.width, crate1.height
  )

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(BG_COLOR)

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, HEADER_BG)
  Citrine.draw_text("CITRINE PS2: 2D RIGID BODY PHYSICS (BOX2D)", 20, 10, 18, HEADER_TEXT)

  # Draw Floor & Walls
  Citrine.draw_rectangle(30, 388, 580, 24, WALL_COLOR)
  Citrine.draw_rectangle(20, 40, 20, 360, WALL_COLOR)
  Citrine.draw_rectangle(600, 40, 20, 360, WALL_COLOR)

  # Draw Dynamic Crates
  c1_x = (crate1.position.x > 0.0_f32 && crate1.position.x < 640.0_f32) ? (crate1.position.x - crate1.width * 0.5_f32).to_i32 : 262
  c1_y = (crate1.position.y > 0.0_f32 && crate1.position.y < 448.0_f32) ? (crate1.position.y - crate1.height * 0.5_f32).to_i32 : 180
  Citrine.draw_rectangle(c1_x, c1_y, 36, 36, CRATE1_COLOR)

  c2_x = (crate2.position.x > 0.0_f32 && crate2.position.x < 640.0_f32) ? (crate2.position.x - crate2.width * 0.5_f32).to_i32 : 324
  c2_y = (crate2.position.y > 0.0_f32 && crate2.position.y < 448.0_f32) ? (crate2.position.y - crate2.height * 0.5_f32).to_i32 : 230
  Citrine.draw_rectangle(c2_x, c2_y, 32, 32, CRATE2_COLOR)

  c3_x = (crate3.position.x > 0.0_f32 && crate3.position.x < 640.0_f32) ? (crate3.position.x - crate3.width * 0.5_f32).to_i32 : 279
  c3_y = (crate3.position.y > 0.0_f32 && crate3.position.y < 448.0_f32) ? (crate3.position.y - crate3.height * 0.5_f32).to_i32 : 290
  Citrine.draw_rectangle(c3_x, c3_y, 42, 42, CRATE3_COLOR)


  # Draw Raycast Beam
  ray_end_y = (hit1.hit && hit1.point.y > 50.0_f32 && hit1.point.y < 388.0_f32) ? hit1.point.y : 388.0_f32
  Citrine.draw_line(320, 50, 320, ray_end_y.to_i32, RAY_COLOR)
  if hit1.hit && hit1.point.x > 0.0_f32 && hit1.point.x < 640.0_f32
    Citrine.draw_circle(hit1.point.x.to_i32, hit1.point.y.to_i32, 4, HIT_COLOR)
  end


  # Footer Telemetry & Controls
  Citrine.draw_rectangle(20, 400, 600, 36, FOOTER_BG)
  Citrine.draw_text("CROSS: Blast | CIRCLE: Gravity Invert | D-PAD: Push | SQUARE: Reset", 32, 412, 13, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
