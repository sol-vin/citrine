require "citrine"
require "citrine/rng"

# 03 Entity Fibers - Citrine PS2
# Demonstrates: Cooperative multitasking with Citrine Fibers (Citrine.spawn),
# scalable multi-fiber coroutines, dynamic optimal screen-fitting grid layout,
# corner-patrolling entities, dynamic color palette cycling, and centered text metrics.

MAX_ENTITIES = 25

COLORS = [
  Color::Red,
  Color::Orange,
  Color::Yellow,
  Color::Green,
  Color::Blue,
  Color::Purple
]


class Entity
  property box_x : Int32
  property box_y : Int32
  property box_size : Int32
  property dot_x : Int32
  property dot_y : Int32
  property dot_radius : Int32
  property speed : Int32
  property corner : Int32
  property laps : Int32
  property color_idx : Int32

  def initialize(@box_x : Int32, @box_y : Int32, @box_size : Int32, @speed : Int32, @corner : Int32 = 0, @color_idx : Int32 = 0)
    @dot_radius = @box_size // 8
    pad = @dot_radius + 3
    min_x = @box_x + pad
    max_x = @box_x + @box_size - pad
    min_y = @box_y + pad
    max_y = @box_y + @box_size - pad

    case @corner
    when 0 # Move right along top edge (starts top-left)
      @dot_x = min_x
      @dot_y = min_y
    when 1 # Move down along right edge (starts top-right)
      @dot_x = max_x
      @dot_y = min_y
    when 2 # Move left along bottom edge (starts bottom-right)
      @dot_x = max_x
      @dot_y = max_y
    when 3 # Move up along left edge (starts bottom-left)
      @dot_x = min_x
      @dot_y = max_y
    else
      @dot_x = min_x
      @dot_y = min_y
      @corner = 0
    end

    @laps = 0
  end

  def update
    pad = @dot_radius + 3
    min_x = @box_x + pad
    max_x = @box_x + @box_size - pad
    min_y = @box_y + pad
    max_y = @box_y + @box_size - pad

    case @corner
    when 0 # Move right along top edge
      @dot_x += @speed
      if @dot_x >= max_x
        @dot_x = max_x
        @corner = 1
      end
    when 1 # Move down along right edge
      @dot_y += @speed
      if @dot_y >= max_y
        @dot_y = max_y
        @corner = 2
      end
    when 2 # Move left along bottom edge
      @dot_x -= @speed
      if @dot_x <= min_x
        @dot_x = min_x
        @corner = 3
      end
    when 3 # Move up along left edge
      @dot_y -= @speed
      if @dot_y <= min_y
        @dot_y = min_y
        @corner = 0
        @laps += 1
        @color_idx = (@color_idx + 1) % 6
      end
    end
  end
end

Citrine.init_window(640, 448, "03 Entity Fibers - Citrine PS2")
Citrine.set_target_fps(60)

# Optimal Grid Layout Algorithm:
# Determines the optimal (cols, rows) and box_size to square MAX_ENTITIES to screen positions
screen_w = 640
screen_h = 448
margin_x = 16
margin_top = 44
margin_bottom = 12
spacing = 6

avail_w = screen_w - (margin_x * 2)
avail_h = screen_h - margin_top - margin_bottom

# Optimal Grid Layout:
# Squares the number of items to grid positions (e.g. 25 entities -> 5x5 square)
cols = 1
while cols * cols < MAX_ENTITIES
  cols += 1
end
rows = (MAX_ENTITIES + cols - 1) // cols

w_space = avail_w - ((cols - 1) * spacing)
h_space = avail_h - ((rows - 1) * spacing)
cand_w = w_space // cols
cand_h = h_space // rows
box_size = cand_w < cand_h ? cand_w : cand_h

total_grid_w = (cols * box_size) + ((cols - 1) * spacing)
total_grid_h = (rows * box_size) + ((rows - 1) * spacing)

origin_x = (screen_w - total_grid_w) // 2
origin_y = margin_top + (avail_h - total_grid_h) // 2

# Instantiate entities with distinct randomized speeds, starting corners, and colors
entities = [] of Entity
MAX_ENTITIES.times do |i|
  c = i % cols
  r = i // cols
  bx = origin_x + c * (box_size + spacing)
  by = origin_y + r * (box_size + spacing)
  spd = Citrine.rand(1, 4)        # Randomized speeds: 1, 2, 3, or 4 px/frame
  corner = Citrine.rand(0, 3)     # Randomized starting corner (0=top-left, 1=top-right, 2=bottom-right, 3=bottom-left)
  color_idx = Citrine.rand(0, 5)  # Randomized initial color
  entities << Entity.new(bx, by, box_size, spd, corner, color_idx)
end

entities.each do |e|
  Citrine.spawn do
    while true
      e.update
      Citrine.yield
    end
  end
end


Citrine.main_loop do
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(10_u8, 14_u8, 22_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 34, Color::Blue)
  Citrine.draw_rectangle(0, 34, 640, 2, Color::White)
  Citrine.draw_text("25", 312, 9, 16, Color::White)

  # Render each entity box, inner fill, lap counter, and orbiting dot
  entities.each do |e|
    # Outer border
    Citrine.draw_rectangle(e.box_x, e.box_y, e.box_size, e.box_size, Color::White)
    # Inner background fill
    Citrine.draw_rectangle(e.box_x + 1, e.box_y + 1, e.box_size - 2, e.box_size - 2, Color::Black)
    # Centered lap counter
    Citrine.draw_text(e.laps.to_s, e.box_x + (e.box_size // 2) - 4, e.box_y + (e.box_size // 2) - 4, 10, Color::White)
    # Orbiting corner circle dot
    Citrine.draw_circle(e.dot_x, e.dot_y, e.dot_radius, COLORS[e.color_idx])
  end

  Citrine.end_drawing
end

Citrine.close_window
