# Citrine PS2 Example 11: Metaprogramming & ECS Architecture
# Demonstrates Crystal macros, citrine_ecs! component system, and fsm! jump tables

require "citrine"
require "citrine/inputmap"

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

input_map do
  action :attack, Button::Cross, port: 0
end

Citrine.init_window(640, 448, "Citrine PS2 - Metaprogramming & ECS")
Citrine.set_target_fps(60)

# Entity 0: Player
player_x = 320
player_y = 224
player_hp = 100
speed = 4
player_ai_state = STATE_IDLE

# Entity 1: Patrol Drone
drone_x = 160
drone_y = 120
drone_vx = 3
drone_hp = 80

frame_count = 0
attack_timer = 0

Citrine.main_loop do
  frame_count += 1
  pad = Citrine.player(0)

  # Handle Player Input & State Transitions
  is_moving = false
  if pad.button_down?(Button::Up)
    player_y -= speed
    is_moving = true
  end
  if pad.button_down?(Button::Down)
    player_y += speed
    is_moving = true
  end
  if pad.button_down?(Button::Left)
    player_x -= speed
    is_moving = true
  end
  if pad.button_down?(Button::Right)
    player_x += speed
    is_moving = true
  end

  # State updates via generated FSM constants
  if Action.is_pressed?(Actions::Attack) || pad.button_pressed?(Button::Cross)
    player_ai_state = STATE_ATTACKING
    attack_timer = 15 # 15 frame attack duration
  elsif attack_timer > 0
    attack_timer -= 1
    if attack_timer == 0
      player_ai_state = STATE_IDLE
    end
  elsif is_moving
    player_ai_state = STATE_MOVING
  else
    player_ai_state = STATE_IDLE
  end

  # Clamping using custom Crystal AST Macro
  player_x = clamp_bound(player_x, 40, 570)
  player_y = clamp_bound(player_y, 60, 360)

  # Update Drone Patrol AI
  drone_x += drone_vx
  if drone_x > 500
    drone_x = 500
    drone_vx = -3
  elsif drone_x < 140
    drone_x = 140
    drone_vx = 3
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12_u8, 16_u8, 26_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color::Blue)
  Citrine.draw_text("CITRINE PS2: METAPROGRAMMING, ECS & FSM DSL", 65, 8, 17, Color::White)

  # Drone Entity Render
  Citrine.draw_rectangle(drone_x, drone_y, 42, 28, Color::Red)
  Citrine.draw_circle(drone_x + 21, drone_y + 14, 6, Color::Yellow)
  Citrine.draw_text("PATROL DRONE", drone_x - 14, drone_y - 16, 11, Color::Red)

  # Drone Health Bar
  Citrine.draw_rectangle(drone_x - 5, drone_y + 32, 50, 6, Color::DarkGray)
  Citrine.draw_rectangle(drone_x - 5, drone_y + 32, (drone_hp * 50) // 100, 6, Color::Green)

  # Player Entity Render with FSM State Color
  px = player_x
  py = player_y

  player_color = if player_ai_state == STATE_ATTACKING
                   Color::Yellow
                 elsif player_ai_state == STATE_MOVING
                   Color::Cyan
                 else
                   Color::Green
                 end

  Citrine.draw_rectangle(px, py, 38, 38, player_color)
  Citrine.draw_rectangle(px + 4, py + 4, 30, 30, Color::Black)
  Citrine.draw_rectangle(px + 8, py + 8, 22, 22, player_color)


  # Attack Burst Effect
  if player_ai_state == STATE_ATTACKING
    Citrine.draw_circle(px + 19, py + 19, 32.0_f32, Color::Yellow)
    Citrine.draw_circle(px + 19, py + 19, 28.0_f32, Color::Black)
    Citrine.draw_line(px - 20, py + 19, px + 58, py + 19, Color::Red)
    Citrine.draw_line(px + 19, py - 20, px + 19, py + 58, Color::Red)
  end

  # Footer HUD Card
  Citrine.draw_rectangle(30, 375, 580, 56, Color::DarkGray)
  Citrine.draw_rectangle(32, 377, 576, 52, Color::Black)

  state_label = if player_ai_state == STATE_ATTACKING
                  "ATTACKING"
                elsif player_ai_state == STATE_MOVING
                  "MOVING"
                else
                  "IDLE"
                end

  Citrine.draw_text("FSM STATE: #{state_label} | HP: #{player_hp} / 100", 45, 386, 13, player_color)
  Citrine.draw_text("CROSS: Attack (Triggers FSM :attacking) | D-PAD: Move Entity", 45, 408, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
