# Citrine 3D Perspective Rendering Subsystem
# Modular engine abstraction - require "citrine/draw3d"

require "../citrine"
require "./math"

# 3D Axis-Aligned Bounding Box (AABB)
struct BoundingBox
  property min_x : Float32
  property min_y : Float32
  property min_z : Float32
  property max_x : Float32
  property max_y : Float32
  property max_z : Float32

  def initialize(
    @min_x : Float32 = Float32::MAX,
    @min_y : Float32 = Float32::MAX,
    @min_z : Float32 = Float32::MAX,
    @max_x : Float32 = -Float32::MAX,
    @max_y : Float32 = -Float32::MAX,
    @max_z : Float32 = -Float32::MAX
  )
  end

  def initialize(min : Vector3, max : Vector3)
    @min_x = min.x
    @min_y = min.y
    @min_z = min.z
    @max_x = max.x
    @max_y = max.y
    @max_z = max.z
  end

  def min : Vector3
    Vector3.new(@min_x, @min_y, @min_z)
  end

  def max : Vector3
    Vector3.new(@max_x, @max_y, @max_z)
  end

  def update(x : Number, y : Number, z : Number)
    fx = x.to_f32
    fy = y.to_f32
    fz = z.to_f32
    @min_x = fx if fx < @min_x
    @min_y = fy if fy < @min_y
    @min_z = fz if fz < @min_z
    @max_x = fx if fx > @max_x
    @max_y = fy if fy > @max_y
    @max_z = fz if fz > @max_z
  end

  def update(v : Vector3)
    update(v.x, v.y, v.z)
  end

  def update(b : BoundingBox)
    update(b.min_x, b.min_y, b.min_z)
    update(b.max_x, b.max_y, b.max_z)
  end

  def center : Vector3
    Vector3.new((@min_x + @max_x) * 0.5_f32, (@min_y + @max_y) * 0.5_f32, (@min_z + @max_z) * 0.5_f32)
  end

  def size : Vector3
    Vector3.new(@max_x - @min_x, @max_y - @min_y, @max_z - @min_z)
  end
end

# Face culling mode for 3D triangles on Graphics Synthesizer
enum CullMode : UInt8
  None  = 0 # Render both front and back faces (glTF doubleSided)
  Back  = 1 # Cull back-facing triangles (standard default)
  Front = 2 # Cull front-facing triangles
end

# 3D surface alpha blending modes
enum BlendMode3D : UInt8
  Opaque   = 0 # No blending, direct Z-buffer depth write
  Alpha    = 1 # Standard alpha transparency (SRC_ALPHA, ONE_MINUS_SRC_ALPHA)
  Additive = 2 # Additive illumination blending (SRC_ALPHA, ONE)
end

# 4x4 Transformation Matrix Stack for ModelView & World transforms
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

  def self.translation(x : Number, y : Number, z : Number) : Matrix4
    mat = Matrix4.new
    mat.m[12] = x.to_f32
    mat.m[13] = y.to_f32
    mat.m[14] = z.to_f32
    mat
  end

  def self.scaling(sx : Number, sy : Number, sz : Number) : Matrix4
    mat = Matrix4.new
    mat.m[0] = sx.to_f32
    mat.m[5] = sy.to_f32
    mat.m[10] = sz.to_f32
    mat
  end

  def self.rotation_y(angle_rad : Number) : Matrix4
    c = Math.cos(angle_rad.to_f32).to_f32
    s = Math.sin(angle_rad.to_f32).to_f32
    mat = Matrix4.new
    mat.m[0] = c
    mat.m[2] = -s
    mat.m[8] = s
    mat.m[10] = c
    mat
  end

  def self.rotation(axis : Vector3, angle_rad : Number) : Matrix4
    x = axis.x
    y = axis.y
    z = axis.z
    len = Math.sqrt(x*x + y*y + z*z).to_f32
    if len > 0.0_f32
      x /= len
      y /= len
      z /= len
    end

    c = Math.cos(angle_rad.to_f32).to_f32
    s = Math.sin(angle_rad.to_f32).to_f32
    t = 1.0_f32 - c

    mat = Matrix4.new
    mat.m[0] = x*x*t + c
    mat.m[1] = y*x*t + z*s
    mat.m[2] = x*z*t - y*s
    mat.m[3] = 0.0_f32

    mat.m[4] = x*y*t - z*s
    mat.m[5] = y*y*t + c
    mat.m[6] = y*z*t + x*s
    mat.m[7] = 0.0_f32

    mat.m[8] = x*z*t + y*s
    mat.m[9] = y*z*t - x*s
    mat.m[10] = z*z*t + c
    mat.m[11] = 0.0_f32

    mat.m[12] = 0.0_f32
    mat.m[13] = 0.0_f32
    mat.m[14] = 0.0_f32
    mat.m[15] = 1.0_f32
    mat
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

