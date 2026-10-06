# Citrine GL - Immediate Mode Graphics Pipeline
# Provides familiar glBegin/glEnd semantics with ModelView matrix transformation

require "../citrine"

module Citrine
  # OpenGL-compatible immediate mode rendering subsystem featuring matrix stacks,
  # vertex assembly, UV mapping, and automatic polygon triangulation for the PS2 GS.
  module GL
    # Primitive assembly rasterization modes.
    enum Mode : UInt8
      # Individual points (1 pixel each).
      Points        = 0
      # Independent line segments (2 vertices per line).
      Lines         = 1
      # Connected line strip.
      LineStrip     = 2
      # Closed line loop.
      LineLoop      = 3
      # Independent triangles (3 vertices per triangle).
      Triangles     = 4
      # Connected triangle strip.
      TriangleStrip = 5
      # Connected triangle fan around the initial vertex.
      TriangleFan   = 6
      # Quadrilaterals (4 vertices per quad, auto-decomposed into 2 triangles).
      Quads         = 7
    end

    # Immediate-mode mode constants mirroring traditional OpenGL.
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

    # Represents a 3D vertex with position, texture coordinates, and color attributes.
    struct Vertex
      # World/transformed X coordinate.
      property x : Float32
      # World/transformed Y coordinate.
      property y : Float32
      # World/transformed Z coordinate (depth).
      property z : Float32
      # Normalized horizontal texture coordinate (U).
      property u : Float32
      # Normalized vertical texture coordinate (V).
      property v : Float32
      # RGBA vertex color.
      property color : Color

      # Creates a new vertex with coordinates, UVs, and color.
      def initialize(@x, @y, @z, @u, @v, @color)
      end
    end

    @@vertices = Array(Vertex).new(128)

    # 4x4 Transformation Matrix Stack for ModelView transforms.
    struct Matrix4
      # Column-major 16-element float array representing the 4x4 matrix.
      property m : StaticArray(Float32, 16)

      # Initializes an identity matrix.
      def initialize
        @m = StaticArray(Float32, 16).new(0.0_f32)
        @m[0] = 1.0_f32
        @m[5] = 1.0_f32
        @m[10] = 1.0_f32
        @m[15] = 1.0_f32
      end

      # Initializes a matrix from raw 16-element float array.
      def initialize(@m : StaticArray(Float32, 16))
      end

      # Returns the 4x4 identity matrix.
      def self.identity : Matrix4
        Matrix4.new
      end

      # Multiplies 3D vector `(x, y, z, 1.0)` by this matrix and returns transformed coordinates.
      def transform(x : Float32, y : Float32, z : Float32) : Tuple(Float32, Float32, Float32)
        tx = @m[0]*x + @m[4]*y + @m[8]*z + @m[12]
        ty = @m[1]*x + @m[5]*y + @m[9]*z + @m[13]
        tz = @m[2]*x + @m[6]*y + @m[10]*z + @m[14]
        {tx, ty, tz}
      end

      # Multiplies this matrix with `other` matrix (`self * other`).
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

    # Begins assembly of primitives for the specified `mode`.
    def self.begin(mode : Mode)
      @@current_mode = mode
      @@in_begin = true
      @@vertices.clear
    end

    # Overload for integer primitive mode enum values.
    def self.begin(mode_int : Int)
      self.begin(Mode.new(mode_int.to_u8))
    end

    # Sets current vertex color using `Color` struct.
    def self.color(color : Color)
      @@current_color = color
    end

    # Sets current vertex color using RGBA components (0-255).
    def self.color(r : Number, g : Number, b : Number, a : Number = 255)
      @@current_color = Color.new(r.to_u8, g.to_u8, b.to_u8, a.to_u8)
    end

    # Sets current vertex color from packed 32-bit integer (RGBA or 0xRRGGBBAA).
    def self.color(hex : UInt32)
      r = (hex & 0xFF).to_u8
      g = ((hex >> 8) & 0xFF).to_u8
      b = ((hex >> 16) & 0xFF).to_u8
      a = ((hex >> 24) & 0xFF).to_u8
      @@current_color = Color.new(r, g, b, a)
    end

    # Sets active texture coordinates `(u, v)` for subsequent vertices.
    def self.tex_coord(u : Number, v : Number)
      @@current_u = u.to_f32
      @@current_v = v.to_f32
    end

    # Submits a vertex with coordinates `(x, y, z)`. Applies current matrix transform.
    def self.vertex(x : Number, y : Number, z : Number = 0.0)
      tx, ty, tz = @@current_matrix.transform(x.to_f32, y.to_f32, z.to_f32)
      @@vertices << Vertex.new(tx, ty, tz, @@current_u, @@current_v, @@current_color)
    end

    # Completes primitive definition and dispatches draw calls to the Citrine GS pipeline.
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

    # Pushes the active transformation matrix onto the matrix stack.
    def self.push_matrix
      @@matrix_stack.push(@@current_matrix)
    end

    # Restores the top matrix from the matrix stack.
    def self.pop_matrix
      if @@matrix_stack.size > 0
        @@current_matrix = @@matrix_stack.pop
      end
    end

    # Resets the active transformation matrix to identity.
    def self.load_identity
      @@current_matrix = Matrix4.identity
    end

    # Multiplies the active matrix by a translation matrix `(x, y, z)`.
    def self.translate(x : Number, y : Number, z : Number = 0.0)
      trans = Matrix4.identity
      trans.m[12] = x.to_f32
      trans.m[13] = y.to_f32
      trans.m[14] = z.to_f32
      @@current_matrix = @@current_matrix * trans
    end

    # Multiplies the active matrix by a non-uniform scale matrix `(x, y, z)`.
    def self.scale(x : Number, y : Number, z : Number = 1.0)
      s = Matrix4.identity
      s.m[0] = x.to_f32
      s.m[5] = y.to_f32
      s.m[10] = z.to_f32
      @@current_matrix = @@current_matrix * s
    end

    # Multiplies the active matrix by an arbitrary axis-angle rotation matrix (in degrees).
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

    # Scoped immediate-mode primitive blocks (guaranteed glBegin / glEnd pairing)
    def self.triangles(&block)
      self.begin(Mode::Triangles)
      begin
        yield
      ensure
        self.end
      end
    end

    def self.quads(&block)
      self.begin(Mode::Quads)
      begin
        yield
      ensure
        self.end
      end
    end

    def self.lines(&block)
      self.begin(Mode::Lines)
      begin
        yield
      ensure
        self.end
      end
    end

    def self.line_strip(&block)
      self.begin(Mode::LineStrip)
      begin
        yield
      ensure
        self.end
      end
    end

    def self.points(&block)
      self.begin(Mode::Points)
      begin
        yield
      ensure
        self.end
      end
    end

    # Scoped matrix transformation block (guaranteed push_matrix / pop_matrix pairing)
    def self.matrix(&block)
      push_matrix
      begin
        yield
      ensure
        pop_matrix
      end
    end
  end
end

