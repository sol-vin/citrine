# Citrine 2D & 3D Camera Helpers
# Modular engine abstraction - require "citrine/camera"

# Represents a 2D camera with target positioning, screen offset, zoom, and rotation
# designed for PlayStation 2 Graphics Synthesizer rendering.
struct Camera2D
  # Target X coordinate in world space that the camera focuses on.
  property target_x : Float32

  # Target Y coordinate in world space that the camera focuses on.
  property target_y : Float32

  # Screen-space anchor X coordinate (defaults to 320.0 for PS2 NTSC screen center).
  property offset_x : Float32

  # Screen-space anchor Y coordinate (defaults to 224.0 for PS2 NTSC screen center).
  property offset_y : Float32

  # Zoom scale factor (1.0 = 100% scale).
  property zoom : Float32

  # Rotation angle in radians around the target point.
  property rotation : Float32

  # Creates a new `Camera2D` instance with default centering for 640x448 NTSC framebuffers.
  def initialize(
    @target_x : Float32 = 0.0_f32,
    @target_y : Float32 = 0.0_f32,
    @offset_x : Float32 = 320.0_f32,
    @offset_y : Float32 = 224.0_f32,
    @zoom : Float32 = 1.0_f32,
    @rotation : Float32 = 0.0_f32
  )
  end

  # Transforms a world X coordinate to screen space based on target, zoom, and offset.
  def world_to_screen_x(wx : Float32) : Float32
    (wx - @target_x) * @zoom + @offset_x
  end

  # Transforms a world Y coordinate to screen space based on target, zoom, and offset.
  def world_to_screen_y(wy : Float32) : Float32
    (wy - @target_y) * @zoom + @offset_y
  end

  # Transforms a screen X coordinate back to world coordinates.
  def screen_to_world_x(sx : Float32) : Float32
    (sx - @offset_x) / @zoom + @target_x
  end

  # Transforms a screen Y coordinate back to world coordinates.
  def screen_to_world_y(sy : Float32) : Float32
    (sy - @offset_y) / @zoom + @target_y
  end

  # Smoothly tracks a target position `(px, py)` using linear interpolation.
  #
  # Parameters:
  # - `px`: Target X world coordinate.
  # - `py`: Target Y world coordinate.
  # - `lerp_speed`: Interpolation rate per frame (0.0 = static, 1.0 = instantaneous).
  def follow(px : Float32, py : Float32, lerp_speed : Float32 = 0.1_f32)
    @target_x += (px - @target_x) * lerp_speed
    @target_y += (py - @target_y) * lerp_speed
  end

  # Applies a pseudo-random deterministic screen shake offset.
  #
  # Parameters:
  # - `amount`: Intensity multiplier for the shake displacement.
  def screen_shake(amount : Float32)
    # Simple deterministic offset based on target coordinates
    shake_x = ((@target_x.to_i32 % 7) - 3).to_f32 * amount
    shake_y = ((@target_y.to_i32 % 5) - 2).to_f32 * amount
    @offset_x += shake_x
    @offset_y += shake_y
  end
end
