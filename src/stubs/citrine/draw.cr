# Citrine Processing-Style Creative Coding Graphics & Matrix Stack
# Modular engine abstraction - require "citrine/draw"

require "../citrine"

module Citrine
  module Draw
    @@fill_enabled : Bool = true
    @@fill_color : Color = Color.new(255_u8, 255_u8, 255_u8, 255_u8)
    @@stroke_enabled : Bool = true
    @@stroke_color : Color = Color.new(0_u8, 0_u8, 0_u8, 255_u8)
    @@stroke_weight : Float32 = 1.0_f32

    # 2D Matrix Stack
    struct MatrixState
      property tx : Float32
      property ty : Float32
      property rot : Float32
      property sx : Float32
      property sy : Float32

      def initialize(@tx : Float32 = 0.0_f32, @ty : Float32 = 0.0_f32,
                     @rot : Float32 = 0.0_f32, @sx : Float32 = 1.0_f32, @sy : Float32 = 1.0_f32)
      end
    end

    @@matrix_stack = Array(MatrixState).new(16)
    @@current_matrix = MatrixState.new

    def self.background(color : Color)
      Citrine.clear_background(color)
    end

    def self.fill(color : Color)
      @@fill_enabled = true
      @@fill_color = color
    end

    def self.no_fill
      @@fill_enabled = false
    end

    def self.stroke(color : Color)
      @@stroke_enabled = true
      @@stroke_color = color
    end

    def self.no_stroke
      @@stroke_enabled = false
    end

    def self.stroke_weight(weight : Float32)
      @@stroke_weight = weight
    end

    def self.push_matrix
      @@matrix_stack.push(@@current_matrix)
    end

    def self.pop_matrix
      if @@matrix_stack.size > 0
        @@current_matrix = @@matrix_stack.pop
      end
    end

    def self.translate(x : Float32, y : Float32)
      @@current_matrix.tx += x
      @@current_matrix.ty += y
    end

    def self.rotate(deg : Float32)
      @@current_matrix.rot += deg
    end

    def self.scale(sx : Float32, sy : Float32)
      @@current_matrix.sx *= sx
      @@current_matrix.sy *= sy
    end

    # 2D Primitives
    def self.rect(x : Float32, y : Float32, w : Float32, h : Float32)
      tx = x * @@current_matrix.sx + @@current_matrix.tx
      ty = y * @@current_matrix.sy + @@current_matrix.ty
      tw = w * @@current_matrix.sx
      th = h * @@current_matrix.sy

      if @@fill_enabled
        Citrine.draw_rectangle(tx.to_i32, ty.to_i32, tw.to_i32, th.to_i32, @@fill_color)
      end

      if @@stroke_enabled
        sw = @@stroke_weight.to_i32
        sw = 1 if sw < 1
        Citrine.draw_rectangle(tx.to_i32, ty.to_i32, tw.to_i32, sw, @@stroke_color)
        Citrine.draw_rectangle(tx.to_i32, (ty + th - sw).to_i32, tw.to_i32, sw, @@stroke_color)
        Citrine.draw_rectangle(tx.to_i32, ty.to_i32, sw, th.to_i32, @@stroke_color)
        Citrine.draw_rectangle((tx + tw - sw).to_i32, ty.to_i32, sw, th.to_i32, @@stroke_color)
      end
    end

    def self.ellipse(cx : Float32, cy : Float32, w : Float32, h : Float32)
      tx = cx * @@current_matrix.sx + @@current_matrix.tx
      ty = cy * @@current_matrix.sy + @@current_matrix.ty
      radius = (w + h) * 0.25_f32 * ((@@current_matrix.sx + @@current_matrix.sy) * 0.5_f32)
      if @@fill_enabled
        Citrine.draw_circle(tx.to_i32, ty.to_i32, radius, @@fill_color)
      end
    end

    def self.circle(cx : Float32, cy : Float32, r : Float32)
      ellipse(cx, cy, r * 2.0_f32, r * 2.0_f32)
    end

    def self.line(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32)
      col = @@stroke_enabled ? @@stroke_color : @@fill_color
      tx1 = (x1 * @@current_matrix.sx + @@current_matrix.tx).to_i32
      ty1 = (y1 * @@current_matrix.sy + @@current_matrix.ty).to_i32
      tx2 = (x2 * @@current_matrix.sx + @@current_matrix.tx).to_i32
      ty2 = (y2 * @@current_matrix.sy + @@current_matrix.ty).to_i32
      Citrine.draw_line(tx1, ty1, tx2, ty2, col)
    end

    def self.point(x : Float32, y : Float32)
      col = @@stroke_enabled ? @@stroke_color : @@fill_color
      sw = @@stroke_weight.to_i32
      sw = 1 if sw < 1
      tx = (x * @@current_matrix.sx + @@current_matrix.tx).to_i32
      ty = (y * @@current_matrix.sy + @@current_matrix.ty).to_i32
      Citrine.draw_rectangle(tx, ty, sw, sw, col)
    end

    def self.triangle(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32, x3 : Float32, y3 : Float32)
      if @@fill_enabled
        Citrine.draw_triangle(Vector2.new(x1, y1), Vector2.new(x2, y2), Vector2.new(x3, y3), @@fill_color)
      end
    end

    def self.quad(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32, x3 : Float32, y3 : Float32, x4 : Float32, y4 : Float32)
      if @@fill_enabled
        # Granular decomposition: quad decomposes into two triangles
        triangle(x1, y1, x2, y2, x3, y3)
        triangle(x1, y1, x3, y3, x4, y4)
      end
      if @@stroke_enabled
        line(x1, y1, x2, y2)
        line(x2, y2, x3, y3)
        line(x3, y3, x4, y4)
        line(x4, y4, x1, y1)
      end
    end

    # 3D Primitives
    def self.box(x : Float32, y : Float32, z : Float32, w : Float32, h : Float32, d : Float32, color : Color? = nil)
      col = color || @@fill_color
      Citrine.draw_cube(Vector3.new(x, y, z), w, h, d, col)
    end

    def self.sphere(x : Float32, y : Float32, z : Float32, radius : Float32, color : Color? = nil)
      col = color || @@fill_color
      Citrine.draw_cube(Vector3.new(x, y, z), radius * 1.5_f32, radius * 1.5_f32, radius * 1.5_f32, col)
    end
  end
end
