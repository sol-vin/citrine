# Citrine Core Stubs and Native API Definitions for PlayStation 2 EE Runtime
# Modular engine abstraction - require "citrine"

# 2D mathematical vector with single-precision floating point coordinates.
struct Vector2
  # Horizontal coordinate.
  property x : Float32
  # Vertical coordinate.
  property y : Float32

  # Creates a 2D vector from single-precision floats.
  def initialize(@x : Float32, @y : Float32)
  end

  # Creates a 2D vector converting arbitrary numeric types to Float32.
  def initialize(x : Number, y : Number)
    @x = x.to_f32
    @y = y.to_f32
  end

  # Adds two 2D vectors component-wise.
  def +(other : Vector2) : Vector2
    Vector2.new(@x + other.x, @y + other.y)
  end

  # Subtracts two 2D vectors component-wise.
  def -(other : Vector2) : Vector2
    Vector2.new(@x - other.x, @y - other.y)
  end

  # Scales 2D vector by numeric scalar.
  def *(scalar : Number) : Vector2
    Vector2.new(@x * scalar.to_f32, @y * scalar.to_f32)
  end
end

# 3D mathematical vector with single-precision floating point coordinates.
struct Vector3
  # X coordinate.
  property x : Float32
  # Y coordinate.
  property y : Float32
  # Z coordinate.
  property z : Float32

  # Creates a 3D vector from single-precision floats.
  def initialize(@x : Float32, @y : Float32, @z : Float32)
  end

  # Creates a 3D vector converting arbitrary numeric types to Float32.
  def initialize(x : Number, y : Number, z : Number)
    @x = x.to_f32
    @y = y.to_f32
    @z = z.to_f32
  end
end

# 3D Camera descriptor for Graphics Synthesizer perspective rendering.
struct Camera3D
  # Eye position in 3D world space.
  property position : Vector3
  # Point the camera is focused on in 3D space.
  property target : Vector3
  # Up vector defining roll orientation (typically (0, 1, 0)).
  property up : Vector3
  # Field of view along Y axis in degrees.
  property fovy : Float32
  # Projection type: 0 for Perspective, 1 for Orthographic.
  property projection : Int32

  # Creates a 3D camera with target and optional orientation parameters.
  def initialize(@position : Vector3, @target : Vector3, @up : Vector3 = Vector3.new(0.0, 1.0, 0.0), @fovy : Float32 = 45.0_f32, @projection : Int32 = 0)
  end
end

# 32-bit RGBA color representation matching GS PSMCT32 pixel format.
struct Color
  # Red channel component (0-255).
  property r : UInt8
  # Green channel component (0-255).
  property g : UInt8
  # Blue channel component (0-255).
  property b : UInt8
  # Alpha opacity component (0 = transparent, 255 = fully opaque).
  property a : UInt8

  # Creates a color with 8-bit unsigned integer channels.
  def initialize(@r : UInt8, @g : UInt8, @b : UInt8, @a : UInt8 = 255_u8)
  end

  # Creates a color converting arbitrary integer types to UInt8.
  def initialize(r : Int, g : Int, b : Int, a : Int = 255)
    @r = r.to_u8
    @g = g.to_u8
    @b = b.to_u8
    @a = a.to_u8
  end

  # Standard predefined colors.
  White   = Color.new(255, 255, 255, 255)
  Black   = Color.new(0, 0, 0, 255)
  Red     = Color.new(255, 0, 0, 255)
  Green   = Color.new(0, 255, 0, 255)
  Blue    = Color.new(0, 0, 255, 255)
  Yellow  = Color.new(255, 255, 0, 255)
  Cyan    = Color.new(0, 255, 255, 255)
  Magenta = Color.new(255, 0, 255, 255)
  Gray      = Color.new(128, 128, 128, 255)
  DarkGray  = Color.new(80, 80, 80, 255)
  LightGray = Color.new(200, 200, 200, 255)
  Orange    = Color.new(255, 165, 0, 255)
  Purple    = Color.new(128, 0, 128, 255)
end

