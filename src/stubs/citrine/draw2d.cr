# Citrine 2D Graphics DSL & Affine Transformation Pipeline
# Modular engine abstraction - require "citrine/draw2d"

require "../citrine"

module Citrine
  # Advanced 2D Immediate-Mode Graphics DSL featuring an affine transformation matrix stack,
  # arbitrary-pivot rotated primitives, rotated text, rounded rectangles, stroke/fill styling,
  # and zero-allocation frame batching.
  module Draw2D
    # 2D Affine Transformation Matrix (3x2 row-major representation):
    # [ a   c   tx ]
    # [ b   d   ty ]
    # [ 0   0    1 ]
    struct Transform2D
      property a : Float32
      property b : Float32
      property c : Float32
      property d : Float32
      property tx : Float32
      property ty : Float32

      def initialize(
        @a : Float32 = 1.0_f32,
        @b : Float32 = 0.0_f32,
        @c : Float32 = 0.0_f32,
        @d : Float32 = 1.0_f32,
        @tx : Float32 = 0.0_f32,
        @ty : Float32 = 0.0_f32
      )
      end

      # Returns identity affine transform.
      def self.identity : Transform2D
        Transform2D.new(1.0_f32, 0.0_f32, 0.0_f32, 1.0_f32, 0.0_f32, 0.0_f32)
      end

      # Creates a pure translation transform.
      def self.translation(x : Number, y : Number) : Transform2D
        Transform2D.new(1.0_f32, 0.0_f32, 0.0_f32, 1.0_f32, x.to_f32, y.to_f32)
      end

      # Creates a scale transform with optional origin pivot.
      def self.scaling(sx : Number, sy : Number, ox : Number = 0.0, oy : Number = 0.0) : Transform2D
        fsx = sx.to_f32
        fsy = sy.to_f32
        fox = ox.to_f32
        foy = oy.to_f32
        tx = fox - fox * fsx
        ty = foy - foy * fsy
        Transform2D.new(fsx, 0.0_f32, 0.0_f32, fsy, tx, ty)
      end

      # Creates a rotation transform (in degrees) around an arbitrary origin pivot (ox, oy).
      def self.rotation(deg : Number, ox : Number = 0.0, oy : Number = 0.0) : Transform2D
        rad = deg.to_f32 * (Math::PI.to_f32 / 180.0_f32)
        c = Math.cos(rad).to_f32
        s = Math.sin(rad).to_f32
        fox = ox.to_f32
        foy = oy.to_f32
        # T(ox, oy) * R(rad) * T(-ox, -oy)
        tx = fox - fox * c + foy * s
        ty = foy - fox * s - foy * c
        Transform2D.new(c, s, -s, c, tx, ty)
      end

      # Multiplies two affine matrices (`self * other`).
      def *(other : Transform2D) : Transform2D
        Transform2D.new(
          @a * other.a + @c * other.b,
          @b * other.a + @d * other.b,
          @a * other.c + @c * other.d,
          @b * other.c + @d * other.d,
          @a * other.tx + @c * other.ty + @tx,
          @b * other.tx + @d * other.ty + @ty
        )
      end

      # Transforms a point (x, y) by this affine matrix.
      def transform_point(x : Number, y : Number) : Tuple(Float32, Float32)
        fx = x.to_f32
        fy = y.to_f32
        { @a * fx + @c * fy + @tx, @b * fx + @d * fy + @ty }
      end
    end

    # Active styling configuration for Draw2D primitives.
    struct Style
      property fill_enabled : Bool
      property fill_color : Color
      property stroke_enabled : Bool
      property stroke_color : Color
      property stroke_weight : Float32

      def initialize(
        @fill_enabled : Bool = true,
        @fill_color : Color = Color::White,
        @stroke_enabled : Bool = false,
        @stroke_color : Color = Color::Black,
        @stroke_weight : Float32 = 1.0_f32
      )
      end
    end

    @@current_style = Style.new
    @@style_stack = Array(Style).new(16)
    @@current_transform = Transform2D.identity
    @@transform_stack = Array(Transform2D).new(16)

    # =========================================================================
    # Styling DSL
    # =========================================================================

    # Sets active solid fill color.
    def self.fill(color : Color)
      @@current_style.fill_enabled = true
      @@current_style.fill_color = color
    end

    # Disables filling interior of subsequent primitives.
    def self.no_fill
      @@current_style.fill_enabled = false
    end

    # Sets active outline stroke color and optional line weight.
    def self.stroke(color : Color, weight : Number? = nil)
      @@current_style.stroke_enabled = true
      @@current_style.stroke_color = color
      @@current_style.stroke_weight = weight.to_f32 if weight
    end

    # Disables outline drawing for subsequent primitives.
    def self.no_stroke
      @@current_style.stroke_enabled = false
    end

    # Sets active outline stroke line thickness in pixels.
    def self.stroke_weight(weight : Number)
      @@current_style.stroke_weight = weight.to_f32
    end

    # Executes a block with temporary styling, automatically restoring previous style on exit.
    def self.with_style(
      fill : Color? = nil,
      stroke : Color? = nil,
      weight : Number? = nil,
      no_fill : Bool = false,
      no_stroke : Bool = false,
      &block
    )
      @@style_stack.push(@@current_style)
      if no_fill
        @@current_style.fill_enabled = false
      elsif fill
        @@current_style.fill_enabled = true
        @@current_style.fill_color = fill
      end

      if no_stroke
        @@current_style.stroke_enabled = false
      elsif stroke
        @@current_style.stroke_enabled = true
        @@current_style.stroke_color = stroke
      end

      @@current_style.stroke_weight = weight.to_f32 if weight

      begin
        yield
      ensure
        if @@style_stack.size > 0
          @@current_style = @@style_stack.pop
        end
      end
    end

    # =========================================================================
    # Affine Transformation Matrix Stack
    # =========================================================================

    # Pushes active affine transformation matrix onto the stack.
    def self.push_matrix
      @@transform_stack.push(@@current_transform)
    end

    # Restores previous transformation matrix from the stack.
    def self.pop_matrix
      if @@transform_stack.size > 0
        @@current_transform = @@transform_stack.pop
      end
    end

    # Resets the transformation matrix to identity.
    def self.load_identity
      @@current_transform = Transform2D.identity
    end

    # Applies a 2D translation offset.
    def self.translate(x : Number, y : Number)
      @@current_transform = @@current_transform * Transform2D.translation(x, y)
    end

    # Applies a 2D rotation (in degrees) around an optional pivot origin (ox, oy).
    def self.rotate(deg : Number, ox : Number = 0.0, oy : Number = 0.0)
      @@current_transform = @@current_transform * Transform2D.rotation(deg, ox, oy)
    end

    # Applies a 2D scale factor with optional origin pivot.
    def self.scale(sx : Number, sy : Number, ox : Number = 0.0, oy : Number = 0.0)
      @@current_transform = @@current_transform * Transform2D.scaling(sx, sy, ox, oy)
    end

    # Executes a block within a scoped transformation, guaranteed to restore the matrix on exit.
    def self.transform(
      x : Number = 0.0,
      y : Number = 0.0,
      rotation : Number = 0.0,
      scale : Number = 1.0,
      scale_y : Number? = nil,
      origin : Vector2? = nil,
      &block
    )
      push_matrix
      ox = origin ? origin.x : 0.0_f32
      oy = origin ? origin.y : 0.0_f32
      translate(x, y) if x != 0.0 || y != 0.0
      rotate(rotation, ox, oy) if rotation != 0.0
      sy = scale_y || scale
      self.scale(scale, sy, ox, oy) if scale != 1.0 || sy != 1.0
      begin
        yield
      ensure
        pop_matrix
      end
    end

    # Convenience scoped rotation block.
    def self.rotated(deg : Number, origin : Vector2? = nil, &block)
      push_matrix
      ox = origin ? origin.x : 0.0_f32
      oy = origin ? origin.y : 0.0_f32
      rotate(deg, ox, oy)
      begin
        yield
      ensure
        pop_matrix
      end
    end

    # =========================================================================
    # Primitives DSL
    # =========================================================================

    # Clears screen buffer with solid background color.
    def self.clear(color : Color)
      Citrine.clear_background(color)
    end

    # Alias for clear(color) matching Processing conventions.
    def self.background(color : Color)
      clear(color)
    end

    # Draws a 2D line segment between (x1, y1) and (x2, y2).
    def self.line(
      x1 : Number, y1 : Number,
      x2 : Number, y2 : Number,
      color : Color? = nil,
      weight : Number? = nil
    )
      tx1, ty1 = @@current_transform.transform_point(x1, y1)
      tx2, ty2 = @@current_transform.transform_point(x2, y2)
      col = color || (@@current_style.stroke_enabled ? @@current_style.stroke_color : @@current_style.fill_color)
      Citrine.draw_line(tx1.to_i32, ty1.to_i32, tx2.to_i32, ty2.to_i32, col)
    end

    # Draws a triangle between vertices (x1, y1), (x2, y2), (x3, y3).
    def self.triangle(
      x1 : Number, y1 : Number,
      x2 : Number, y2 : Number,
      x3 : Number, y3 : Number,
      fill : Color? = nil,
      stroke : Color? = nil,
      weight : Number? = nil
    )
      tx1, ty1 = @@current_transform.transform_point(x1, y1)
      tx2, ty2 = @@current_transform.transform_point(x2, y2)
      tx3, ty3 = @@current_transform.transform_point(x3, y3)

      f_col = fill || (@@current_style.fill_enabled ? @@current_style.fill_color : nil)
      if f_col
        Citrine.draw_triangle(tx1, ty1, tx2, ty2, tx3, ty3, f_col)
      end

      s_col = stroke || (@@current_style.stroke_enabled ? @@current_style.stroke_color : nil)
      if s_col
        Citrine.draw_line(tx1.to_i32, ty1.to_i32, tx2.to_i32, ty2.to_i32, s_col)
        Citrine.draw_line(tx2.to_i32, ty2.to_i32, tx3.to_i32, ty3.to_i32, s_col)
        Citrine.draw_line(tx3.to_i32, ty3.to_i32, tx1.to_i32, ty1.to_i32, s_col)
      end
    end

    # Draws a quadrilateral defined by four vertices (x1, y1) through (x4, y4).
    def self.quad(
      x1 : Number, y1 : Number,
      x2 : Number, y2 : Number,
      x3 : Number, y3 : Number,
      x4 : Number, y4 : Number,
      fill : Color? = nil,
      stroke : Color? = nil
    )
      tx1, ty1 = @@current_transform.transform_point(x1, y1)
      tx2, ty2 = @@current_transform.transform_point(x2, y2)
      tx3, ty3 = @@current_transform.transform_point(x3, y3)
      tx4, ty4 = @@current_transform.transform_point(x4, y4)

      f_col = fill || (@@current_style.fill_enabled ? @@current_style.fill_color : nil)
      if f_col
        Citrine.draw_triangle(tx1, ty1, tx2, ty2, tx3, ty3, f_col)
        Citrine.draw_triangle(tx1, ty1, tx3, ty3, tx4, ty4, f_col)
      end

      s_col = stroke || (@@current_style.stroke_enabled ? @@current_style.stroke_color : nil)
      if s_col
        Citrine.draw_line(tx1.to_i32, ty1.to_i32, tx2.to_i32, ty2.to_i32, s_col)
        Citrine.draw_line(tx2.to_i32, ty2.to_i32, tx3.to_i32, ty3.to_i32, s_col)
        Citrine.draw_line(tx3.to_i32, ty3.to_i32, tx4.to_i32, ty4.to_i32, s_col)
        Citrine.draw_line(tx4.to_i32, ty4.to_i32, tx1.to_i32, ty1.to_i32, s_col)
      end
    end

    # Draws a rectangle with support for arbitrary rotation, custom pivot origin,
    # rounded corners, and fill/stroke styling.
    def self.rect(
      x : Number, y : Number,
      w : Number, h : Number,
      rotation : Number = 0.0,
      origin : Vector2? = nil,
      radius : Number = 0.0,
      fill : Color? = nil,
      stroke : Color? = nil,
      weight : Number? = nil
    )
      fx = x.to_f32
      fy = y.to_f32
      fw = w.to_f32
      fh = h.to_f32
      frad = radius.to_f32

      f_col = fill || (@@current_style.fill_enabled ? @@current_style.fill_color : nil)
      s_col = stroke || (@@current_style.stroke_enabled ? @@current_style.stroke_color : nil)
      sw = (weight || @@current_style.stroke_weight).to_f32

      if rotation != 0.0 || origin
        # Calculate local transform with rotation around origin
        ox = origin ? origin.x : 0.0_f32
        oy = origin ? origin.y : 0.0_f32
        local_rot = Transform2D.rotation(rotation, ox, oy)
        p0 = @@current_transform.transform_point(*(local_rot.transform_point(fx, fy)))
        p1 = @@current_transform.transform_point(*(local_rot.transform_point(fx + fw, fy)))
        p2 = @@current_transform.transform_point(*(local_rot.transform_point(fx + fw, fy + fh)))
        p3 = @@current_transform.transform_point(*(local_rot.transform_point(fx, fy + fh)))

        if f_col
          Citrine.draw_triangle(p0[0], p0[1], p1[0], p1[1], p2[0], p2[1], f_col)
          Citrine.draw_triangle(p0[0], p0[1], p2[0], p2[1], p3[0], p3[1], f_col)
        end

        if s_col
          Citrine.draw_line(p0[0].to_i32, p0[1].to_i32, p1[0].to_i32, p1[1].to_i32, s_col)
          Citrine.draw_line(p1[0].to_i32, p1[1].to_i32, p2[0].to_i32, p2[1].to_i32, s_col)
          Citrine.draw_line(p2[0].to_i32, p2[1].to_i32, p3[0].to_i32, p3[1].to_i32, s_col)
          Citrine.draw_line(p3[0].to_i32, p3[1].to_i32, p0[0].to_i32, p0[1].to_i32, s_col)
        end
        return
      end

      # No local rotation: check for rounded rectangle
      if frad > 0.0_f32
        draw_rounded_rect(fx, fy, fw, fh, frad, f_col, s_col, sw)
        return
      end

      # Axis-aligned with matrix stack transform
      p0 = @@current_transform.transform_point(fx, fy)
      p1 = @@current_transform.transform_point(fx + fw, fy)
      p2 = @@current_transform.transform_point(fx + fw, fy + fh)
      p3 = @@current_transform.transform_point(fx, fy + fh)

      if f_col
        Citrine.draw_triangle(p0[0], p0[1], p1[0], p1[1], p2[0], p2[1], f_col)
        Citrine.draw_triangle(p0[0], p0[1], p2[0], p2[1], p3[0], p3[1], f_col)
      end

      if s_col
        Citrine.draw_line(p0[0].to_i32, p0[1].to_i32, p1[0].to_i32, p1[1].to_i32, s_col)
        Citrine.draw_line(p1[0].to_i32, p1[1].to_i32, p2[0].to_i32, p2[1].to_i32, s_col)
        Citrine.draw_line(p2[0].to_i32, p2[1].to_i32, p3[0].to_i32, p3[1].to_i32, s_col)
        Citrine.draw_line(p3[0].to_i32, p3[1].to_i32, p0[0].to_i32, p0[1].to_i32, s_col)
      end
    end

    private def self.draw_rounded_rect(
      x : Float32, y : Float32,
      w : Float32, h : Float32,
      r : Float32,
      f_col : Color?, s_col : Color?, sw : Float32
    )
      max_r = Math.min(w, h) * 0.5_f32
      r = Math.min(r, max_r)

      # Decompose rounded rectangle into central cross quads + 4 corner fan discs
      if f_col
        # Center horizontal body
        quad(x, y + r, x + w, y + r, x + w, y + h - r, x, y + h - r, fill: f_col)
        # Top tab
        quad(x + r, y, x + w - r, y, x + w - r, y + r, x + r, y + r, fill: f_col)
        # Bottom tab
        quad(x + r, y + h - r, x + w - r, y + h - r, x + w - r, y + h, x + r, y + h, fill: f_col)
        # 4 Corner discs
        draw_corner_fan(x + r, y + r, r, 180.0_f32, 270.0_f32, f_col)
        draw_corner_fan(x + w - r, y + r, r, 270.0_f32, 360.0_f32, f_col)
        draw_corner_fan(x + w - r, y + h - r, r, 0.0_f32, 90.0_f32, f_col)
        draw_corner_fan(x + r, y + h - r, r, 90.0_f32, 180.0_f32, f_col)
      end

      if s_col
        # 4 straight border lines
        line(x + r, y, x + w - r, y, color: s_col, weight: sw)
        line(x + w, y + r, x + w, y + h - r, color: s_col, weight: sw)
        line(x + w - r, y + h, x + r, y + h, color: s_col, weight: sw)
        line(x, y + h - r, x, y + r, color: s_col, weight: sw)
      end
    end

    private def self.draw_corner_fan(cx : Float32, cy : Float32, r : Float32, start_deg : Float32, end_deg : Float32, col : Color)
      steps = 4
      step_deg = (end_deg - start_deg) / steps.to_f32
      rad0 = start_deg * (Math::PI.to_f32 / 180.0_f32)
      prev_x = cx + Math.cos(rad0) * r
      prev_y = cy + Math.sin(rad0) * r

      steps.times do |i|
        cur_deg = start_deg + (i + 1) * step_deg
        rad = cur_deg * (Math::PI.to_f32 / 180.0_f32)
        cur_x = cx + Math.cos(rad) * r
        cur_y = cy + Math.sin(rad) * r
        triangle(cx, cy, prev_x, prev_y, cur_x, cur_y, fill: col)
        prev_x = cur_x
        prev_y = cur_y
      end
    end

    # Draws a circle centered at (cx, cy) with radius r.
    def self.circle(
      cx : Number, cy : Number,
      r : Number,
      fill : Color? = nil,
      stroke : Color? = nil
    )
      ellipse(cx, cy, r.to_f32 * 2.0_f32, r.to_f32 * 2.0_f32, fill: fill, stroke: stroke)
    end

    # Draws an ellipse centered at (cx, cy) with width w and height h.
    def self.ellipse(
      cx : Number, cy : Number,
      w : Number, h : Number,
      fill : Color? = nil,
      stroke : Color? = nil
    )
      rx = w.to_f32 * 0.5_f32
      ry = h.to_f32 * 0.5_f32
      tcx, tcy = @@current_transform.transform_point(cx, cy)
      f_col = fill || (@@current_style.fill_enabled ? @@current_style.fill_color : nil)
      if f_col
        # Dispatched to native circle rasterizer with scaled radius
        avg_r = (rx + ry) * 0.5_f32 * ((@@current_transform.a.abs + @@current_transform.d.abs) * 0.5_f32)
        Citrine.draw_circle(tcx.to_i32, tcy.to_i32, avg_r, f_col)
      end
    end

    # Draws a regular star shape centered at (cx, cy) with given points, inner radius, and outer radius.
    def self.star(
      cx : Number, cy : Number,
      points : Int32 = 5,
      inner_r : Number = 10.0,
      outer_r : Number = 25.0,
      fill : Color? = nil,
      stroke : Color? = nil
    )
      fcx = cx.to_f32
      fcy = cy.to_f32
      total_verts = points * 2
      step = (Math::PI * 2.0_f32) / total_verts.to_f32

      verts = Array(Tuple(Float32, Float32)).new(total_verts)
      total_verts.times do |i|
        r = (i % 2 == 0) ? outer_r.to_f32 : inner_r.to_f32
        angle = i.to_f32 * step - (Math::PI * 0.5_f32)
        px = fcx + Math.cos(angle) * r
        py = fcy + Math.sin(angle) * r
        verts << @@current_transform.transform_point(px, py)
      end

      f_col = fill || (@@current_style.fill_enabled ? @@current_style.fill_color : nil)
      if f_col
        tcx, tcy = @@current_transform.transform_point(fcx, fcy)
        total_verts.times do |i|
          next_i = (i + 1) % total_verts
          Citrine.draw_triangle(tcx, tcy, verts[i][0], verts[i][1], verts[next_i][0], verts[next_i][1], f_col)
        end
      end

      s_col = stroke || (@@current_style.stroke_enabled ? @@current_style.stroke_color : nil)
      if s_col
        total_verts.times do |i|
          next_i = (i + 1) % total_verts
          Citrine.draw_line(verts[i][0].to_i32, verts[i][1].to_i32, verts[next_i][0].to_i32, verts[next_i][1].to_i32, s_col)
        end
      end
    end

    # Draws arbitrary polygon defined by an array of Vector2 vertices.
    def self.polygon(
      points : Array(Vector2),
      fill : Color? = nil,
      stroke : Color? = nil
    )
      return if points.size < 3
      t_points = points.map { |p| @@current_transform.transform_point(p.x, p.y) }

      f_col = fill || (@@current_style.fill_enabled ? @@current_style.fill_color : nil)
      if f_col
        # Triangle fan triangulation around vertex 0
        (1...(t_points.size - 1)).each do |i|
          Citrine.draw_triangle(
            t_points[0][0], t_points[0][1],
            t_points[i][0], t_points[i][1],
            t_points[i + 1][0], t_points[i + 1][1],
            f_col
          )
        end
      end

      s_col = stroke || (@@current_style.stroke_enabled ? @@current_style.stroke_color : nil)
      if s_col
        t_points.size.times do |i|
          next_i = (i + 1) % t_points.size
          Citrine.draw_line(
            t_points[i][0].to_i32, t_points[i][1].to_i32,
            t_points[next_i][0].to_i32, t_points[next_i][1].to_i32,
            s_col
          )
        end
      end
    end

    # =========================================================================
    # Rotated & Formatted Text DSL
    # =========================================================================

    # Renders text string with optional rotation angle (in degrees), pivot origin,
    # font size, color, and horizontal alignment (:left, :center, :right).
    def self.text(
      string : String,
      x : Number, y : Number,
      size : Int32 = 16,
      color : Color = Color::White,
      rotation : Number = 0.0,
      origin : Vector2? = nil,
      align : Symbol = :left
    )
      fx = x.to_f32
      fy = y.to_f32

      # Approximate font metrics for alignment (standard 8x16 bitmap glyph ratio: 0.55 * size)
      char_w = size.to_f32 * 0.55_f32
      str_w = string.size.to_f32 * char_w

      adj_x = case align
              when :center then fx - (str_w * 0.5_f32)
              when :right  then fx - str_w
              else fx
              end

      if rotation == 0.0 && !origin && @@current_transform.b == 0.0_f32 && @@current_transform.c == 0.0_f32
        # Simple axis-aligned text
        tx, ty = @@current_transform.transform_point(adj_x, fy)
        Citrine.draw_text(string, tx.to_i32, ty.to_i32, size, color)
        return
      end

      # Rotated text rendering via affine transformed glyph quads
      ox = origin ? origin.x : 0.0_f32
      oy = origin ? origin.y : 0.0_f32
      rot_mat = Transform2D.rotation(rotation, ox, oy)
      combined = @@current_transform * Transform2D.translation(adj_x, fy) * rot_mat

      # Decompose string glyph quads along baseline
      string.each_char_with_index do |ch, i|
        next if ch == ' '
        gx = i.to_f32 * char_w
        gy = 0.0_f32
        gw = char_w * 0.9_f32
        gh = size.to_f32

        p0 = combined.transform_point(gx, gy)
        p1 = combined.transform_point(gx + gw, gy)
        p2 = combined.transform_point(gx + gw, gy + gh)
        p3 = combined.transform_point(gx, gy + gh)

        # Emit glyph quad as 2 GS triangles
        Citrine.draw_triangle(p0[0], p0[1], p1[0], p1[1], p2[0], p2[1], color)
        Citrine.draw_triangle(p0[0], p0[1], p2[0], p2[1], p3[0], p3[1], color)
      end
    end

    # Convenience card container with background fill, border stroke, and optional rounded corners.
    def self.card(
      x : Number, y : Number,
      w : Number, h : Number,
      radius : Number = 4.0,
      fill : Color = Color.new(25_u8, 30_u8, 42_u8, 240_u8),
      stroke : Color = Color.new(65_u8, 75_u8, 95_u8, 255_u8),
      &block
    )
      rect(x, y, w, h, radius: radius, fill: fill, stroke: stroke, weight: 1.5_f32)
      transform(x: x, y: y) do
        yield
      end
    end

    # =========================================================================
    # 2D Texture Drawing & Palette Swapping DSL
    # =========================================================================

    @@current_palette : UInt32? = nil
    @@palette_stack = Array(UInt32?).new(8)

    # Sets active GS CLUT buffer pointer to the specified palette handle.
    def self.set_palette(palette : Palette | UInt32?)
      handle = palette.is_a?(Palette) ? palette.handle : palette
      @@current_palette = handle
      Citrine.set_palette(handle) if handle
    end

    # Executes a block with a scoped palette, restoring the previous palette on exit.
    def self.with_palette(palette : Palette | UInt32?, &block)
      @@palette_stack.push(@@current_palette)
      set_palette(palette)
      begin
        yield
      ensure
        prev = @@palette_stack.size > 0 ? @@palette_stack.pop : nil
        set_palette(prev)
      end
    end

    # Resolves origin preset symbol or Vector2 into pixel offset (ox, oy).
    def self.resolve_origin(origin : Symbol | Vector2?, width : Float32, height : Float32) : Tuple(Float32, Float32)
      case origin
      when :center
        { width * 0.5_f32, height * 0.5_f32 }
      when :top_center, :center_top
        { width * 0.5_f32, 0.0_f32 }
      when :bottom_center, :center_bottom
        { width * 0.5_f32, height }
      when :center_left, :left_center
        { 0.0_f32, height * 0.5_f32 }
      when :center_right, :right_center
        { width, height * 0.5_f32 }
      when :top_right, :right_top
        { width, 0.0_f32 }
      when :bottom_left, :left_bottom
        { 0.0_f32, height }
      when :bottom_right, :right_bottom
        { width, height }
      when :top_left, :left_top, nil
        { 0.0_f32, 0.0_f32 }
      when Vector2
        { origin.x, origin.y }
      else
        { 0.0_f32, 0.0_f32 }
      end
    end

    # Draws a texture in 2D mode with support for custom width/height, arbitrary rotation,
    # origin anchor presets (:center, :bottom_center, etc.), scaling, color tinting,
    # horizontal/vertical mirroring (flip_x, flip_y), source UV cropping, and palette swapping.
    def self.draw_texture(
      texture : Texture | UInt32,
      x : Number = 0, y : Number = 0,
      width : Number? = nil,
      height : Number? = nil,
      rotation : Number = 0.0,
      origin : Symbol | Vector2? = nil,
      scale : Number = 1.0,
      scale_y : Number? = nil,
      tint : Color = Color::White,
      flip_x : Bool = false,
      flip_y : Bool = false,
      src : Rect? = nil,
      dest : Rect? = nil,
      palette : Palette | UInt32? = nil
    )
      # Apply temporary palette if specified
      if palette
        with_palette(palette) do
          draw_texture(
            texture, x, y, width: width, height: height,
            rotation: rotation, origin: origin, scale: scale, scale_y: scale_y,
            tint: tint, flip_x: flip_x, flip_y: flip_y, src: src, dest: dest, palette: nil
          )
        end
        return
      end

      tex_w = texture.is_a?(Texture) ? texture.width.to_f32 : 64.0_f32
      tex_h = texture.is_a?(Texture) ? texture.height.to_f32 : 64.0_f32
      tex_handle = texture.is_a?(Texture) ? texture.handle : texture.to_u32

      # Determine source rectangle
      sx = src ? src.x : 0.0_f32
      sy = src ? src.y : 0.0_f32
      sw = src ? src.width : tex_w
      sh = src ? src.height : tex_h

      # Determine destination dimensions
      base_w = width ? width.to_f32 : sw
      base_h = height ? height.to_f32 : sh
      fw = (dest ? dest.width : base_w) * scale.to_f32
      fh = (dest ? dest.height : base_h) * (scale_y ? scale_y.to_f32 : scale.to_f32)
      dx = dest ? dest.x : x.to_f32
      dy = dest ? dest.y : y.to_f32

      # Resolve origin pivot
      ox, oy = resolve_origin(origin, fw, fh)

      rot = rotation.to_f32

      # Hardware Fast-Path Check:
      # If no rotation, no skew in matrix stack, no flip, and no scaling:
      # Emit as axis-aligned GS_PRIM_SPRITE via draw_texture_rec!
      if rot == 0.0_f32 && @@current_transform.b == 0.0_f32 && @@current_transform.c == 0.0_f32 && !flip_x && !flip_y && fw == sw && fh == sh && @@current_transform.a == 1.0_f32 && @@current_transform.d == 1.0_f32
        tx, ty = @@current_transform.transform_point(dx - ox, dy - oy)
        Citrine.draw_texture_rec(tex_handle, sx, sy, sw, sh, tx, ty, tint)
        return
      end

      # General Affine Path:
      # Bit 0: flip_x, Bit 1: flip_y
      flip_flags = 0_u8
      flip_flags |= 1_u8 if flip_x
      flip_flags |= 2_u8 if flip_y

      # If matrix stack has transform, combine destination with matrix stack
      if @@current_transform.a != 1.0_f32 || @@current_transform.d != 1.0_f32 ||
         @@current_transform.tx != 0.0_f32 || @@current_transform.ty != 0.0_f32 ||
         @@current_transform.b != 0.0_f32 || @@current_transform.c != 0.0_f32
        tx, ty = @@current_transform.transform_point(dx, dy)
        Citrine.draw_texture_pro(
          tex_handle,
          sx, sy, sw, sh,
          tx, ty, fw * @@current_transform.a.abs, fh * @@current_transform.d.abs,
          rot, ox, oy,
          tint, flip_flags
        )
      else
        Citrine.draw_texture_pro(
          tex_handle,
          sx, sy, sw, sh,
          dx, dy, fw, fh,
          rot, ox, oy,
          tint, flip_flags
        )
      end
    end

    # Convenience alias for draw_texture matching Draw2D DSL naming conventions.
    def self.texture(
      texture : Texture | UInt32,
      x : Number = 0, y : Number = 0,
      width : Number? = nil,
      height : Number? = nil,
      rotation : Number = 0.0,
      origin : Symbol | Vector2? = nil,
      scale : Number = 1.0,
      scale_y : Number? = nil,
      tint : Color = Color::White,
      flip_x : Bool = false,
      flip_y : Bool = false,
      src : Rect? = nil,
      dest : Rect? = nil,
      palette : Palette | UInt32? = nil
    )
      draw_texture(
        texture, x, y, width: width, height: height,
        rotation: rotation, origin: origin, scale: scale, scale_y: scale_y,
        tint: tint, flip_x: flip_x, flip_y: flip_y, src: src, dest: dest, palette: palette
      )
    end
  end
end