module Citrine
  # Material definition encapsulating diffuse texture, shading tint, ambient/specular coefficients,
  # culling flags, and blending properties on the PlayStation 2 Graphics Synthesizer.
  class Material
    property texture : Texture?
    property color : Color
    property ambient : Color
    property specular : Color
    property shininess : Float32
    property cull_mode : CullMode
    property blend_mode : BlendMode3D
    property wireframe : Bool

    def initialize(
      @texture : Texture? = nil,
      @color : Color = Color::White,
      @ambient : Color = Color.new(32_u8, 32_u8, 32_u8, 255_u8),
      @specular : Color = Color::White,
      @shininess : Float32 = 0.0_f32,
      @cull_mode : CullMode = CullMode::Back,
      @blend_mode : BlendMode3D = BlendMode3D::Opaque,
      @wireframe : Bool = false
    )
    end

    def self.default : Material
      Material.new
    end

    def self.from_texture(tex : Texture, color : Color = Color::White) : Material
      Material.new(texture: tex, color: color)
    end

    def self.from_color(color : Color) : Material
      Material.new(color: color)
    end
  end

  # Represents 3D polygon geometry with interleaved 32-byte vertex attributes
  # (Position XYZ, Normal XYZ, UV) and 16-bit triangle indices for Emotion Engine DMA.
  class Mesh
    property name : String
    property vertices : Array(Float32)     # [x, y, z, ...]
    property normals : Array(Float32)      # [nx, ny, nz, ...]
    property texcoords : Array(Float32)    # [u, v, ...]
    property colors : Array(UInt8)         # [r, g, b, a, ...]
    property indices : Array(UInt16)
    property bounds : BoundingBox
    property material_index : Int32

    def initialize(@name : String = "mesh", @material_index : Int32 = 0)
      @vertices = [] of Float32
      @normals = [] of Float32
      @texcoords = [] of Float32
      @colors = [] of UInt8
      @indices = [] of UInt16
      @bounds = BoundingBox.new
    end

    def vertex_count : Int32
      @vertices.size // 3
    end

    def triangle_count : Int32
      @indices.size // 3
    end

    def index_count : Int32
      @indices.size
    end

    # Procedural Mesh Generator: Cube
    # Generates 24 vertices (4 per face) with distinct normals and UV coordinates (0..1)
    def self.gen_cube(width : Number, height : Number, length : Number) : Mesh
      mesh = Mesh.new("cube")
      w = width.to_f32 * 0.5_f32
      h = height.to_f32 * 0.5_f32
      l = length.to_f32 * 0.5_f32

      # 6 faces: +Z (front), -Z (back), +X (right), -X (left), +Y (top), -Y (bottom)
      faces = [
        # Front (+Z)
        { [ {-w, -h,  l}, { w, -h,  l}, { w,  h,  l}, {-w,  h,  l} ], {0.0_f32, 0.0_f32, 1.0_f32} },
        # Back (-Z)
        { [ { w, -h, -l}, {-w, -h, -l}, {-w,  h, -l}, { w,  h, -l} ], {0.0_f32, 0.0_f32, -1.0_f32} },
        # Right (+X)
        { [ { w, -h,  l}, { w, -h, -l}, { w,  h, -l}, { w,  h,  l} ], {1.0_f32, 0.0_f32, 0.0_f32} },
        # Left (-X)
        { [ {-w, -h, -l}, {-w, -h,  l}, {-w,  h,  l}, {-w,  h, -l} ], {-1.0_f32, 0.0_f32, 0.0_f32} },
        # Top (+Y)
        { [ {-w,  h,  l}, { w,  h,  l}, { w,  h, -l}, {-w,  h, -l} ], {0.0_f32, 1.0_f32, 0.0_f32} },
        # Bottom (-Y)
        { [ {-w, -h, -l}, { w, -h, -l}, { w, -h,  l}, {-w, -h,  l} ], {0.0_f32, -1.0_f32, 0.0_f32} },
      ]

      uvs = [ {0.0_f32, 1.0_f32}, {1.0_f32, 1.0_f32}, {1.0_f32, 0.0_f32}, {0.0_f32, 0.0_f32} ]

      faces.each do |face_verts, normal|
        base_idx = mesh.vertex_count.to_u16
        4.times do |i|
          vx, vy, vz = face_verts[i]
          mesh.vertices << vx << vy << vz
          mesh.normals << normal[0] << normal[1] << normal[2]
          mesh.texcoords << uvs[i][0] << uvs[i][1]
          mesh.bounds.update(vx, vy, vz)
        end
        # Two triangles per face quad: (0, 1, 2) and (0, 2, 3)
        mesh.indices << (base_idx + 0_u16) << (base_idx + 1_u16) << (base_idx + 2_u16)
        mesh.indices << (base_idx + 0_u16) << (base_idx + 2_u16) << (base_idx + 3_u16)
      end

      mesh
    end

    # Procedural Mesh Generator: Plane (XZ Ground)
    def self.gen_plane(width : Number, length : Number, res_x : Int32 = 1, res_z : Int32 = 1) : Mesh
      mesh = Mesh.new("plane")
      w = width.to_f32
      l = length.to_f32
      rx = res_x < 1 ? 1 : res_x
      rz = res_z < 1 ? 1 : res_z

      (0..rz).each do |z|
        z_pos = (z.to_f32 / rz.to_f32 - 0.5_f32) * l
        v = z.to_f32 / rz.to_f32
        (0..rx).each do |x|
          x_pos = (x.to_f32 / rx.to_f32 - 0.5_f32) * w
          u = x.to_f32 / rx.to_f32
          mesh.vertices << x_pos << 0.0_f32 << z_pos
          mesh.normals << 0.0_f32 << 1.0_f32 << 0.0_f32
          mesh.texcoords << u << v
          mesh.bounds.update(x_pos, 0.0_f32, z_pos)
        end
      end

      (0...rz).each do |z|
        (0...rx).each do |x|
          row1 = (z * (rx + 1) + x).to_u16
          row2 = ((z + 1) * (rx + 1) + x).to_u16
          mesh.indices << row1 << (row1 + 1_u16) << row2
          mesh.indices << (row1 + 1_u16) << (row2 + 1_u16) << row2
        end
      end

      mesh
    end

    # Procedural Mesh Generator: UV Sphere
    def self.gen_sphere(radius : Number, rings : Int32 = 16, slices : Int32 = 16) : Mesh
      mesh = Mesh.new("sphere")
      r = radius.to_f32
      rings_cnt = rings < 4 ? 4 : rings
      slices_cnt = slices < 4 ? 4 : slices

      (0..rings_cnt).each do |i|
        v = i.to_f32 / rings_cnt.to_f32
        phi = v * Math::PI.to_f32
        (0..slices_cnt).each do |j|
          u = j.to_f32 / slices_cnt.to_f32
          theta = u * Math::PI.to_f32 * 2.0_f32

          nx = Math.sin(phi) * Math.cos(theta)
          ny = Math.cos(phi)
          nz = Math.sin(phi) * Math.sin(theta)

          vx = nx * r
          vy = ny * r
          vz = nz * r

          mesh.vertices << vx << vy << vz
          mesh.normals << nx << ny << nz
          mesh.texcoords << u << v
          mesh.bounds.update(vx, vy, vz)
        end
      end

      (0...rings_cnt).each do |i|
        (0...slices_cnt).each do |j|
          first = (i * (slices_cnt + 1) + j).to_u16
          second = (first + slices_cnt + 1).to_u16
          mesh.indices << first << (first + 1_u16) << second
          mesh.indices << (first + 1_u16) << (second + 1_u16) << second
        end
      end

      mesh
    end

    # Procedural Mesh Generator: Cylinder
    def self.gen_cylinder(radius : Number, height : Number, slices : Int32 = 16) : Mesh
      mesh = Mesh.new("cylinder")
      r = radius.to_f32
      h = height.to_f32 * 0.5_f32
      sl = slices < 4 ? 4 : slices

      # Side vertices
      (0..sl).each do |i|
        u = i.to_f32 / sl.to_f32
        theta = u * Math::PI.to_f32 * 2.0_f32
        cos_t = Math.cos(theta)
        sin_t = Math.sin(theta)

        # Top vertex
        mesh.vertices << (r * cos_t) << h << (r * sin_t)
        mesh.normals << cos_t << 0.0_f32 << sin_t
        mesh.texcoords << u << 0.0_f32
        mesh.bounds.update(r * cos_t, h, r * sin_t)

        # Bottom vertex
        mesh.vertices << (r * cos_t) << -h << (r * sin_t)
        mesh.normals << cos_t << 0.0_f32 << sin_t
        mesh.texcoords << u << 1.0_f32
        mesh.bounds.update(r * cos_t, -h, r * sin_t)
      end

      # Side indices
      sl.times do |i|
        idx = (i * 2).to_u16
        mesh.indices << idx << (idx + 1_u16) << (idx + 2_u16)
        mesh.indices << (idx + 2_u16) << (idx + 1_u16) << (idx + 3_u16)
      end

      # Top and bottom caps
      top_center = mesh.vertex_count.to_u16
      mesh.vertices << 0.0_f32 << h << 0.0_f32
      mesh.normals << 0.0_f32 << 1.0_f32 << 0.0_f32
      mesh.texcoords << 0.5_f32 << 0.5_f32

      sl.times do |i|
        idx = (i * 2).to_u16
        mesh.indices << top_center << idx << (idx + 2_u16)
      end

      bot_center = mesh.vertex_count.to_u16
      mesh.vertices << 0.0_f32 << -h << 0.0_f32
      mesh.normals << 0.0_f32 << -1.0_f32 << 0.0_f32
      mesh.texcoords << 0.5_f32 << 0.5_f32

      sl.times do |i|
        idx = (i * 2 + 1).to_u16
        mesh.indices << bot_center << (idx + 2_u16) << idx
      end

      mesh
    end

    # Procedural Mesh Generator: Cone
    def self.gen_cone(radius : Number, height : Number, slices : Int32 = 16) : Mesh
      mesh = Mesh.new("cone")
      r = radius.to_f32
      h = height.to_f32
      sl = slices < 3 ? 3 : slices

      # Tip vertex
      tip_idx = 0_u16
      mesh.vertices << 0.0_f32 << h << 0.0_f32
      mesh.normals << 0.0_f32 << 1.0_f32 << 0.0_f32
      mesh.texcoords << 0.5_f32 << 0.0_f32
      mesh.bounds.update(0.0_f32, h, 0.0_f32)

      # Base circle vertices
      (0..sl).each do |i|
        u = i.to_f32 / sl.to_f32
        theta = u * Math::PI.to_f32 * 2.0_f32
        cos_t = Math.cos(theta)
        sin_t = Math.sin(theta)

        vx = r * cos_t
        vz = r * sin_t
        mesh.vertices << vx << 0.0_f32 << vz
        mesh.normals << cos_t << (r / h) << sin_t
        mesh.texcoords << u << 1.0_f32
        mesh.bounds.update(vx, 0.0_f32, vz)
      end

      # Cone body triangles
      sl.times do |i|
        b1 = (i + 1).to_u16
        b2 = (i + 2).to_u16
        mesh.indices << tip_idx << b1 << b2
      end

      # Bottom cap
      base_center = mesh.vertex_count.to_u16
      mesh.vertices << 0.0_f32 << 0.0_f32 << 0.0_f32
      mesh.normals << 0.0_f32 << -1.0_f32 << 0.0_f32
      mesh.texcoords << 0.5_f32 << 0.5_f32

      sl.times do |i|
        b1 = (i + 1).to_u16
        b2 = (i + 2).to_u16
        mesh.indices << base_center << b2 << b1
      end

      mesh
    end

    # Procedural Mesh Generator: Torus (Donut)
    def self.gen_torus(radius : Number, size : Number, rad_segments : Int32 = 16, sides : Int32 = 16) : Mesh
      mesh = Mesh.new("torus")
      r = radius.to_f32
      tube_r = size.to_f32
      segs = rad_segments < 4 ? 4 : rad_segments
      sd = sides < 4 ? 4 : sides

      (0..segs).each do |i|
        u = i.to_f32 / segs.to_f32
        u_ang = u * Math::PI.to_f32 * 2.0_f32
        cos_u = Math.cos(u_ang)
        sin_u = Math.sin(u_ang)

        (0..sd).each do |j|
          v = j.to_f32 / sd.to_f32
          v_ang = v * Math::PI.to_f32 * 2.0_f32
          cos_v = Math.cos(v_ang)
          sin_v = Math.sin(v_ang)

          vx = (r + tube_r * cos_v) * cos_u
          vy = tube_r * sin_v
          vz = (r + tube_r * cos_v) * sin_u

          nx = cos_v * cos_u
          ny = sin_v
          nz = cos_v * sin_u

          mesh.vertices << vx << vy << vz
          mesh.normals << nx << ny << nz
          mesh.texcoords << u << v
          mesh.bounds.update(vx, vy, vz)
        end
      end

      segs.times do |i|
        sd.times do |j|
          a = (i * (sd + 1) + j).to_u16
          b = ((i + 1) * (sd + 1) + j).to_u16
          c = ((i + 1) * (sd + 1) + (j + 1)).to_u16
          d = (i * (sd + 1) + (j + 1)).to_u16

          mesh.indices << a << b << d
          mesh.indices << b << c << d
        end
      end

      mesh
    end

    # Procedural Mesh Generator: Heightmap Terrain
    def self.gen_heightmap(heights : Array(Float32), grid_w : Int32, grid_h : Int32, size : Vector3) : Mesh
      mesh = Mesh.new("heightmap")
      dx = size.x / (grid_w - 1).to_f32
      dz = size.z / (grid_h - 1).to_f32

      grid_h.times do |z|
        grid_w.times do |x|
          idx = z * grid_w + x
          h = (heights[idx]? || 0.0_f32) * size.y
          vx = x.to_f32 * dx - size.x * 0.5_f32
          vz = z.to_f32 * dz - size.z * 0.5_f32

          mesh.vertices << vx << h << vz
          mesh.normals << 0.0_f32 << 1.0_f32 << 0.0_f32
          mesh.texcoords << (x.to_f32 / (grid_w - 1).to_f32) << (z.to_f32 / (grid_h - 1).to_f32)
          mesh.bounds.update(vx, h, vz)
        end
      end

      (grid_h - 1).times do |z|
        (grid_w - 1).times do |x|
          i0 = (z * grid_w + x).to_u16
          i1 = (z * grid_w + (x + 1)).to_u16
          i2 = ((z + 1) * grid_w + x).to_u16
          i3 = ((z + 1) * grid_w + (x + 1)).to_u16

          mesh.indices << i0 << i1 << i2
          mesh.indices << i1 << i3 << i2
        end
      end

      mesh
    end
  end

  # Composite 3D model containing multiple meshes, assigned materials, and transformation matrix.
  class Model
    property name : String
    property meshes : Array(Mesh)
    property materials : Array(Material)
    property mesh_materials : Array(Int32)
    property transform : Matrix4
    property bounds : BoundingBox
    property handle : UInt32

    def initialize(
      @name : String = "model",
      @meshes = [] of Mesh,
      @materials = [] of Material,
      @mesh_materials = [] of Int32,
      @handle : UInt32 = 0_u32
    )
      @transform = Matrix4.identity
      @bounds = BoundingBox.new
      recalculate_bounds
    end

    def recalculate_bounds
      @bounds = BoundingBox.new
      @meshes.each do |mesh|
        @bounds.update(mesh.bounds.min_x, mesh.bounds.min_y, mesh.bounds.min_z)
        @bounds.update(mesh.bounds.max_x, mesh.bounds.max_y, mesh.bounds.max_z)
      end
    end

    def self.load(path : String) : Model
      Citrine.load_model(path)
    end

    def draw(pos : Vector3, scale : Float32 = 1.0_f32, tint : Color = Color::White)
      Citrine.draw_model(self, pos, scale, tint)
    end

    def draw_ex(pos : Vector3, rotation_axis : Vector3, rotation_angle : Float32, scale : Vector3, tint : Color = Color::White)
      Citrine.draw_model_ex(self, pos, rotation_axis, rotation_angle, scale, tint)
    end

    def unload
      Citrine.unload_model(self)
    end
  end

  # High-level 3D perspective drawing DSL for PlayStation 2 Graphics Synthesizer
  module Draw3D
    # Executes a block in 3D perspective mode with given `camera`.
    # Automatically restores 2D orthographic projection on block exit.
    def self.mode(camera : Camera3D, &block : Citrine::Draw3D.class -> Nil)
      Citrine.begin_mode_3d(camera)
      begin
        yield self
      ensure
        Citrine.end_mode_3d
      end
    end

    # Executes a block in 3D mode with default camera.
    def self.mode(&block : Citrine::Draw3D.class -> Nil)
      Citrine.begin_mode_3d
      begin
        yield self
      ensure
        Citrine.end_mode_3d
      end
    end

    # Renders a 3D solid cube at position `pos` with dimensions `(w, h, l)` and `color`.
    def self.cube(pos : Vector3, w : Number, h : Number, l : Number, color : Color = Color::White)
      Citrine.draw_cube(pos.x, pos.y, pos.z, w, h, l, color)
    end

    # Renders a 3D solid cube at coordinates `(x, y, z)` with dimensions `(w, h, l)` and `color`.
    def self.cube(x : Number, y : Number, z : Number, w : Number, h : Number, l : Number, color : Color = Color::White)
      Citrine.draw_cube(x, y, z, w, h, l, color)
    end

    # Renders a 3D wireframe cube at position `pos` with dimensions `(w, h, l)` and `color`.
    def self.cube_wires(pos : Vector3, w : Number, h : Number, l : Number, color : Color = Color::White)
      Citrine.draw_cube_wires(pos.x, pos.y, pos.z, w, h, l, color)
    end

    # Renders a 3D wireframe cube at coordinates `(x, y, z)` with dimensions `(w, h, l)` and `color`.
    def self.cube_wires(x : Number, y : Number, z : Number, w : Number, h : Number, l : Number, color : Color = Color::White)
      Citrine.draw_cube_wires(x, y, z, w, h, l, color)
    end

    # Renders a 3D ground plane grid with `slices` lines spaced `spacing` units apart.
    def self.grid(slices : Int32 = 10, spacing : Number = 1.0)
      Citrine.draw_grid(slices, spacing)
    end

    # Renders a 3D mesh resource identified by `mesh_id` at `pos` with optional `tint`.
    def self.mesh(mesh_id : UInt32, pos : Vector3, tint : Color = Color::White)
      Citrine.draw_mesh(mesh_id, pos.x, pos.y, pos.z, tint)
    end

    # Renders a 3D mesh resource identified by `mesh_id` at `(x, y, z)` with optional `tint`.
    def self.mesh(mesh_id : UInt32, x : Number, y : Number, z : Number, tint : Color = Color::White)
      Citrine.draw_mesh(mesh_id, x, y, z, tint)
    end

    # Renders a `Model` instance at `pos` with uniform `scale` and optional `tint`.
    def self.model(m : Model, pos : Vector3, scale : Float32 = 1.0_f32, tint : Color = Color::White)
      Citrine.draw_model(m, pos, scale, tint)
    end

    # Renders a `Model` instance with full transform (rotation axis, angle, non-uniform scale, tint).
    def self.model_ex(m : Model, pos : Vector3, rotation_axis : Vector3, rotation_angle : Float32, scale : Vector3, tint : Color = Color::White)
      Citrine.draw_model_ex(m, pos, rotation_axis, rotation_angle, scale, tint)
    end

    # Renders a single 3D triangle defined by three vertices in world space.
    def self.triangle(v1 : Vector3, v2 : Vector3, v3 : Vector3, color : Color = Color::White)
      Citrine.draw_triangle_3d(v1, v2, v3, color)
    end

    # Renders a camera-facing textured billboard in 3D world space.
    def self.billboard(camera : Camera3D, texture : Texture, pos : Vector3, size : Float32, tint : Color = Color::White)
      Citrine.draw_billboard(camera, texture, pos, size, tint)
    end
  end

  # Scoped 3D rendering frame helper yielding `Citrine::Draw3D`.
  def self.draw_3d(camera : Camera3D? = nil, &block : Citrine::Draw3D.class -> Nil)
    if cam = camera
      Citrine::Draw3D.mode(cam, &block)
    else
      Citrine::Draw3D.mode(&block)
    end
  end

  # =========================================================================
  # 3D Model & Mesh Engine Methods
  # =========================================================================

  # Loads a 3D model (.cbm, .glb, or .obj) from optical disc or host filesystem.
  def self.load_model(path : String) : Model
    handle = Citrine.load_model_handle(path)
    Model.new(name: File.basename(path), handle: handle)
  end

  # Low-level handle loader dispatched to native VM
  def self.load_model_handle(path : String) : UInt32
    1_u32
  end

  # Frees GPU memory and unloads textures associated with a model.
  def self.unload_model(model : Model)
  end

  # Draws a 3D model at position `pos` with uniform `scale` and `tint`.
  def self.draw_model(model : Model, position : Vector3, scale : Float32 = 1.0_f32, tint : Color = Color::White)
    Citrine.draw_model_native(model.handle, position.x, position.y, position.z, scale, tint)
  end

  # Low-level VM native call for drawing models
  def self.draw_model_native(handle : UInt32, x : Float32, y : Float32, z : Float32, scale : Float32, tint : Color)
  end

  # Draws a 3D model with full transform parameters (position, rotation axis, angle, non-uniform scale, tint).
  def self.draw_model_ex(model : Model, position : Vector3, rotation_axis : Vector3, rotation_angle : Float32, scale : Vector3, tint : Color = Color::White)
    Citrine.draw_model_ex_native(
      model.handle,
      position.x, position.y, position.z,
      rotation_axis.x, rotation_axis.y, rotation_axis.z,
      rotation_angle,
      scale.x, scale.y, scale.z,
      tint
    )
  end

  # Low-level VM native call for DrawModelEx
  def self.draw_model_ex_native(
    handle : UInt32,
    x : Float32, y : Float32, z : Float32,
    rx : Float32, ry : Float32, rz : Float32,
    angle : Float32,
    sx : Float32, sy : Float32, sz : Float32,
    tint : Color
  )
  end

  # Renders a single mesh with given material and matrix transform.
  def self.draw_mesh(mesh : Mesh, material : Material, transform : Matrix4)
    Citrine.draw_mesh_native(mesh, material, transform)
  end

  def self.draw_mesh_native(mesh : Mesh, material : Material, transform : Matrix4)
  end

  # Renders a single 3D triangle defined by three 3D vertices.
  def self.draw_triangle_3d(v1 : Vector3, v2 : Vector3, v3 : Vector3, color : Color = Color::White)
    Citrine.draw_triangle_3d_native(v1.x, v1.y, v1.z, v2.x, v2.y, v2.z, v3.x, v3.y, v3.z, color)
  end

  def self.draw_triangle_3d_native(x1 : Float32, y1 : Float32, z1 : Float32, x2 : Float32, y2 : Float32, z2 : Float32, x3 : Float32, y3 : Float32, z3 : Float32, color : Color)
  end

  # Renders a camera-facing textured billboard in 3D perspective space.
  def self.draw_billboard(camera : Camera3D, texture : Texture, position : Vector3, size : Float32, tint : Color = Color::White)
    Citrine.draw_billboard_native(texture.handle, camera.position.x, camera.position.y, camera.position.z, position.x, position.y, position.z, size, tint)
  end

  def self.draw_billboard_native(tex_id : UInt32, cx : Float32, cy : Float32, cz : Float32, px : Float32, py : Float32, pz : Float32, size : Float32, tint : Color)
  end

  # Returns the default system 3D material.
  def self.load_material_default : Material
    Material.default
  end

  # Macro placeholder for compile-time disc model baking
  def self.bake_model(path : String, target : String? = nil, texture_size : Int32 = 128, clut : Int32 = 8) : String
    target || File.basename(path).sub(/\.(glb|gltf|obj)$/i, ".cbm")
  end

  # Macro placeholder for compile-time disc mesh baking
  def self.bake_mesh(path : String, target : String? = nil) : String
    target || File.basename(path).sub(/\.(glb|gltf|obj)$/i, ".cbm")
  end