# Physical DualShock 2 controller button enumeration on PlayStation 2.
enum Button : UInt8
  # DualShock Select button.
  Select   =  0
  # Left analog stick click.
  L3       =  1
  # Right analog stick click.
  R3       =  2
  # DualShock Start button.
  Start    =  3
  # D-Pad Up button.
  Up       =  4
  # D-Pad Right button.
  Right    =  5
  # D-Pad Down button.
  Down     =  6
  # D-Pad Left button.
  Left     =  7
  # Left lower trigger button (L2).
  L2       =  8
  # Right lower trigger button (R2).
  R2       =  9
  # Left upper shoulder button (L1).
  L1       = 10
  # Right upper shoulder button (R1).
  R1       = 11
  # Geometric Triangle button.
  Triangle = 12
  # Geometric Circle button.
  Circle   = 13
  # Geometric Cross (X) button.
  Cross    = 14
  # Geometric Square button.
  Square   = 15
end

# Controller port / player selection on PlayStation 2.
enum Port : UInt8
  # Physical controller port 1 on the console.
  Port1   = 0
  # Physical controller port 2 on the console.
  Port2   = 1
  # Player 1 controller (Port 1).
  Player1 = 0
  # Player 2 controller (Port 2).
  Player2 = 1

  # Returns the 0-indexed port index (0 or 1).
  def index : Int32
    self.value.to_i32
  end
end

# Controller handle providing ergonomic object-oriented button and stick queries for a specific port.
#
# ### Example:
# ```crystal
# p1 = Citrine.player(0)
# p2 = Citrine.player(1)
#
# if p1.button_pressed?(Button::Cross)
#   # Player 1 action
# end
# ```
struct Controller
  # The physical controller port associated with this controller handle.
  getter port : Port

  # Initializes a controller handle for the specified port (0 = Port 1, 1 = Port 2).
  def initialize(port : Port | Int32)
    @port = port.is_a?(Port) ? port : (port == 1 ? Port::Port2 : Port::Port1)
  end

  # Returns true if the specified button is currently held down on this controller port.
  def button_down?(button : Button) : Bool
    Citrine.button_down?(@port, button)
  end

  # Returns true if the specified button was pressed on this controller port during the current frame (rising edge).
  def button_pressed?(button : Button) : Bool
    Citrine.button_pressed?(@port, button)
  end

  # Returns true if the specified button was released on this controller port during the current frame (falling edge).
  def button_released?(button : Button) : Bool
    Citrine.button_released?(@port, button)
  end

  # Returns the horizontal analog stick value (-1.0 to 1.0).
  def analog_x : Float32
    Citrine.get_analog(@port, 0)
  end

  # Returns the vertical analog stick value (-1.0 to 1.0).
  def analog_y : Float32
    Citrine.get_analog(@port, 1)
  end

  # Returns the left analog stick horizontal axis (-1.0 to 1.0).
  def left_stick_x : Float32
    analog_x
  end

  # Returns the left analog stick vertical axis (-1.0 to 1.0).
  def left_stick_y : Float32
    analog_y
  end

  # Returns the right analog stick horizontal axis (-1.0 to 1.0).
  def right_stick_x : Float32
    Citrine.get_analog(@port, 2)
  end

  # Returns the right analog stick vertical axis (-1.0 to 1.0).
  def right_stick_y : Float32
    Citrine.get_analog(@port, 3)
  end

  # Sets the vibration rumble motors for this controller port.
  def rumble(small : UInt8, large : UInt8) : Nil
    Citrine.set_rumble(@port, small, large)
  end
end

# Texture handle referencing image data loaded in Graphics Synthesizer VRAM.
struct Texture
  # Hardware texture allocation handle ID.
  getter handle : UInt32
  # Texture width in pixels.
  getter width : Int32
  # Texture height in pixels.
  getter height : Int32

  # Creates a Texture wrapper with given GPU handle and dimensions.
  def initialize(@handle : UInt32, @width : Int32, @height : Int32)
  end

  # Loads an image file from optical disc or host filesystem and returns a `Texture`.
  def self.load(path : String) : Texture
    Texture.new(Citrine.load_texture(path), 64, 64)
  end
end

# Prints diagnostic string `msg` to EE SIO / SIF console.
def debug_puts(msg : String)
  Citrine.debug_puts(msg)
end

# Logs formatted diagnostic string `msg` to developer console.
def debug_log(msg : String)
  Citrine.debug_log(msg)
end

