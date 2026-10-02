# Citrine 2D & 3D Camera Helpers
# Modular engine abstraction - require "citrine/camera"

struct Camera2D
  property target_x : Float32
  property target_y : Float32
  property offset_x : Float32
  property offset_y : Float32
  property zoom : Float32
  property rotation : Float32

  def initialize(
    @target_x : Float32 = 0.0_f32,
    @target_y : Float32 = 0.0_f32,
    @offset_x : Float32 = 320.0_f32,
    @offset_y : Float32 = 224.0_f32,
    @zoom : Float32 = 1.0_f32,
    @rotation : Float32 = 0.0_f32
  )
  end

  def world_to_screen_x(wx : Float32) : Float32
    (wx - @target_x) * @zoom + @offset_x
  end

  def world_to_screen_y(wy : Float32) : Float32
    (wy - @target_y) * @zoom + @offset_y
  end

  def screen_to_world_x(sx : Float32) : Float32
    (sx - @offset_x) / @zoom + @target_x
  end

  def screen_to_world_y(sy : Float32) : Float32
    (sy - @offset_y) / @zoom + @target_y
  end

  def follow(px : Float32, py : Float32, lerp_speed : Float32 = 0.1_f32)
    @target_x += (px - @target_x) * lerp_speed
    @target_y += (py - @target_y) * lerp_speed
  end

  def screen_shake(amount : Float32)
    # Simple deterministic offset based on target coordinates
    shake_x = ((@target_x.to_i32 % 7) - 3).to_f32 * amount
    shake_y = ((@target_y.to_i32 % 5) - 2).to_f32 * amount
    @offset_x += shake_x
    @offset_y += shake_y
  end
end