end

# Top-level DSL aliases
Draw3D = Citrine::Draw3D
Material = Citrine::Material
Mesh = Citrine::Mesh
Model = Citrine::Model

def bake_model(path : String, target : String? = nil, texture_size : Int32 = 128, clut : Int32 = 8) : String
  Citrine.bake_model(path, target, texture_size, clut)
end

def bake_mesh(path : String, target : String? = nil) : String
  Citrine.bake_mesh(path, target)
end

def load_model(path : String) : Model
  Citrine.load_model(path)
end

def unload_model(model : Model)
  Citrine.unload_model(model)
end

def draw_model(model : Model, position : Vector3, scale : Float32 = 1.0_f32, tint : Color = Color::White)
  Citrine.draw_model(model, position, scale, tint)
end

def draw_model_ex(model : Model, position : Vector3, rotation_axis : Vector3, rotation_angle : Float32, scale : Vector3, tint : Color = Color::White)
  Citrine.draw_model_ex(model, position, rotation_axis, rotation_angle, scale, tint)
end

def draw_triangle_3d(v1 : Vector3, v2 : Vector3, v3 : Vector3, color : Color = Color::White)
  Citrine.draw_triangle_3d(v1, v2, v3, color)
end

def draw_billboard(camera : Camera3D, texture : Texture, position : Vector3, size : Float32, tint : Color = Color::White)
  Citrine.draw_billboard(camera, texture, position, size, tint)
end