# Core Citrine runtime module exposing display, rendering, input, audio, video,
# coroutine fibers, channels, and diagnostic facilities.
module Citrine
  # =========================================================================
  # Display & Window Management
  # =========================================================================

  # Initializes the display context, video mode (NTSC/PAL), and backbuffer with dimensions `(width, height)`.
  def self.init_window(width : Int32, height : Int32, title : String)
  end

  # Shuts down display output and releases GS framebuffer allocations.
  def self.close_window
  end

  # Returns true if the display output context remains open and active.
  def self.window_open? : Bool
    true
  end

  # Sets the target frames-per-second limiter (e.g. 60 for NTSC, 50 for PAL).
  def self.set_target_fps(fps : Int32)
  end

  # Returns current measured frame rate in frames per second.
  def self.get_fps : Float32
    60.0_f32
  end

  # Returns elapsed time since previous frame step in seconds.
  def self.get_delta_time : Float32
    0.016667_f32
  end

  # Main game loop executing `block` repeatedly while the display window is open.
  def self.main_loop(&block)
    while window_open?
      yield
    end
  end

  # =========================================================================
  # 2D Rendering
  # =========================================================================

  # Prepares the Graphics Synthesizer packet buffer for frame draw calls.
  def self.begin_drawing
  end

  # Finalizes current frame rendering, dispatches DMA GIF packets, and swaps framebuffers.
  def self.end_drawing
  end

  # Clears the active backbuffer with specified solid `color`.
  def self.clear_background(color : Color)
  end

  # Draws a 2D solid filled rectangle with upper-left corner at `(x, y)` and size `(width, height)`.
  def self.draw_rectangle(x : Number, y : Number, width : Number, height : Number, color : Color)
  end

  # Draws a 2D filled circle centered at `(cx, cy)` with radius `radius`.
  def self.draw_circle(cx : Number, cy : Number, radius : Number, color : Color)
  end

  # Draws a 2D line segment between `(x1, y1)` and `(x2, y2)`.
  def self.draw_line(x1 : Number, y1 : Number, x2 : Number, y2 : Number, color : Color)
  end

  # Draws a 2D filled triangle connecting vertices `(x1, y1)`, `(x2, y2)`, and `(x3, y3)`.
  def self.draw_triangle(x1 : Number, y1 : Number, x2 : Number, y2 : Number, x3 : Number, y3 : Number, color : Color)
  end

  # Draws a 2D filled quadrilateral defined by 4 vertices, automatically decomposed into two triangles.
  def self.draw_quad(x1 : Number, y1 : Number, x2 : Number, y2 : Number, x3 : Number, y3 : Number, x4 : Number, y4 : Number, color : Color)
    # Granular decomposition: quad decomposes into two triangles
    draw_triangle(x1, y1, x2, y2, x3, y3, color)
    draw_triangle(x1, y1, x3, y3, x4, y4, color)
  end

  # Renders text string `text` at position `(x, y)` with size `font_size` and `color`.
  def self.draw_text(text : String, x : Number, y : Number, font_size : Int32, color : Color)
  end

  # =========================================================================
  # 3D Graphics
  # =========================================================================

  # Begins 3D perspective rendering mode using the camera setup from `camera`.
  def self.begin_mode_3d(camera : Camera3D)
  end

  # Begins 3D perspective rendering mode with default camera.
  def self.begin_mode_3d
  end

  # Ends 3D rendering mode and restores 2D orthographic screen space coordinate projection.
  def self.end_mode_3d
  end

  # Renders a 3D solid cube at position `(x, y, z)` with dimensions `(width, height, length)`.
  def self.draw_cube(x : Number, y : Number, z : Number, width : Number, height : Number, length : Number, color : Color)
  end

  # Renders a 3D wireframe cube outline at position `(x, y, z)`.
  def self.draw_cube_wires(x : Number, y : Number, z : Number, width : Number, height : Number, length : Number, color : Color)
  end

  # Renders a 3D ground plane grid with `slices` lines spaced `spacing` units apart.
  def self.draw_grid(slices : Int32, spacing : Number)
  end

  # Renders a 3D mesh resource identified by `mesh_id` at `(x, y, z)`.
  def self.draw_mesh(mesh_id : UInt32, x : Number, y : Number, z : Number, tint : Color = Color::White)
  end

  # =========================================================================
  # Textures
  # =========================================================================

  # Loads an image file into GS VRAM and returns a numeric texture handle.
  def self.load_texture(path : String) : UInt32
    1_u32
  end

  # Draws full texture at position `(x, y)` with color `tint`.
  def self.draw_texture(texture : Texture | UInt32, x : Number, y : Number, tint : Color = Color::White)
  end

  # Draws a cropped region `(src_x, src_y, src_w, src_h)` of `texture` to destination `(dest_x, dest_y)`.
  def self.draw_texture_rec(texture : Texture | UInt32, src_x : Number, src_y : Number, src_w : Number, src_h : Number, dest_x : Number, dest_y : Number, tint : Color = Color::White)
  end

  # Unloads texture from GS VRAM.
  def self.unload_texture(texture : Texture | UInt32)
  end

  # =========================================================================
  # DualShock 2 Controller Subsystem
  # =========================================================================

  # Returns true if the specified `button` is currently held down on the given controller `port`.
  #
  # Parameters:
  # - `port`: Controller port index (0 for Player 1 / Port 1, 1 for Player 2 / Port 2).
  # - `button`: DualShock 2 physical button (e.g. `Button::Cross`).
  #
  # Example:
  # ```crystal
  # if Citrine.button_down?(0, Button::Right)
  #   player_x += 5
  # end
  # ```
  def self.button_down?(port : Int32 | Port, button : ::Button | Citrine::Button | PadButton | Int32) : Bool
    p = port.is_a?(Port) ? port.index : port
    Citrine::Hardware::VirtualPad.button_down?(p, button)
  end

  # Returns true if the specified `button` was pressed on the given controller `port`
  # during the current frame (rising edge transition from released to pressed).
  #
  # Parameters:
  # - `port`: Controller port index (0 for Player 1 / Port 1, 1 for Player 2 / Port 2).
  # - `button`: DualShock 2 physical button (e.g. `Button::Cross`).
  #
  # Example:
  # ```crystal
  # if Citrine.button_pressed?(0, Button::Cross)
  #   jump
  # end
  # ```
  def self.button_pressed?(port : Int32 | Port, button : ::Button | Citrine::Button | PadButton | Int32) : Bool
    p = port.is_a?(Port) ? port.index : port
    Citrine::Hardware::VirtualPad.button_pressed?(p, button)
  end

  # Returns true if the specified `button` was released on the given controller `port`
  # during the current frame (falling edge transition from pressed to released).
  #
  # Parameters:
  # - `port`: Controller port index (0 for Player 1 / Port 1, 1 for Player 2 / Port 2).
  # - `button`: DualShock 2 physical button (e.g. `Button::Cross`).
  def self.button_released?(port : Int32 | Port, button : ::Button | Citrine::Button | PadButton | Int32) : Bool
    p = port.is_a?(Port) ? port.index : port
    Citrine::Hardware::VirtualPad.button_released?(p, button)
  end

  # Returns the analog stick axis value (-1.0 to 1.0) on the given controller `port`.
  #
  # Parameters:
  # - `port`: Controller port index (0 for Player 1, 1 for Player 2).
  # - `axis`: 0 = Left Stick X, 1 = Left Stick Y, 2 = Right Stick X, 3 = Right Stick Y.
  def self.get_analog(port : Int32 | Port, axis : Int32) : Float32
    p = port.is_a?(Port) ? port.index : port
    Citrine::Hardware::VirtualPad.get_analog(p, axis)
  end

  # Sets the vibration rumble motors for the specified controller `port`.
  #
  # Parameters:
  # - `port`: Controller port index (0 for Player 1, 1 for Player 2).
  # - `small_motor`: 0 (off) or 1 (on) for the high-frequency vibration motor.
  # - `large_motor`: 0 to 255 for the low-frequency weight motor speed.
  def self.set_rumble(port : Int32 | Port, small_motor : UInt8 | Int32, large_motor : UInt8 | Int32) : Nil
    p = port.is_a?(Port) ? port.index : port
    Citrine::Hardware::VirtualPad.set_rumble(p, small_motor.to_u8, large_motor.to_u8)
  end

  # Returns a high-level `Controller` handle bound to the specified player / controller port.
  #
  # Example:
  # ```crystal
  # p1 = Citrine.player(0)
  # p2 = Citrine.player(1)
  #
  # if p1.button_pressed?(Button::Cross)
  #   p1.rumble(small: 1, large: 128)
  # end
  # ```
  def self.player(port : Int32 | Port) : Controller
    Controller.new(port)
  end

  # Alias for `Citrine.player(port)` returning a `Controller` handle for the given port.
  def self.pad(port : Int32 | Port) : Controller
    Controller.new(port)
  end

  # =========================================================================
  # Audio (SPU2)
  # =========================================================================

  # Loads an ADPCM audio sample into SPU2 sound memory and returns a sound handle ID.
  def self.load_sound(path : String) : UInt32
    1_u32
  end

  # Starts playback of audio sample `sound_id` on an available SPU2 hardware voice channel.
  def self.play_sound(sound_id : UInt32)
  end

  # Stops playback of audio sample `sound_id`.
  def self.stop_sound(sound_id : UInt32)
  end

  # Plays a CD-DA optical audio track (e.g. track 2..99) streaming directly from the disc drive via SPU2.
  def self.play_cdda_track(track : Int32) : Bool
    Citrine::Audio.play_cdda_track(track)
  end

  # Stops CD-DA optical audio streaming.
  def self.stop_cdda : Bool
    Citrine::Audio.stop_cdda
  end

  # Returns 1 if a CD-DA track is currently playing.
  def self.cdda_status : Int32
    Citrine::Audio.cdda_status
  end

  # Sets the master optical CD-DA / SPU2 volume (0-255).
  def self.set_volume(vol : Int32) : Int32
    Citrine::Audio.set_volume(vol)
  end

  # Compile-time / code-first inspection of album track titles from album_metadata.json
  def self.album_track_titles(metadata_path : String = "album_metadata.json") : Array(String)
    [] of String
  end

  def self.load_track_titles(metadata_path : String = "album_metadata.json") : Array(String)
    [] of String
  end

  # Compile-time / code-first inspection of album track durations (seconds)
  def self.album_track_durations(metadata_path : String = "album_metadata.json") : Array(Float32)
    [] of Float32
  end

  def self.load_track_durations(metadata_path : String = "album_metadata.json") : Array(Float32)
    [] of Float32
  end

  # Compile-time inspection of album title
  def self.album_title(metadata_path : String = "album_metadata.json") : String
    ""
  end

  def self.album_name(metadata_path : String = "album_metadata.json") : String
    ""
  end

  # Compile-time inspection of album artist
  def self.album_artist(metadata_path : String = "album_metadata.json") : String
    ""
  end

  # =========================================================================
  # Video (IPU MPEG-2 / PSS)
  # =========================================================================

  # Loads an MPEG-2 / PSS video stream from disc and returns a video stream handle ID.
  def self.load_video(path : String) : UInt32
    1_u32
  end

  # Starts video playback via the hardware IPU DMA pipeline.
  def self.play_video(video_id : UInt32, loop : Bool = false) : Bool
    true
  end

  # Renders the most recently decoded IPU video frame as a textured rectangle on screen.
  def self.draw_video_frame(video_id : UInt32, x : Number, y : Number, width : Number, height : Number)
  end

  # Returns true if video stream playback has reached the end of stream.
  def self.video_finished?(video_id : UInt32) : Bool
    false
  end

  # Pauses video stream decoding and playback.
  def self.pause_video(video_id : UInt32)
  end

  # Stops video stream playback and resets decoder position.
  def self.stop_video(video_id : UInt32)
  end

  # =========================================================================
  # Coroutines & Concurrency
  # =========================================================================

  # Lightweight coroutine fiber abstraction executing cooperatively on the EE MIPS processor.
  class Fiber
    # Unique 32-bit fiber identification number.
    property id : UInt32
    # Execution liveness state of the fiber.
    property alive : Bool

    # Creates a Fiber instance with given ID.
    def initialize(@id : UInt32 = 0_u32)
      @alive = true
    end

    # Cooperatively relinquishes CPU execution to allow other fibers to run.
    def self.yield
      Citrine.yield
    end

    # Returns the Fiber ID of the currently executing fiber.
    def self.current_id : UInt32
      Citrine.fiber_id
    end

    # Returns true if the fiber identified by `id` is active and alive.
    def self.alive?(id : UInt32) : Bool
      Citrine.fiber_alive?(id)
    end

    # Returns true if this fiber instance is still alive.
    def alive? : Bool
      @alive && Citrine.fiber_alive?(@id)
    end

    # Resumes paused execution of this fiber.
    def resume
    end
  end

  @@fiber_counter : UInt32 = 1_u32
  @@fiber_ids = Hash(::Fiber, UInt32).new
  @@active_fiber_ids = Set(UInt32).new([0_u32])

  # Spawns a new concurrent cooperative fiber executing `block`.
  def self.spawn(&block : -> Nil) : Citrine::Fiber
    fid = @@fiber_counter
    @@fiber_counter &+= 1
    @@active_fiber_ids.add(fid)
    fib_obj = Citrine::Fiber.new(fid)
    ::spawn do
      cur = ::Fiber.current
      @@fiber_ids[cur] = fid
      begin
        block.call
      ensure
        fib_obj.alive = false
        @@active_fiber_ids.delete(fid)
        @@fiber_ids.delete(cur)
      end
    end
    fib_obj
  end

  # Relinquishes the current fiber's execution slice.
  def self.yield
    ::Fiber.yield
  end

  # Suspends execution for `seconds` duration.
  def self.sleep(seconds : Number)
    ::sleep(seconds.seconds)
  end

  # Returns the unique 32-bit ID of the calling fiber.
  def self.fiber_id : UInt32
    @@fiber_ids[::Fiber.current]? || 0_u32
  end

  # Returns true if the fiber identified by `id` is alive.
  def self.fiber_alive?(id : UInt32) : Bool
    @@active_fiber_ids.includes?(id)
  end

  # =========================================================================
  # Channel Native Primitives & Citrine::Channel Class
  # =========================================================================

  # Typed FIFO synchronization channel for message passing between fibers.
  class Channel(T)
    # Maximum number of elements the channel can buffer before senders yield.
    getter capacity : Int32
    # Internal native runtime channel handle ID.
    getter handle : UInt32
    @queue : Deque(T)
    @closed : Bool

    # Creates a channel with the given buffer `capacity`.
    def initialize(@capacity : Int32 = 32)
      @handle = Citrine.channel_new(@capacity)
      @queue = Deque(T).new(@capacity)
      @closed = false
    end

    # Sends `value` into the channel. If full, cooperatively yields until space is available.
    def send(value : T) : Bool
      return false if @closed
      yields = 0
      while full?
        Citrine.yield
        yields += 1
        return false if @closed || yields > 10_000
      end
      @queue.push(value)
      Citrine.channel_send(@handle, value)
      true
    end

    # Attempts to send `value` without blocking. Returns true if queued, false if full or closed.
    def try_send(value : T) : Bool
      return false if @closed || full?
      @queue.push(value)
      Citrine.channel_send(@handle, value)
      true
    end

    # Receives next item from the channel, cooperatively yielding until an item is ready.
    def receive : T?
      yields = 0
      while empty?
        return nil if @closed
        Citrine.yield
        yields += 1
        return nil if yields > 10_000
      end
      @queue.shift?
    end

    # Attempts to receive next item without blocking. Returns item or `nil` if empty.
    def try_receive : T?
      @queue.shift?
    end

    # Returns number of items currently buffered in the channel.
    def size : Int32
      @queue.size
    end

    # Alias for `size`.
    def count : Int32
      size
    end

    # Returns true if channel contains 0 buffered items.
    def empty? : Bool
      @queue.empty?
    end

    # Returns true if channel buffer is at capacity.
    def full? : Bool
      @queue.size >= @capacity
    end

    # Returns true if channel has been closed.
    def closed? : Bool
      @closed
    end

    # Closes channel, waking pending receivers.
    def close
      @closed = true
    end
  end

  # Native runtime hook creating a new channel buffer with `capacity`.
  def self.channel_new(capacity : Int32 = 32) : UInt32
    1_u32
  end

  # Native runtime hook sending value to channel `handle`.
  def self.channel_send(handle : UInt32, value) : Bool
    true
  end

  # Native runtime hook receiving value from channel `handle`.
  def self.channel_receive(handle : UInt32)
    nil
  end

  # Native runtime hook attempting non-blocking receive from channel `handle`.
  def self.channel_try_receive(handle : UInt32)
    nil
  end

  # Native runtime hook querying element count in channel `handle`.
  def self.channel_count(handle : UInt32) : Int32
    0
  end

  # Native runtime hook querying buffer capacity in channel `handle`.
  def self.channel_capacity(handle : UInt32) : Int32
    32
  end

  # High-level concurrency helpers for fan-out worker topologies and multicast broadcasts.
  module Concurrency
    # Dispatches incoming items from `input_channel` across `worker_count` background worker fibers.
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

    # Multicasts `value` by sending to every channel in `channels`.
    def self.broadcast(channels : Array(Citrine::Channel(T)), value : T) forall T
      channels.each do |ch|
        ch.send(value)
      end
    end
  end

  # =========================================================================
  # Diagnostics & Safety
  # =========================================================================

  # Enables or disables the on-screen developer diagnostic overlay.
  def self.debug_overlay=(enabled : Bool)
  end

  # Logs informational message `msg`.
  def self.log(msg : String)
    puts msg
  end

  # Prints `msg` without newline.
  def self.print(msg : String)
    puts msg
  end

  # Prints `msg` followed by newline.
  def self.puts(msg : String)
    puts msg
  end

  # Prints `msg` directly to EE SIO UART console.
  def self.debug_puts(msg : String)
    puts msg
  end

  # Formats and emits diagnostic log message `msg`.
  def self.debug_log(msg : String)
    puts msg
  end

  # Executes inline MIPS R5900, COP0, or COP2 assembly instructions directly on the Emotion Engine silicon.
  # Returns integer value from $v0 (register 2) if evaluated in an expression context.
  def self.asm(*instructions) : Int32
    0
  end

  # Hardware CD-DA & SPU2 Audio Streaming Subsystem
  module Audio
    # Plays a CD-DA optical audio track (e.g. track 2..99) streaming directly from the disc drive via SPU2.
    def self.play_cdda_track(track : Int32) : Bool
      Citrine.puts("[CITRINE AUDIO] Playing CD-DA Audio Track #{track} via SPU2")
      true
    end

    # Stops CD-DA optical audio streaming.
    def self.stop_cdda : Bool
      Citrine.puts("[CITRINE AUDIO] Stopped CD-DA Audio Track")
      true
    end

    # Returns 1 if a CD-DA track is currently playing.
    def self.cdda_status : Int32
      1
    end

    # Sets the master CD-DA / SPU2 audio playback volume (0..255).
    def self.set_volume(vol : Int32) : Int32
      Citrine.puts("[CITRINE AUDIO] CD-DA Volume set to #{vol}")
      vol
    end
  end

  # Raises an unrecoverable engine panic with error description `msg`.
  def self.panic(msg : String)
    raise msg
  end
