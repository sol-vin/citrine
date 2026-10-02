require "citrine"

class SimpleRng
  property seed : Int32

  def initialize(@seed : Int32)
  end

  def next_int(min_val : Int32, max_val : Int32) : Int32
    @seed = ((@seed * 1103515245) + 12345) % 2147483647
    if @seed < 0
      @seed = -@seed
    end
    range = max_val - min_val + 1
    min_val + (@seed % range)
  end
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

  def update(rng : SimpleRng)
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
      # Rotate text color: 1..5 step guarantees a different color (out of 6)
      step = rng.next_int(1, 5)
      @text_color_idx = (@text_color_idx + step) % 6

      # BG color: pick an offset in 1..5 from text color to guarantee bg != text
      bg_step = rng.next_int(1, 5)
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

rng = SimpleRng.new(42)
logos = [] of BouncingLogo

# Initial logo: starts at (120, 100), moving southeast, Blue BG with Yellow text
logos << BouncingLogo.new(120, 100, 3, 2, 3, 2)

Citrine.main_loop do
  # Check Cross button: spawn a new bouncing logo at random position & direction (max 16)
  if Citrine.button_pressed?(Button::Cross)
    if logos.size < 16
      rx = rng.next_int(40, 400)
      ry = rng.next_int(40, 320)
      dir_choice_x = rng.next_int(0, 1)
      dir_x = (dir_choice_x == 0) ? -3 : 3
      dir_choice_y = rng.next_int(0, 1)
      dir_y = (dir_choice_y == 0) ? -2 : 2
      rt_col = rng.next_int(0, 5)
      rbg_col = (rt_col + rng.next_int(1, 5)) % 6
      logos << BouncingLogo.new(rx, ry, dir_x, dir_y, rt_col, rbg_col)
    end
  end

  # Check Triangle button: delete all logos except for the first one
  if Citrine.button_pressed?(Button::Triangle)
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
  Citrine.draw_text("Press CROSS (X) to spawn logo (max 16) | TRIANGLE to reset to 1", 70, 418, 14, Color::Yellow)

  Citrine.end_drawing
end

Citrine.close_window
