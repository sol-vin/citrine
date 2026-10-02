# Citrine GL - Immediate Mode Graphics Pipeline
# Provides familiar glBegin/glEnd semantics with ModelView matrix transformation

require "../citrine"

module Citrine
  module GL
    enum Mode : UInt8
      Points        = 0
      Lines         = 1
      LineStrip     = 2
      LineLoop      = 3
      Triangles     = 4
      TriangleStrip = 5
      TriangleFan   = 6
      Quads         = 7
    end

    POINTS         = Mode::Points
    LINES          = Mode::Lines
    LINE_STRIP     = Mode::LineStrip
    LINE_LOOP      = Mode::LineLoop
    TRIANGLES      = Mode::Triangles
    TRIANGLE_STRIP = Mode::TriangleStrip
    TRIANGLE_FAN   = Mode::TriangleFan
    QUADS          = Mode::Quads

    @@current_mode : Mode = Mode::Triangles
    @@in_begin : Bool = false
    @@current_color : Color = Color::White
    @@current_u : Float32 = 0.0_f32
    @@current_v : Float32 = 0.0_f32

    struct Vertex
      property x : Float32
      property y : Float32
      property z : Float32
      property u : Float32
      property v : Float32
      property color : Color

      def initialize(@x, @y, @z, @u, @v, @color)
      end
    end

    @@vertices = Array(Vertex).new(128)

    # 4x4 Transformation Matrix Stack
    struct Matrix4
      property m : StaticArray(Float32, 16)

      def initialize
        @m = StaticArray(Float32, 16).new(0.0_f32)
        @m[0] = 1.0_f32
        @m[5] = 1.0_f32
        @m[10] = 1.0_f32
        @m[15] = 1.0_f32
      end

      def initialize(@m : StaticArray(Float32, 16))
      end

      def self.identity : Matrix4
        Matrix4.new
      end

      def transform(x : Float32, y : Float32, z : Float32) : Tuple(Float32, Float32, Float32)
        tx = @m[0]*x + @m[4]*y + @m[8]*z + @m[12]
        ty = @m[1]*x + @m[5]*y + @m[9]*z + @m[13]
        tz = @m[2]*x + @m[6]*y + @m[10]*z + @m[14]
        {tx, ty, tz}
      end

      def *(other : Matrix4) : Matrix4
        res = StaticArray(Float32, 16).new(0.0_f32)
        4.times do |i|
          4.times do |j|
            sum = 0.0_f32
            4.times do |k|
              sum += @m[k * 4 + j] * other.m[i * 4 + k]
            end
            res[i * 4 + j] = sum
          end
        end
        Matrix4.new(res)
      end
    end

    @@matrix_stack = Array(Matrix4).new(16)
    @@current_matrix : Matrix4 = Matrix4.identity

    def self.begin(mode : Mode)
      @@current_mode = mode
      @@in_begin = true
      @@vertices.clear
    end

    def self.begin(mode_int : Int)
      self.begin(Mode.new(mode_int.to_u8))
    end

    def self.color(color : Color)
      @@current_color = color
    end

    def self.color(r : Number, g : Number, b : Number, a : Number = 255)
      @@current_color = Color.new(r.to_u8, g.to_u8, b.to_u8, a.to_u8)
    end

    def self.color(hex : UInt32)
      r = (hex & 0xFF).to_u8
      g = ((hex >> 8) & 0xFF).to_u8
      b = ((hex >> 16) & 0xFF).to_u8
      a = ((hex >> 24) & 0xFF).to_u8
      @@current_color = Color.new(r, g, b, a)
    end

    def self.tex_coord(u : Number, v : Number)
      @@current_u = u.to_f32
      @@current_v = v.to_f32
    end

    def self.vertex(x : Number, y : Number, z : Number = 0.0)
      tx, ty, tz = @@current_matrix.transform(x.to_f32, y.to_f32, z.to_f32)
      @@vertices << Vertex.new(tx, ty, tz, @@current_u, @@current_v, @@current_color)
    end

    def self.end
      return unless @@in_begin
      @@in_begin = false

      case @@current_mode
      when Mode::Points
        @@vertices.each do |v|
          Citrine.draw_rectangle(v.x.to_i32, v.y.to_i32, 1, 1, v.color)
        end
      when Mode::Lines
        i = 0
        while i + 1 < @@vertices.size
          v1 = @@vertices[i]
          v2 = @@vertices[i + 1]
          Citrine.draw_line(v1.x.to_i32, v1.y.to_i32, v2.x.to_i32, v2.y.to_i32, v1.color)
          i += 2
        end
      when Mode::LineStrip
        (0...(@@vertices.size - 1)).each do |i|
          v1 = @@vertices[i]
          v2 = @@vertices[i + 1]
          Citrine.draw_line(v1.x.to_i32, v1.y.to_i32, v2.x.to_i32, v2.y.to_i32, v1.color)
        end
      when Mode::LineLoop
        if @@vertices.size > 1
          (0...(@@vertices.size - 1)).each do |i|
            v1 = @@vertices[i]
            v2 = @@vertices[i + 1]
            Citrine.draw_line(v1.x.to_i32, v1.y.to_i32, v2.x.to_i32, v2.y.to_i32, v1.color)
          end
          first = @@vertices.first
          last = @@vertices.last
          Citrine.draw_line(last.x.to_i32, last.y.to_i32, first.x.to_i32, first.y.to_i32, last.color)
        end
      when Mode::Triangles
        i = 0
        while i + 2 < @@vertices.size
          v1 = @@vertices[i]
          v2 = @@vertices[i + 1]
          v3 = @@vertices[i + 2]
          Citrine.draw_triangle(v1.x, v1.y, v2.x, v2.y, v3.x, v3.y, v1.color)
          i += 3
        end
      when Mode::TriangleStrip
        (0...(@@vertices.size - 2)).each do |i|
          if i % 2 == 0
            v1, v2, v3 = @@vertices[i], @@vertices[i + 1], @@vertices[i + 2]
          else
            v1, v2, v3 = @@vertices[i + 1], @@vertices[i], @@vertices[i + 2]
          end
          Citrine.draw_triangle(v1.x, v1.y, v2.x, v2.y, v3.x, v3.y, v1.color)
        end
      when Mode::TriangleFan
        first = @@vertices[0]?
        if first
          (1...(@@vertices.size - 1)).each do |i|
            v2 = @@vertices[i]
            v3 = @@vertices[i + 1]
            Citrine.draw_triangle(first.x, first.y, v2.x, v2.y, v3.x, v3.y, first.color)
          end
        end
      when Mode::Quads
        # Granular decomposition: Each quad (4 vertices) decomposes into TWO triangles!
        i = 0
        while i + 3 < @@vertices.size
          v1 = @@vertices[i]
          v2 = @@vertices[i + 1]
          v3 = @@vertices[i + 2]
          v4 = @@vertices[i + 3]
          # Triangle 1: (v1, v2, v3)
          Citrine.draw_triangle(v1.x, v1.y, v2.x, v2.y, v3.x, v3.y, v1.color)
          # Triangle 2: (v1, v3, v4)
          Citrine.draw_triangle(v1.x, v1.y, v3.x, v3.y, v4.x, v4.y, v1.color)
          i += 4
        end
      end
    end

    def self.push_matrix
      @@matrix_stack.push(@@current_matrix)
    end

    def self.pop_matrix
      if @@matrix_stack.size > 0
        @@current_matrix = @@matrix_stack.pop
      end
    end

    def self.load_identity
      @@current_matrix = Matrix4.identity
    end

    def self.translate(x : Number, y : Number, z : Number = 0.0)
      trans = Matrix4.identity
      trans.m[12] = x.to_f32
      trans.m[13] = y.to_f32
      trans.m[14] = z.to_f32
      @@current_matrix = @@current_matrix * trans
    end

    def self.scale(x : Number, y : Number, z : Number = 1.0)
      s = Matrix4.identity
      s.m[0] = x.to_f32
      s.m[5] = y.to_f32
      s.m[10] = z.to_f32
      @@current_matrix = @@current_matrix * s
    end

    def self.rotate(angle_deg : Number, x : Number, y : Number, z : Number)
      rad = angle_deg.to_f32 * (Math::PI.to_f32 / 180.0_f32)
      c = Math.cos(rad)
      s = Math.sin(rad)
      len = Math.sqrt(x*x + y*y + z*z).to_f32
      return if len == 0.0_f32
      nx = x.to_f32 / len
      ny = y.to_f32 / len
      nz = z.to_f32 / len

      r = Matrix4.identity
      r.m[0] = nx*nx*(1 - c) + c
      r.m[1] = ny*nx*(1 - c) + nz*s
      r.m[2] = nz*nx*(1 - c) - ny*s

      r.m[4] = nx*ny*(1 - c) - nz*s
      r.m[5] = ny*ny*(1 - c) + c
      r.m[6] = nz*ny*(1 - c) + nx*s

      r.m[8] = nx*nz*(1 - c) + ny*s
      r.m[9] = ny*nz*(1 - c) - nx*s
      r.m[10] = nz*nz*(1 - c) + c

      @@current_matrix = @@current_matrix * r
    end
  end
end