end

# Top-level DSL helper for inline MIPS R5900 assembly.
def asm(*instructions) : Int32
  0
end

require "./citrine/concurrency/select"
require "./citrine/concurrency/wait_group"
require "./citrine/concurrency/mutex"
require "./citrine/concurrency/semaphore"
require "./citrine/concurrency/once"
require "./citrine/concurrency/future"
require "./citrine/concurrency/worker_pool"
require "./citrine/concurrency/pipeline"
require "./citrine/concurrency/scope"
require "./citrine/concurrency/safety"
require "./citrine/hardware/iop"
require "./citrine/hardware/vu0"
require "./citrine/hardware/virtual_pad"
require "./citrine/hardware/gif"

module Citrine
  alias WorkerPool = Citrine::Concurrency::WorkerPool
  alias ComputePool = Citrine::Concurrency::ComputePool
  alias Pipeline = Citrine::Concurrency::Pipeline
  alias Scope = Citrine::Concurrency::Scope
  alias VU0 = Citrine::Hardware::VU0

  module Concurrency
    alias WaitGroup = Citrine::WaitGroup
    alias Mutex = Citrine::Mutex
    alias Semaphore = Citrine::Semaphore
    alias Once = Citrine::Once
    alias Future = Citrine::Future
    alias Promise = Citrine::Promise
    alias SelectBuilder = Citrine::SelectBuilder

    # Module-level alias for `Citrine.select`.
    def self.select(&block : SelectBuilder -> Nil) : Bool
      Citrine.select(&block)
    end
  end
end
