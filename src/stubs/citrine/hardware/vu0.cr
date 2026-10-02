# Citrine Vector Unit 0 (VU0) Coprocessor 2 Subsystem
# Modular hardware abstraction - require "citrine/hardware/vu0"

module Citrine
  module Hardware
    module VU0
      def self.dot_product(x1 : Float32, y1 : Float32, z1 : Float32,
                           x2 : Float32, y2 : Float32, z2 : Float32) : Float32
        x1 * x2 + y1 * y2 + z1 * z2
      end

      def self.vector_magnitude_sq(x : Float32, y : Float32, z : Float32) : Float32
        x * x + y * y + z * z
      end

      def self.transform_point(px : Float32, py : Float32, pz : Float32,
                               tx : Float32, ty : Float32, tz : Float32) : Tuple(Float32, Float32, Float32)
        {px + tx, py + ty, pz + tz}
      end
    end
  end
end
