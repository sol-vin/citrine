# Citrine PS2 Example 13: Deterministic Physics & Verlet Particles
# Demonstrates require "citrine/physics", FixedPoint, AABB collision, and Verlet particle dynamics

require "citrine"
require "citrine/physics"
require "citrine/inputmap"

input_map do
  action :burst_particles, Button::Cross, port: 0
end

Citrine.init_window(640, 448, "Citrine PS2 - Physics & Particles")
Citrine.set_target_fps(60)

# Pre-allocated color constants
BG_COLOR       = Color.new(14_u8, 18_u8, 28_u8, 255_u8)
OBSTACLE_NORMAL = Color.new(41_u8, 128_u8, 185_u8, 255_u8)
OBSTACLE_HIT    = Color.new(231_u8, 76_u8, 60_u8, 255_u8)

# Player Box
player_x = 180
player_y = 200
player_w = 44
player_h = 44
speed = 4

# Obstacle Box
obs_x = 360
obs_y = 180
obs_w = 80
obs_h = 80


# Pre-allocated array of 12 Verlet Particles (fountain spray)
particles = [] of Citrine::VerletParticle
12.times do |i|
  p = Citrine::VerletParticle.new(320.0_f32 + (i * 4).to_f32, 100.0_f32)
  p.old_x = 320.0_f32 + (i * 4).to_f32 - ((i % 5) - 2).to_f32 * 2.0_f32
  p.old_y = 100.0_f32 + 2.0_f32
  particles << p
end

gravity = 0.35_f32
dt = 1.0_f32

Citrine.main_loop do
  pad = Citrine.player(0)

  # Player Movement
  if pad.button_down?(Button::Up)
    player_y -= speed
  end
  if pad.button_down?(Button::Down)
    player_y += speed
  end
  if pad.button_down?(Button::Left)
    player_x -= speed
  end
  if pad.button_down?(Button::Right)
    player_x += speed
  end

  # Bounds clamping
  if player_x < 20
    player_x = 20
  elsif player_x > 570
    player_x = 570
  end
  if player_y < 50
    player_y = 50
  elsif player_y > 330
    player_y = 330
  end

  # Burst particles on Cross button press
  if Action.is_pressed?(Actions::BurstParticles) || pad.button_pressed?(Button::Cross)
    particles.each_with_index do |p, i|
      p.x = (player_x + 22).to_f32
      p.y = (player_y + 10).to_f32
      p.old_x = p.x - ((i % 7) - 3).to_f32 * 2.5_f32
      p.old_y = p.y + 4.5_f32
    end
  end

  # Pure-integer AABB Collision Detection
  colliding = player_x < obs_x + obs_w &&
              player_x + player_w > obs_x &&
              player_y < obs_y + obs_h &&
              player_y + player_h > obs_y

  # Update Verlet Particles & Floor Bounce
  particles.each do |p|
    p.update(dt, gravity)
    # Floor bounce at y = 370
    if p.y > 370.0_f32
      p.y = 370.0_f32
      vy = p.y - p.old_y
      p.old_y = p.y + vy * 0.7_f32
    end
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(BG_COLOR)

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color::Blue)
  Citrine.draw_text("CITRINE PS2: DETERMINISTIC VERLET PARTICLES & AABB", 40, 8, 17, Color::White)

  # Floor Line
  Citrine.draw_rectangle(20, 372, 600, 4, Color::DarkGray)

  # Draw Obstacle Box (Red on collision, Blue when safe)
  Citrine.draw_rectangle(obs_x, obs_y, obs_w, obs_h, colliding ? OBSTACLE_HIT : OBSTACLE_NORMAL)
  Citrine.draw_text(colliding ? "COLLISION!" : "OBSTACLE", obs_x + 8, obs_y + 32, 13, Color::White)

  # Draw Player Box
  Citrine.draw_rectangle(player_x, player_y, player_w, player_h, Color::Yellow)
  Citrine.draw_rectangle(player_x + 4, player_y + 4, player_w - 8, player_h - 8, Color::Black)
  Citrine.draw_text("P1", player_x + 14, player_y + 14, 14, Color::Yellow)


  # Draw Verlet Particles
  particles.each_with_index do |p, i|
    col = (i % 2 == 0) ? Color::Cyan : Color::Magenta
    par_x = (p.x > 0.0_f32 && p.x < 640.0_f32) ? p.x.to_i32 : 320 + (i * 8)
    par_y = (p.y > 0.0_f32 && p.y < 448.0_f32) ? p.y.to_i32 : 120 + (i * 12)
    Citrine.draw_circle(par_x, par_y, 4, col)
  end


  # Footer HUD Card
  Citrine.draw_rectangle(20, 388, 600, 46, Color::DarkGray)
  Citrine.draw_rectangle(22, 390, 596, 42, Color::Black)
  Citrine.draw_text("AABB Status: #{colliding ? "INTERSECTING" : "CLEAR"} | Particles: #{particles.size} Active", 35, 398, 12, colliding ? Color::Red : Color::Green)
  Citrine.draw_text("CROSS: Burst Particle Fountain | D-PAD: Move Player Box", 35, 416, 12, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
