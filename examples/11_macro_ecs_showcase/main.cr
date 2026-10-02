# Citrine PS2 Example 11: Metaprogramming & ECS Architecture
# Demonstrates Crystal macros, citrine_ecs! component system, and fsm! jump tables

require "citrine"

# 1. Metaprogramming: Custom Crystal Macro for coordinate clamping
macro clamp_bound(val, min_v, max_v)
  if {{val}} < {{min_v}}
    {{min_v}}
  elsif {{val}} > {{max_v}}
    {{max_v}}
  else
    {{val}}
  end
end

# 2. Metaprogramming: citrine_ecs! component memory layout
citrine_ecs! do
  component Position, x: Float32, y: Float32
  component Velocity, vx: Float32, vy: Float32
  component Health, hp: Int32
  component Renderable, r: UInt8, g: UInt8, b: UInt8
end

# 3. Metaprogramming: Declarative Finite State Machine
fsm PlayerAI, initial: :idle do
  state :idle
  state :moving
  state :attacking
end

Citrine.init_window(640, 448, "Citrine PS2 - Metaprogramming & ECS")
Citrine.set_target_fps(60)

# Entity 0: Player
player_x = 320.0_f32
player_y = 224.0_f32
player_hp = 100
speed = 4.0_f32

# Entity 1: Patrol Drone
drone_x = 160.0_f32
drone_y = 120.0_f32
drone_vx = 3.0_f32

frame_count = 0

Citrine.main_loop do
  frame_count += 1

  # Handle Player Input & State Transitions
  is_moving = false
  if Citrine.button_down?(Button::Up)
    player_y -= speed
    is_moving = true
  end
  if Citrine.button_down?(Button::Down)
    player_y += speed
    is_moving = true
  end
  if Citrine.button_down?(Button::Left)
    player_x -= speed
    is_moving = true
  end
  if Citrine.button_down?(Button::Right)
    player_x += speed
    is_moving = true
  end

  # State updates via generated FSM constants
  if Citrine.button_pressed?(Button::Cross)
    player_ai_state = STATE_ATTACKING
  elsif is_moving
    player_ai_state = STATE_MOVING
  else
    player_ai_state = STATE_IDLE
  end

  # Clamping using custom macro
  player_x = clamp_bound(player_x, 20.0_f32, 600.0_f32)
  player_y = clamp_bound(player_y, 40.0_f32, 400.0_f32)

  # Update Drone Entity
  drone_x += drone_vx
  if drone_x > 580.0_f32 || drone_x < 60.0_f32
    drone_vx = -drone_vx
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(18_u8, 22_u8, 30_u8, 255_u8))

  # Header & Telemetry
  Citrine.draw_rectangle(0, 0, 640, 36, Color.new(28_u8, 34_u8, 48_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: METAPROGRAMMING & ECS", 20, 10, 18, Color.new(240_u8, 240_u8, 255_u8, 255_u8))
  Citrine.draw_text("COMPONENTS: 4 | FSM ACTIVE", 420, 10, 14, Color.new(100_u8, 220_u8, 140_u8, 255_u8))

  # Draw Drone Entity
  Citrine.draw_rectangle(drone_x.to_i32 - 12, drone_y.to_i32 - 12, 24, 24, Color.new(230_u8, 126_u8, 34_u8, 255_u8))
  Citrine.draw_text("DRONE (ECS ENTITY #1)", drone_x.to_i32 - 50, drone_y.to_i32 - 28, 12, Color.new(200_u8, 200_u8, 200_u8, 255_u8))

  # Draw Player Entity (Color depends on FSM state)
  player_color = if player_ai_state == STATE_ATTACKING
                   Color.new(231_u8, 76_u8, 60_u8, 255_u8) # Red: Attacking
                 elsif player_ai_state == STATE_MOVING
                   Color.new(52_u8, 152_u8, 219_u8, 255_u8) # Blue: Moving
                 else
                   Color.new(46_u8, 204_u8, 113_u8, 255_u8) # Green: Idle
                 end

  Citrine.draw_rectangle(player_x.to_i32 - 16, player_y.to_i32 - 16, 32, 32, player_color)
  Citrine.draw_rectangle(player_x.to_i32 - 20, player_y.to_i32 - 26, 40, 6, Color.new(40_u8, 40_u8, 40_u8, 255_u8))
  Citrine.draw_rectangle(player_x.to_i32 - 20, player_y.to_i32 - 26, (player_hp * 40 // 100), 6, Color.new(46_u8, 204_u8, 113_u8, 255_u8))

  # Status Banner
  state_label = if player_ai_state == STATE_ATTACKING
                  "STATE: ATTACKING (CROSS)"
                elsif player_ai_state == STATE_MOVING
                  "STATE: MOVING (D-PAD)"
                else
                  "STATE: IDLE"
                end

  Citrine.draw_rectangle(20, 390, 600, 36, Color.new(28_u8, 34_u8, 48_u8, 240_u8))
  Citrine.draw_text(state_label, 36, 400, 16, Color.new(255_u8, 255_u8, 255_u8, 255_u8))
  Citrine.draw_text("D-Pad: Move | Cross: Attack", 380, 400, 14, Color.new(180_u8, 190_u8, 210_u8, 255_u8))

  Citrine.end_drawing
end

Citrine.close_window
