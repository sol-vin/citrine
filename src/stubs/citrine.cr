struct Vector2
  property x : Float32
  property y : Float32

  def initialize(@x : Float32, @y : Float32)
  end

  def initialize(x : Number, y : Number)
    @x = x.to_f32
    @y = y.to_f32
  end

  def +(other : Vector2) : Vector2
    Vector2.new(@x + other.x, @y + other.y)
  end

  def -(other : Vector2) : Vector2
    Vector2.new(@x - other.x, @y - other.y)
  end

  def *(scalar : Number) : Vector2
    Vector2.new(@x * scalar.to_f32, @y * scalar.to_f32)
  end
end

struct Color
  property r : UInt8
  property g : UInt8
  property b : UInt8
  property a : UInt8

  def initialize(@r : UInt8, @g : UInt8, @b : UInt8, @a : UInt8 = 255_u8)
  end

  def initialize(r : Int, g : Int, b : Int, a : Int = 255)
    @r = r.to_u8
    @g = g.to_u8
    @b = b.to_u8
    @a = a.to_u8
  end

  White  = Color.new(255, 255, 255, 255)
  Black  = Color.new(0, 0, 0, 255)
  Red    = Color.new(255, 0, 0, 255)
  Green  = Color.new(0, 255, 0, 255)
  Blue   = Color.new(0, 0, 255, 255)
  Yellow = Color.new(255, 255, 0, 255)
  Gray   = Color.new(128, 128, 128, 255)
end

enum Button : UInt8
  Select   =  0
  L3       =  1
  R3       =  2
  Start    =  3
  Up       =  4
  Right    =  5
  Down     =  6
  Left     =  7
  L2       =  8
  R2       =  9
  L1       = 10
  R1       = 11
  Triangle = 12
  Circle   = 13
  Cross    = 14
  Square   = 15
end

struct Texture
  getter handle : UInt32
  getter width : Int32
  getter height : Int32

  def initialize(@handle : UInt32, @width : Int32, @height : Int32)
  end

  def self.load(path : String) : Texture
    Texture.new(Citrine.load_texture(path), 64, 64)
  end
end

class Fiber
  property id : UInt32

  def initialize(@id : UInt32)
  end

  def resume
    # Resumes execution in Citrine-VM
  end
end

module Citrine
  # Display & Window Management
  def self.init_window(width : Int32, height : Int32, title : String)
  end

  def self.close_window
  end

  def self.window_open? : Bool
    true
  end

  def self.set_target_fps(fps : Int32)
  end

  def self.get_fps : Float32
    60.0_f32
  end

  def self.get_delta_time : Float32
    0.016667_f32
  end

  def self.main_loop(&block)
    while window_open?
      yield
    end
  end

  # Rendering
  def self.begin_drawing
  end

  def self.end_drawing
  end

  def self.clear_background(color : Color)
  end

  def self.draw_rectangle(x : Number, y : Number, width : Number, height : Number, color : Color)
  end

  def self.draw_circle(cx : Number, cy : Number, radius : Number, color : Color)
  end

  def self.draw_line(x1 : Number, y1 : Number, x2 : Number, y2 : Number, color : Color)
  end

  def self.draw_triangle(x1 : Number, y1 : Number, x2 : Number, y2 : Number, x3 : Number, y3 : Number, color : Color)
  end

  def self.draw_text(text : String, x : Number, y : Number, font_size : Int32, color : Color)
  end

  # Textures
  def self.load_texture(path : String) : UInt32
    1_u32
  end

  def self.draw_texture(texture : Texture | UInt32, x : Number, y : Number, tint : Color = Color::White)
  end

  def self.draw_texture_rec(texture : Texture | UInt32, src_x : Number, src_y : Number, src_w : Number, src_h : Number, dest_x : Number, dest_y : Number, tint : Color = Color::White)
  end

  def self.unload_texture(texture : Texture | UInt32)
  end

  # Input (DualShock 2)
  def self.button_down?(button : Button) : Bool
    false
  end

  def self.button_pressed?(button : Button) : Bool
    false
  end

  def self.button_released?(button : Button) : Bool
    false
  end

  def self.get_analog(axis : Int32) : Float32
    0.0_f32
  end

  def self.set_rumble(small_motor : UInt8, large_motor : UInt8)
  end

  # Audio (SPU2)
  def self.load_sound(path : String) : UInt32
    1_u32
  end

  def self.play_sound(sound_id : UInt32)
  end

  def self.stop_sound(sound_id : UInt32)
  end

  # Coroutines / Fibers
  def self.spawn(&block) : Fiber
    Fiber.new(1_u32)
  end

  def self.yield
  end

  # Diagnostics & Safety
  def self.debug_overlay=(enabled : Bool)
  end

  def self.log(msg : String)
    puts msg
  end

  def self.panic(msg : String)
    raise msg
  end
end
