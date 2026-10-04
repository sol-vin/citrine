require "citrine"
require "citrine/inputmap"

# 03 Entity Fibers - Citrine PS2
# Demonstrates: Cooperative multitasking with Citrine Fibers (Citrine.spawn),
# autonomous entity AI coroutines, and zero-allocation entity struct updates

input_map do
  action :move_left, Button::Left, port: 0
  action :move_right, Button::Right, port: 0
  action :jump, Button::Cross, port: 0
end

struct EntityState
  property x : Int32
  property y : Int32
  property dir : Int32
  property color : Int32

  def initialize(@x : Int32, @y : Int32, @dir : Int32, @color : Int32)
  end
end

Citrine.init_window(640, 448, "03 Entity Fibers - Citrine PS2")
Citrine.set_target_fps(60)

# Shared entity state structures updated cooperatively by fibers
drone = EntityState.new(120, 126, 3, Color::Cyan)
sentry = EntityState.new(460, 206, -2, Color::Magenta)

# Player Avatar State
player_x = 280
player_y = 310

# Fiber 1: Autonomous Patrol Drone AI
Citrine.spawn do
  while true
    drone.x += drone.dir
    if drone.x > 520
      drone.x = 520
      drone.dir = -3
    elsif drone.x < 80
      drone.x = 80
      drone.dir = 3
    end
    Citrine.yield
  end
end

# Fiber 2: Autonomous Sentry Hover AI
Citrine.spawn do
  hover_step = 0
  while true
    sentry.x += sentry.dir
    if sentry.x > 500
      sentry.x = 500
      sentry.dir = -2
    elsif sentry.x < 120
      sentry.x = 120
      sentry.dir = 2
    end
    hover_step = (hover_step + 1) % 60
    sentry.y = 206 + (hover_step < 30 ? (hover_step // 5) : ((60 - hover_step) // 5))
    Citrine.yield
  end
end

Citrine.main_loop do
  pad = Citrine.player(0)

  # Interactive Player Movement
  if Action.is_down?(Actions::MoveLeft) || pad.button_down?(Button::Left)
    if player_x > 50
      player_x -= 4
    end
  end
  if Action.is_down?(Actions::MoveRight) || pad.button_down?(Button::Right)
    if player_x < 550
      player_x += 4
    end
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(10_u8, 14_u8, 22_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 38, Color::Blue)
  Citrine.draw_text("CITRINE PS2: COOPERATIVE ENTITY FIBERS", 110, 8, 18, Color::White)

  # --- Multi-Tier Platforms ---
  # Top Platform (Drone)
  Citrine.draw_rectangle(60, 150, 520, 10, Color::DarkGray)
  Citrine.draw_rectangle(60, 150, 520, 2, Color::Cyan)

  # Middle Platform (Sentry)
  Citrine.draw_rectangle(100, 240, 440, 10, Color::DarkGray)
  Citrine.draw_rectangle(100, 240, 440, 2, Color::Magenta)

  # Bottom Ground Floor (Player)
  Citrine.draw_rectangle(40, 350, 560, 16, Color::Gray)
  Citrine.draw_rectangle(40, 350, 560, 3, Color::Yellow)

  # --- Render Fiber Entities ---
  # Drone 1 (Controlled by Fiber 1)
  Citrine.draw_rectangle(drone.x, drone.y, 36, 22, drone.color)
  Citrine.draw_circle(drone.x + 18, drone.y + 11, 5, Color::White)
  Citrine.draw_text("DRONE 1 [FIBER]", drone.x - 12, drone.y - 18, 11, Color::Cyan)

  # Sentry 2 (Controlled by Fiber 2)
  Citrine.draw_rectangle(sentry.x, sentry.y, 32, 32, sentry.color)
  Citrine.draw_circle(sentry.x + 16, sentry.y + 16, 6, Color::Yellow)
  Citrine.draw_text("SENTRY 2 [FIBER]", sentry.x - 14, sentry.y - 18, 11, Color::Magenta)

  # Player Avatar
  Citrine.draw_rectangle(player_x, player_y, 36, 40, Color::Yellow)
  Citrine.draw_rectangle(player_x + 4, player_y + 4, 28, 32, Color::Black)
  Citrine.draw_circle(player_x + 18, player_y + 20, 6, Color::Red)
  Citrine.draw_text("PLAYER", player_x - 4, player_y - 16, 12, Color::White)


  # Telemetry Card
  Citrine.draw_rectangle(40, 380, 560, 48, Color::Black)
  Citrine.draw_rectangle(40, 380, 560, 2, Color::Gray)
  Citrine.draw_text("Autonomous Entities scheduled concurrently across EE cooperative fiber queue", 60, 390, 13, Color::Yellow)
  Citrine.draw_text("D-Pad Left/Right: Move Avatar | Fibers: 2 Active Co-routines", 60, 408, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
