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

struct Vector3
  property x : Float32
  property y : Float32
  property z : Float32

  def initialize(@x : Float32, @y : Float32, @z : Float32)
  end

  def initialize(x : Number, y : Number, z : Number)
    @x = x.to_f32
    @y = y.to_f32
    @z = z.to_f32
  end
end

struct Camera3D
  property position : Vector3
  property target : Vector3
  property up : Vector3
  property fovy : Float32
  property projection : Int32

  def initialize(@position : Vector3, @target : Vector3, @up : Vector3 = Vector3.new(0.0, 1.0, 0.0), @fovy : Float32 = 45.0_f32, @projection : Int32 = 0)
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

def spawn(&block) : Citrine::Fiber
  Citrine.spawn(&block)
end

def sleep(seconds : Number)
  Citrine.sleep(seconds)
end

def debug_puts(msg : String)
  Citrine.debug_puts(msg)
end

def debug_log(msg : String)
  Citrine.debug_log(msg)
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

  def self.draw_quad(x1 : Number, y1 : Number, x2 : Number, y2 : Number, x3 : Number, y3 : Number, x4 : Number, y4 : Number, color : Color)
    # Granular decomposition: quad decomposes into two triangles
    draw_triangle(x1, y1, x2, y2, x3, y3, color)
    draw_triangle(x1, y1, x3, y3, x4, y4, color)
  end

  def self.draw_text(text : String, x : Number, y : Number, font_size : Int32, color : Color)
  end

  # 3D Graphics
  def self.begin_mode_3d(camera : Camera3D)
  end

  def self.begin_mode_3d
  end

  def self.end_mode_3d
  end

  def self.draw_cube(x : Number, y : Number, z : Number, width : Number, height : Number, length : Number, color : Color)
  end

  def self.draw_cube_wires(x : Number, y : Number, z : Number, width : Number, height : Number, length : Number, color : Color)
  end

  def self.draw_grid(slices : Int32, spacing : Number)
  end

  def self.draw_mesh(mesh_id : UInt32, x : Number, y : Number, z : Number, tint : Color = Color::White)
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

  # Video (IPU MPEG-2 / PSS)
  def self.load_video(path : String) : UInt32
    1_u32
  end

  def self.play_video(video_id : UInt32, loop : Bool = false) : Bool
    true
  end

  def self.draw_video_frame(video_id : UInt32, x : Number, y : Number, width : Number, height : Number)
  end

  def self.video_finished?(video_id : UInt32) : Bool
    false
  end

  def self.pause_video(video_id : UInt32)
  end

  def self.stop_video(video_id : UInt32)
  end

  # Coroutines & Concurrency
  # Fiber Class
  class Fiber
    property id : UInt32

    def initialize(@id : UInt32 = 0_u32)
    end

    def self.yield
      Citrine.yield
    end

    def self.current_id : UInt32
      Citrine.fiber_id
    end

    def self.alive?(id : UInt32) : Bool
      Citrine.fiber_alive?(id)
    end

    def alive? : Bool
      Citrine.fiber_alive?(@id)
    end

    def resume
    end
  end

  def self.spawn(&block) : Citrine::Fiber
    Citrine::Fiber.new(1_u32)
  end

  def self.yield
  end

  def self.sleep(seconds : Number)
  end

  def self.fiber_id : UInt32
    0_u32
  end

  def self.fiber_alive?(id : UInt32) : Bool
    true
  end

  # Channel Native Primitives & Citrine::Channel Class
  class Channel(T)
    getter capacity : Int32
    getter handle : UInt32

    def initialize(@capacity : Int32 = 32)
      @handle = Citrine.channel_new(@capacity)
    end

    def send(value : T) : Bool
      Citrine.channel_send(@handle, value)
    end

    def receive : T?
      Citrine.channel_receive(@handle).as?(T)
    end

    def try_receive : T?
      Citrine.channel_try_receive(@handle).as?(T)
    end

    def size : Int32
      Citrine.channel_count(@handle)
    end

    def count : Int32
      size
    end

    def empty? : Bool
      size == 0
    end

    def full? : Bool
      size >= @capacity
    end
  end

  def self.channel_new(capacity : Int32 = 32) : UInt32
    1_u32
  end

  def self.channel_send(handle : UInt32, value) : Bool
    true
  end

  def self.channel_receive(handle : UInt32)
    nil
  end

  def self.channel_try_receive(handle : UInt32)
    nil
  end

  def self.channel_count(handle : UInt32) : Int32
    0
  end

  def self.channel_capacity(handle : UInt32) : Int32
    32
  end

  # High-level Concurrency Helpers
  module Concurrency
    class WorkerPool(T)
      getter in_channel : Citrine::Channel(T)
      getter worker_fibers : Array(Citrine::Fiber)

      def initialize(worker_count : Int32, capacity : Int32 = 32, &block : T -> Nil)
        @in_channel = Citrine::Channel(T).new(capacity)
        @worker_fibers = [] of Citrine::Fiber
        worker_count.times do
          fib = Citrine.spawn do
            while true
              if item = @in_channel.receive
                block.call(item)
              else
                Citrine.yield
              end
            end
          end
          @worker_fibers << fib
        end
      end

      def post(item : T) : Bool
        @in_channel.send(item)
      end

      def active_workers : Int32
        @worker_fibers.count(&.alive?)
      end
    end

    def self.fan_out(input_channel : Citrine::Channel(T), worker_count : Int32, &worker_block : T -> Nil) forall T
      worker_count.times do
        Citrine.spawn do
          while true
            if item = input_channel.receive
              worker_block.call(item)
            else
              Citrine.yield
            end
          end
        end
      end
    end

    def self.broadcast(channels : Array(Citrine::Channel(T)), value : T) forall T
      channels.each do |ch|
        ch.send(value)
      end
    end
  end

  # Diagnostics & Safety
  def self.debug_overlay=(enabled : Bool)
  end

  def self.log(msg : String)
    puts msg
  end

  def self.print(msg : String)
    puts msg
  end

  def self.puts(msg : String)
    puts msg
  end

  def self.debug_puts(msg : String)
    puts msg
  end

  def self.debug_log(msg : String)
    puts msg
  end

  def self.panic(msg : String)
    raise msg
  end
end
