# Citrine PS2 Example 13: Deterministic Physics & Verlet Particles
# Demonstrates require "citrine/physics", FixedPoint, AABB collision, and Verlet particle dynamics

require "citrine"
require "citrine/physics"

Citrine.init_window(640, 448, "Citrine PS2 - Physics & Particles")
Citrine.set_target_fps(60)

# Player Box
player_x = 240.0_f32
player_y = 200.0_f32
player_w = 48.0_f32
player_h = 48.0_f32
speed = 4.0_f32

# Obstacle Box
obs_x = 340.0_f32
obs_y = 180.0_f32
obs_w = 80.0_f32
obs_h = 80.0_f32

# Particle emitters
p1 = Citrine::VerletParticle.new(320.0_f32, 100.0_f32)
p2 = Citrine::VerletParticle.new(325.0_f32, 105.0_f32)
p3 = Citrine::VerletParticle.new(315.0_f32, 95.0_f32)

gravity = 0.35_f32
dt = 1.0_f32

Citrine.main_loop do
  # Input Handling
  if Citrine.button_down?(Button::Up)
    player_y -= speed
  end
  if Citrine.button_down?(Button::Down)
    player_y += speed
  end
  if Citrine.button_down?(Button::Left)
    player_x -= speed
  end
  if Citrine.button_down?(Button::Right)
    player_x += speed
  end

  # Bounds clamping
  player_x = Citrine::Physics2D.clamp(player_x, 20.0_f32, 570.0_f32)
  player_y = Citrine::Physics2D.clamp(player_y, 40.0_f32, 380.0_f32)

  # Check AABB Collision
  colliding = Citrine::Physics2D.check_collision_recs(
    player_x, player_y, player_w, player_h,
    obs_x, obs_y, obs_w, obs_h
  )

  # Update Verlet Particles
  p1.update(dt, gravity)
  p2.update(dt, gravity)
  p3.update(dt, gravity)

  p1.constrain(40.0_f32, 50.0_f32, 600.0_f32, 400.0_f32, 0.75_f32)
  p2.constrain(40.0_f32, 50.0_f32, 600.0_f32, 400.0_f32, 0.75_f32)
  p3.constrain(40.0_f32, 50.0_f32, 600.0_f32, 400.0_f32, 0.75_f32)

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(16_u8, 20_u8, 28_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color.new(24_u8, 30_u8, 44_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: 2D PHYSICS & VERLET PARTICLES", 20, 10, 18, Color.new(240_u8, 245_u8, 255_u8, 255_u8))

  # Draw Static Obstacle
  obs_color = colliding ? Color.new(231_u8, 76_u8, 60_u8, 255_u8) : Color.new(52_u8, 73_u8, 94_u8, 255_u8)
  Citrine.draw_rectangle(obs_x.to_i32, obs_y.to_i32, obs_w.to_i32, obs_h.to_i32, obs_color)
  Citrine.draw_text("OBSTACLE", obs_x.to_i32 + 10, obs_y.to_i32 + 30, 14, Color.new(255_u8, 255_u8, 255_u8, 255_u8))

  # Draw Player Box
  player_col = colliding ? Color.new(241_u8, 196_u8, 15_u8, 255_u8) : Color.new(46_u8, 204_u8, 113_u8, 255_u8)
  Citrine.draw_rectangle(player_x.to_i32, player_y.to_i32, player_w.to_i32, player_h.to_i32, player_col)
  Citrine.draw_text("PLAYER", player_x.to_i32 + 4, player_y.to_i32 + 16, 12, Color.new(20_u8, 20_u8, 20_u8, 255_u8))

  # Draw Bouncing Particles
  Citrine.draw_circle(p1.x.to_i32, p1.y.to_i32, 6.0_f32, Color.new(230_u8, 126_u8, 34_u8, 255_u8))
  Citrine.draw_circle(p2.x.to_i32, p2.y.to_i32, 5.0_f32, Color.new(243_u8, 156_u8, 18_u8, 255_u8))
  Citrine.draw_circle(p3.x.to_i32, p3.y.to_i32, 4.0_f32, Color.new(236_u8, 240_u8, 241_u8, 255_u8))

  # Collision Status Banner
  status_text = colliding ? "COLLISION DETECTED (AABB OVERLAP)" : "NO COLLISION - CLEAR PATH"
  banner_col = colliding ? Color.new(192_u8, 57_u8, 43_u8, 230_u8) : Color.new(39_u8, 174_u8, 96_u8, 230_u8)
  Citrine.draw_rectangle(20, 396, 600, 34, banner_col)
  Citrine.draw_text(status_text, 36, 404, 16, Color.new(255_u8, 255_u8, 255_u8, 255_u8))
  Citrine.draw_text("D-Pad: Move Player Box", 420, 404, 14, Color.new(255_u8, 255_u8, 255_u8, 255_u8))

  Citrine.end_drawing
end

Citrine.close_window
