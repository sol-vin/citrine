require "citrine"
require "citrine/inputmap"
require "citrine/rng"
require "citrine/rng/secure"

# Godot-style InputMap Action configuration
input_map do
  action :spawn_one, Button::Cross, port: 0
  action :spawn_ten, Button::R1, port: 0
  action :reset, Button::Triangle, port: 0
end

class BouncingLogo
  property pos_x : Int32
  property pos_y : Int32
  property vel_x : Int32
  property vel_y : Int32
  property text_color_idx : Int32
  property bg_color_idx : Int32

  def initialize(@pos_x : Int32, @pos_y : Int32, @vel_x : Int32, @vel_y : Int32, @text_color_idx : Int32, @bg_color_idx : Int32)
  end

  def update(rng : Citrine::RNG::PRNG)
    @pos_x = @pos_x + @vel_x
    @pos_y = @pos_y + @vel_y

    bounced = 0
    # Left / Right boundaries: box width = 190, screen width = 640
    if @pos_x <= 10
      @pos_x = 10
      @vel_x = -@vel_x
      bounced = 1
    end
    if @pos_x >= 430
      @pos_x = 430
      @vel_x = -@vel_x
      bounced = 1
    end

    # Top / Bottom boundaries: box height = 44, screen height = 448
    if @pos_y <= 10
      @pos_y = 10
      @vel_y = -@vel_y
      bounced = 1
    end
    if @pos_y >= 360
      @pos_y = 360
      @vel_y = -@vel_y
      bounced = 1
    end

    if bounced == 1
      # Rotate text color using RNG: 1..5 step guarantees a different color (out of 6)
      step = rng.rand(1, 5)
      @text_color_idx = (@text_color_idx + step) % 6

      # BG color: pick an offset in 1..5 from text color to guarantee bg != text
      bg_step = rng.rand(1, 5)
      @bg_color_idx = (@text_color_idx + bg_step) % 6
    end
  end
end

def draw_colored_rect(x, y, w, h, c_idx)
  if c_idx == 0
    Citrine.draw_rectangle(x, y, w, h, Color::Red)
  elsif c_idx == 1
    Citrine.draw_rectangle(x, y, w, h, Color::Green)
  elsif c_idx == 2
    Citrine.draw_rectangle(x, y, w, h, Color::Blue)
  elsif c_idx == 3
    Citrine.draw_rectangle(x, y, w, h, Color::Yellow)
  elsif c_idx == 4
    Citrine.draw_rectangle(x, y, w, h, Color::Cyan)
  elsif c_idx == 5
    Citrine.draw_rectangle(x, y, w, h, Color::Magenta)
  else
    Citrine.draw_rectangle(x, y, w, h, Color::White)
  end
end

def draw_colored_text(text, x, y, size, c_idx)
  if c_idx == 0
    Citrine.draw_text(text, x, y, size, Color::Red)
  elsif c_idx == 1
    Citrine.draw_text(text, x, y, size, Color::Green)
  elsif c_idx == 2
    Citrine.draw_text(text, x, y, size, Color::Blue)
  elsif c_idx == 3
    Citrine.draw_text(text, x, y, size, Color::Yellow)
  elsif c_idx == 4
    Citrine.draw_text(text, x, y, size, Color::Cyan)
  elsif c_idx == 5
    Citrine.draw_text(text, x, y, size, Color::Magenta)
  else
    Citrine.draw_text(text, x, y, size, Color::White)
  end
end

Citrine.init_window(640, 448, "05 Hello World - DVD Bouncing Screensaver")
Citrine.set_target_fps(60)

# True hardware entropy seeding
entropy = Citrine::RNG::Secure.harvest_entropy
rng = Citrine::RNG::PRNG.new(entropy)
logos = [] of BouncingLogo

# Initial logo: starts at (240, 200), moving southeast, Blue BG with Yellow text
logos << BouncingLogo.new(240, 200, 7, 6, 3, 2)

Citrine.main_loop do
  pad = Citrine.player(0)

  # Cross button: spawn 1 new bouncing logo at random position & trajectory
  if (Action.is_pressed?(Actions::SpawnOne) || pad.button_pressed?(Button::Cross)) && logos.size < 128
    puts "[CITRINE] Button Cross (X) pressed!"
    rx = rng.rand(40, 400)
    ry = rng.rand(40, 320)
    sx = rng.rand(4, 7)
    sy = rng.rand(3, 6)
    dir_x = (((rng.next_u32 >> 16) & 1) == 0 ? -1 : 1) * sx
    dir_y = (((rng.next_u32 >> 24) & 1) == 0 ? -1 : 1) * sy
    rt_col = rng.rand(0, 5)
    rbg_col = (rt_col + rng.rand(1, 5)) % 6
    logos << BouncingLogo.new(rx, ry, dir_x, dir_y, rt_col, rbg_col)
  end

  # R1 button: stress test - spawn 10 logos at once!
  if (Action.is_pressed?(Actions::SpawnTen) || pad.button_pressed?(Button::R1)) && logos.size < 128
    puts "[CITRINE] Button R1 pressed!"
    10.times do
      if logos.size < 128
        rx = rng.rand(40, 400)
        ry = rng.rand(40, 320)
        sx = rng.rand(4, 7)
        sy = rng.rand(3, 6)
        dir_x = (((rng.next_u32 >> 16) & 1) == 0 ? -1 : 1) * sx
        dir_y = (((rng.next_u32 >> 24) & 1) == 0 ? -1 : 1) * sy
        rt_col = rng.rand(0, 5)
        rbg_col = (rt_col + rng.rand(1, 5)) % 6
        logos << BouncingLogo.new(rx, ry, dir_x, dir_y, rt_col, rbg_col)
      end
    end
  end

  # Triangle button: reset back to 1 logo
  if Action.is_pressed?(Actions::Reset) || pad.button_pressed?(Button::Triangle)
    puts "[CITRINE] Button Triangle pressed!"
    while logos.size > 1
      logos.pop
    end
  end

  # Update all logos
  logos.each do |logo|
    logo.update(rng)
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Draw screen border
  Citrine.draw_rectangle(0, 0, 640, 6, Color::Gray)
  Citrine.draw_rectangle(0, 442, 640, 6, Color::Gray)
  Citrine.draw_rectangle(0, 0, 6, 448, Color::Gray)
  Citrine.draw_rectangle(634, 0, 6, 448, Color::Gray)

  # Draw each bouncing Hello World logo (Background rectangle + Text)
  logos.each do |logo|
    px = logo.pos_x
    py = logo.pos_y
    bg_c = logo.bg_color_idx
    txt_c = logo.text_color_idx

    # Background rectangle behind text (always different color from text)
    draw_colored_rect(px, py, 190, 44, bg_c)
    # Inner border / bevel
    Citrine.draw_rectangle(px + 2, py + 2, 186, 40, Color::Black)
    draw_colored_rect(px + 4, py + 4, 182, 36, bg_c)

    # Hello World text
    draw_colored_text("HELLO WORLD!", px + 16, py + 12, 20, txt_c)
  end

  # Status HUD
  Citrine.draw_text("CROSS: +1 | R1: +10 | TRIANGLE: RESET | STRESS TEST", 60, 420, 14, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
