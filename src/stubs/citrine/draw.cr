# Citrine Processing-Style Creative Coding Graphics & Matrix Stack
# Modular engine abstraction - require "citrine/draw"

require "../citrine"

module Citrine
  # Immediate-mode 2D and 3D drawing API modeled after Processing / p5.js,
  # featuring a transform matrix stack, stroke/fill styling, and primitive rasterization.
  module Draw
    @@fill_enabled : Bool = true
    @@fill_color : Color = Color.new(255_u8, 255_u8, 255_u8, 255_u8)
    @@stroke_enabled : Bool = true
    @@stroke_color : Color = Color.new(0_u8, 0_u8, 0_u8, 255_u8)
    @@stroke_weight : Float32 = 1.0_f32

    # Represents the state of the 2D transformation matrix stack.
    struct MatrixState
      # Translation along X-axis.
      property tx : Float32
      # Translation along Y-axis.
      property ty : Float32
      # Rotation angle in degrees.
      property rot : Float32
      # Scale factor along X-axis.
      property sx : Float32
      # Scale factor along Y-axis.
      property sy : Float32

      # Creates a new matrix transformation state.
      def initialize(@tx : Float32 = 0.0_f32, @ty : Float32 = 0.0_f32,
                     @rot : Float32 = 0.0_f32, @sx : Float32 = 1.0_f32, @sy : Float32 = 1.0_f32)
      end
    end

    @@matrix_stack = Array(MatrixState).new(16)
    @@current_matrix = MatrixState.new

    # Clears the screen buffer with the given background `color`.
    def self.background(color : Color)
      Citrine.clear_background(color)
    end

    # Sets the active fill color for subsequent geometric primitives.
    def self.fill(color : Color)
      @@fill_enabled = true
      @@fill_color = color
    end

    # Disables filling interior areas of geometric primitives.
    def self.no_fill
      @@fill_enabled = false
    end

    # Sets the active outline stroke color for subsequent primitives.
    def self.stroke(color : Color)
      @@stroke_enabled = true
      @@stroke_color = color
    end

    # Disables outline drawing for subsequent primitives.
    def self.no_stroke
      @@stroke_enabled = false
    end

    # Sets the line thickness in pixels for stroked primitives.
    def self.stroke_weight(weight : Float32)
      @@stroke_weight = weight
    end

    # Pushes the current transformation matrix onto the matrix stack.
    def self.push_matrix
      @@matrix_stack.push(@@current_matrix)
    end

    # Restores the previous transformation matrix from the matrix stack.
    def self.pop_matrix
      if @@matrix_stack.size > 0
        @@current_matrix = @@matrix_stack.pop
      end
    end

    # Applies a 2D translation offset to the current transformation matrix.
    def self.translate(x : Float32, y : Float32)
      @@current_matrix.tx += x
      @@current_matrix.ty += y
    end

    # Applies a 2D rotation (in degrees) to the current transformation matrix.
    def self.rotate(deg : Float32)
      @@current_matrix.rot += deg
    end

    # Scales subsequent rendering by `(sx, sy)` factors.
    def self.scale(sx : Float32, sy : Float32)
      @@current_matrix.sx *= sx
      @@current_matrix.sy *= sy
    end

    # Draws a rectangle with upper-left corner at `(x, y)` and size `(w, h)`.
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

    # Draws an ellipse centered at `(cx, cy)` with width `w` and height `h`.
    def self.ellipse(cx : Float32, cy : Float32, w : Float32, h : Float32)
      tx = cx * @@current_matrix.sx + @@current_matrix.tx
      ty = cy * @@current_matrix.sy + @@current_matrix.ty
      radius = (w + h) * 0.25_f32 * ((@@current_matrix.sx + @@current_matrix.sy) * 0.5_f32)
      if @@fill_enabled
        Citrine.draw_circle(tx.to_i32, ty.to_i32, radius, @@fill_color)
      end
    end

    # Draws a circle centered at `(cx, cy)` with radius `r`.
    def self.circle(cx : Float32, cy : Float32, r : Float32)
      ellipse(cx, cy, r * 2.0_f32, r * 2.0_f32)
    end

    # Draws a 2D line segment between `(x1, y1)` and `(x2, y2)`.
    def self.line(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32)
      col = @@stroke_enabled ? @@stroke_color : @@fill_color
      tx1 = (x1 * @@current_matrix.sx + @@current_matrix.tx).to_i32
      ty1 = (y1 * @@current_matrix.sy + @@current_matrix.ty).to_i32
      tx2 = (x2 * @@current_matrix.sx + @@current_matrix.tx).to_i32
      ty2 = (y2 * @@current_matrix.sy + @@current_matrix.ty).to_i32
      Citrine.draw_line(tx1, ty1, tx2, ty2, col)
    end

    # Draws a single pixel or dot at `(x, y)` honoring stroke weight.
    def self.point(x : Float32, y : Float32)
      col = @@stroke_enabled ? @@stroke_color : @@fill_color
      sw = @@stroke_weight.to_i32
      sw = 1 if sw < 1
      tx = (x * @@current_matrix.sx + @@current_matrix.tx).to_i32
      ty = (y * @@current_matrix.sy + @@current_matrix.ty).to_i32
      Citrine.draw_rectangle(tx, ty, sw, sw, col)
    end

    # Draws a filled triangle connecting vertices `(x1, y1)`, `(x2, y2)`, and `(x3, y3)`.
    def self.triangle(x1 : Float32, y1 : Float32, x2 : Float32, y2 : Float32, x3 : Float32, y3 : Float32)
      if @@fill_enabled
        tx1 = (x1 * @@current_matrix.sx + @@current_matrix.tx).to_i32
        ty1 = (y1 * @@current_matrix.sy + @@current_matrix.ty).to_i32
        tx2 = (x2 * @@current_matrix.sx + @@current_matrix.tx).to_i32
        ty2 = (y2 * @@current_matrix.sy + @@current_matrix.ty).to_i32
        tx3 = (x3 * @@current_matrix.sx + @@current_matrix.tx).to_i32
        ty3 = (y3 * @@current_matrix.sy + @@current_matrix.ty).to_i32
        Citrine.draw_triangle(tx1, ty1, tx2, ty2, tx3, ty3, @@fill_color)
      end
    end

    # Draws a quadrilateral defined by four vertices `(x1, y1)` through `(x4, y4)`.
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

    # Draws a 3D box at position `(x, y, z)` with dimensions `(w, h, d)`.
    def self.box(x : Float32, y : Float32, z : Float32, w : Float32, h : Float32, d : Float32, color : Color? = nil)
      col = color || @@fill_color
      Citrine.draw_cube(Vector3.new(x, y, z), w, h, d, col)
    end

    # Draws a 3D sphere placeholder at position `(x, y, z)` with radius `radius`.
    def self.sphere(x : Float32, y : Float32, z : Float32, radius : Float32, color : Color? = nil)
      col = color || @@fill_color
      Citrine.draw_cube(Vector3.new(x, y, z), radius * 1.5_f32, radius * 1.5_f32, radius * 1.5_f32, col)
    end

    # Renders text with optional rotation and alignment.
    def self.text(string : String, x : Number, y : Number, size : Int32 = 16, color : Color = Color::White, rotation : Number = 0.0, origin : Vector2? = nil, align : Symbol = :left)
      Draw2D.text(string, x, y, size: size, color: color, rotation: rotation, origin: origin, align: align)
    end

    # Draws arbitrary polygon.
    def self.polygon(points : Array(Vector2), fill : Color? = nil, stroke : Color? = nil)
      Draw2D.polygon(points, fill: fill, stroke: stroke)
    end

    # Draws regular star.
    def self.star(cx : Number, cy : Number, points : Int32 = 5, inner_r : Number = 10.0, outer_r : Number = 25.0, fill : Color? = nil, stroke : Color? = nil)
      Draw2D.star(cx, cy, points: points, inner_r: inner_r, outer_r: outer_r, fill: fill, stroke: stroke)
    end
  end
end

