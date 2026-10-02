# Citrine Collision Filtering, Raycasting & Shape Sweeping
# Modular engine abstraction - require "citrine/physics/collision"

require "../../citrine"

module Citrine
  module Collision
    struct Filter
      property layer : UInt16
      property mask : UInt16

      def initialize(@layer : UInt16 = 1_u16, @mask : UInt16 = 0xFFFF_u16)
      end

      def can_collide?(other : Filter) : Bool
        ((@layer & other.mask) != 0) && ((other.layer & @mask) != 0)
      end
    end

    struct Ray2D
      property origin : Vector2
      property direction : Vector2
      property max_distance : Float32

      def initialize(@origin : Vector2, @direction : Vector2, @max_distance : Float32 = 1000.0_f32)
        # Normalize direction
        len = Math.sqrt(@direction.x * @direction.x + @direction.y * @direction.y)
        if len > 0.0_f32
          @direction = Vector2.new(@direction.x / len, @direction.y / len)
        end
      end
    end

    struct RaycastHit2D
      property hit : Bool
      property point : Vector2
      property normal : Vector2
      property distance : Float32

      def initialize(
        @hit : Bool = false,
        @point : Vector2 = Vector2.new(0.0_f32, 0.0_f32),
        @normal : Vector2 = Vector2.new(0.0_f32, 0.0_f32),
        @distance : Float32 = 0.0_f32
      )
      end
    end

    # Fast 2D Ray-AABB slab intersection
    def self.raycast_aabb(ray : Ray2D, rx : Float32, ry : Float32, rw : Float32, rh : Float32) : RaycastHit2D
      inv_dir_x = ray.direction.x.abs > 0.0001_f32 ? (1.0_f32 / ray.direction.x) : 100000.0_f32
      inv_dir_y = ray.direction.y.abs > 0.0001_f32 ? (1.0_f32 / ray.direction.y) : 100000.0_f32

      t1 = (rx - ray.origin.x) * inv_dir_x
      t2 = (rx + rw - ray.origin.x) * inv_dir_x
      t3 = (ry - ray.origin.y) * inv_dir_y
      t4 = (ry + rh - ray.origin.y) * inv_dir_y

      tmin = Math.max(Math.min(t1, t2), Math.min(t3, t4))
      tmax = Math.min(Math.max(t1, t2), Math.max(t3, t4))

      if tmax < 0.0_f32 || tmin > tmax || tmin > ray.max_distance
        return RaycastHit2D.new(hit: false)
      end

      hit_dist = tmin >= 0.0_f32 ? tmin : tmax
      hit_pt = Vector2.new(
        ray.origin.x + ray.direction.x * hit_dist,
        ray.origin.y + ray.direction.y * hit_dist
      )

      # Determine surface normal
      normal = if (hit_pt.x - rx).abs < 0.1_f32
                 Vector2.new(-1.0_f32, 0.0_f32)
               elsif (hit_pt.x - (rx + rw)).abs < 0.1_f32
                 Vector2.new(1.0_f32, 0.0_f32)
               elsif (hit_pt.y - ry).abs < 0.1_f32
                 Vector2.new(0.0_f32, -1.0_f32)
               else
                 Vector2.new(0.0_f32, 1.0_f32)
               end

      RaycastHit2D.new(hit: true, point: hit_pt, normal: normal, distance: hit_dist)
    end

    # Swept Circle ShapeCast against AABB (Continuous Collision Detection)
    def self.shapecast_circle(
      start_pos : Vector2,
      radius : Float32,
      velocity : Vector2,
      rx : Float32, ry : Float32, rw : Float32, rh : Float32
    ) : RaycastHit2D
      # Expand AABB by circle radius (Minkowski Sum)
      expanded_x = rx - radius
      expanded_y = ry - radius
      expanded_w = rw + radius * 2.0_f32
      expanded_h = rh + radius * 2.0_f32

      speed = Math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
      return RaycastHit2D.new(hit: false) if speed <= 0.0_f32

      ray = Ray2D.new(start_pos, velocity, speed)
      raycast_aabb(ray, expanded_x, expanded_y, expanded_w, expanded_h)
    end
  end
end
