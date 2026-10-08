# Citrine PlayStation 2 Shader Framework (VU1 Microcode & GS Multi-Pass)
# Modular hardware abstraction - require "citrine/shader"

module Citrine
  # Programmable shading pipeline leveraging Vector Unit 1 (VU1) microcode
  # for geometric vertex shaders and Graphics Synthesizer multi-pass rendering for post-processing.
  module Shader
    # =========================================================================
    # Programmable Vector & Matrix Types (128-bit SIMD Quadwords)
    # =========================================================================

    # 2D floating-point vector.
    struct Vec2
      property x : Float32
      property y : Float32

      def initialize(@x : Float32 = 0.0_f32, @y : Float32 = 0.0_f32)
      end

      def initialize(x : Number, y : Number)
        @x = x.to_f32
        @y = y.to_f32
      end

      def +(other : Vec2) : Vec2
        Vec2.new(@x + other.x, @y + other.y)
      end

      def -(other : Vec2) : Vec2
        Vec2.new(@x - other.x, @y - other.y)
      end

      def *(s : Number) : Vec2
        Vec2.new(@x * s.to_f32, @y * s.to_f32)
      end
    end

    # 3D floating-point vector.
    struct Vec3
      property x : Float32
      property y : Float32
      property z : Float32

      def initialize(@x : Float32 = 0.0_f32, @y : Float32 = 0.0_f32, @z : Float32 = 0.0_f32)
      end

      def initialize(x : Number, y : Number, z : Number)
        @x = x.to_f32
        @y = y.to_f32
        @z = z.to_f32
      end

      def +(other : Vec3) : Vec3
        Vec3.new(@x + other.x, @y + other.y, @z + other.z)
      end

      def -(other : Vec3) : Vec3
        Vec3.new(@x - other.x, @y - other.y, @z - other.z)
      end

      def *(s : Number) : Vec3
        Vec3.new(@x * s.to_f32, @y * s.to_f32, @z * s.to_f32)
      end

      def dot(other : Vec3) : Float32
        @x * other.x + @y * other.y + @z * other.z
      end

      def cross(other : Vec3) : Vec3
        Vec3.new(
          @y * other.z - @z * other.y,
          @z * other.x - @x * other.z,
          @x * other.y - @y * other.x
        )
      end

      def length : Float32
        Math.sqrt(@x * @x + @y * @y + @z * @z).to_f32
      end

      def normalize : Vec3
        l = length
        l > 0.0_f32 ? Vec3.new(@x / l, @y / l, @z / l) : self
      end
    end

    # 4D floating-point vector matching 128-bit VU1 $vf register quadwords.
    struct Vec4
      property x : Float32
      property y : Float32
      property z : Float32
      property w : Float32

      def initialize(
        @x : Float32 = 0.0_f32,
        @y : Float32 = 0.0_f32,
        @z : Float32 = 0.0_f32,
        @w : Float32 = 1.0_f32
      )
      end

      def initialize(x : Number, y : Number, z : Number, w : Number = 1.0)
        @x = x.to_f32
        @y = y.to_f32
        @z = z.to_f32
        @w = w.to_f32
      end

      def +(other : Vec4) : Vec4
        Vec4.new(@x + other.x, @y + other.y, @z + other.z, @w + other.w)
      end

      def -(other : Vec4) : Vec4
        Vec4.new(@x - other.x, @y - other.y, @z - other.z, @w - other.w)
      end

      def *(s : Number) : Vec4
        Vec4.new(@x * s.to_f32, @y * s.to_f32, @z * s.to_f32, @w * s.to_f32)
      end

      def xyz : Vec3
        Vec3.new(@x, @y, @z)
      end

      def xy : Vec2
        Vec2.new(@x, @y)
      end

      def dot(other : Vec4) : Float32
        @x * other.x + @y * other.y + @z * other.z + @w * other.w
      end
    end

    # 4x4 matrix for 3D perspective and affine transformations.
    struct Mat4
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

      def self.identity : Mat4
        Mat4.new
      end

      def *(v : Vec4) : Vec4
        tx = @m[0]*v.x + @m[4]*v.y + @m[8]*v.z  + @m[12]*v.w
        ty = @m[1]*v.x + @m[5]*v.y + @m[9]*v.z  + @m[13]*v.w
        tz = @m[2]*v.x + @m[6]*v.y + @m[10]*v.z + @m[14]*v.w
        tw = @m[3]*v.x + @m[7]*v.y + @m[11]*v.z + @m[15]*v.w
        Vec4.new(tx, ty, tz, tw)
      end

      def *(other : Mat4) : Mat4
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
        Mat4.new(res)
      end
    end

    # =========================================================================
    # GLSL-like Programmable Vertex Shader DSL
    # =========================================================================

    struct ShaderVariable
      property name : String
      property type_name : String

      def initialize(@name : String, @type_name : String)
      end
    end

    # Declarative vertex shader compiling to VU1 dual-issue VLIW microcode.
    class VertexShader
      property name : String
      property uniforms : Hash(String, ShaderVariable)
      property inputs : Hash(String, ShaderVariable)
      property outputs : Hash(String, ShaderVariable)
      property body : Proc(Vec4, Vec3, Vec2, Vec4, Tuple(Vec4, Vec4, Vec2))?
      property microcode_bytes : Bytes?

      def initialize(@name : String)
        @uniforms = Hash(String, ShaderVariable).new
        @inputs = Hash(String, ShaderVariable).new
        @outputs = Hash(String, ShaderVariable).new
        @body = nil
        @microcode_bytes = nil
      end

      def uniform(name : String | Symbol, type_name : String)
        @uniforms[name.to_s] = ShaderVariable.new(name.to_s, type_name)
      end

      def input(name : String | Symbol, type_name : String)
        @inputs[name.to_s] = ShaderVariable.new(name.to_s, type_name)
      end

      def output(name : String | Symbol, type_name : String)
        @outputs[name.to_s] = ShaderVariable.new(name.to_s, type_name)
      end

      # Defines programmable per-vertex execution logic:
      # takes (position, normal, uv, color) and returns (out_pos, out_color, out_uv)
      def main(&block : (Vec4, Vec3, Vec2, Vec4) -> Tuple(Vec4, Vec4, Vec2))
        @body = block
      end
    end

    @@active_vertex_shaders = Hash(String, VertexShader).new

    # Programmable vertex shader builder:
    # ```crystal
    # Citrine::Shader.vertex "LitWave" do |s|
    #   s.uniform :mvp, "Mat4"
    #   s.uniform :light_dir, "Vec3"
    #   s.input :position, "Vec4"
    #   s.input :normal, "Vec3"
    #   s.output :out_pos, "Vec4"
    #   s.output :out_color, "Vec4"
    #
    #   s.main do |pos, norm, uv, col|
    #     { pos, col, uv }
    #   end
    # end
    # ```
    def self.vertex(name : String, &block : VertexShader -> Nil) : VertexShader
      vs = VertexShader.new(name)
      yield vs
      @@active_vertex_shaders[name] = vs
      vs
    end

    def self.get_vertex_shader(name : String) : VertexShader?
      @@active_vertex_shaders[name]?
    end

    # =========================================================================
    # Rasterizer & GS Blending Pipeline Configuration
    # =========================================================================

    enum DepthFunc
      Never
      Always
      Less
      LEqual
      Greater
      GEqual
    end

    enum CullMode
      None
      Front
      Back
    end

    enum TexFunc
      Modulate
      Decal
      Highlight
    end

    struct RasterConfig
      property depth_test : DepthFunc = DepthFunc::LEqual
      property cull_mode : CullMode = CullMode::Back
      property tex_func : TexFunc = TexFunc::Modulate
      property wireframe : Bool = false
    end

    struct BlendConfig
      property a : Symbol = :source_color
      property b : Symbol = :dest_color
      property c : Symbol = :source_alpha
      property d : Symbol = :dest_color
      property fixed_alpha : UInt8 = 128_u8
    end

    # =========================================================================
    # Backward-Compatible Multi-Pass & Effect Framework
    # =========================================================================

    # Post-processing and rasterization effect types.
    enum EffectType
      Default
      Bloom
      MotionBlur
      Scanlines
      ColorGrade
      HeatHaze
      CelShading
      Glitch
      PaletteSwap
      Quantize
      RainbowCycle
    end

    # Represents an individual post-processing pass dispatched to the GS.
    class EffectPass
      property effect : EffectType
      property intensity : Float32
      property alpha_blend : UInt8

      def initialize(@effect : EffectType, @intensity : Float32 = 1.0_f32, @alpha_blend : UInt8 = 128_u8)
      end
    end

    # Configurable shader pipeline coordinating VU1 vertex microcode and GS multi-pass chains.
    class Pipeline
      property name : String
      property wave_deform : Bool
      property wave_amplitude : Float32
      property wave_frequency : Float32
      property lighting_enabled : Bool
      property raster : RasterConfig
      property blend : BlendConfig
      property vertex_shader_name : String?
      getter passes : Array(EffectPass)

      def initialize(@name : String)
        @wave_deform = false
        @wave_amplitude = 0.0_f32
        @wave_frequency = 0.0_f32
        @lighting_enabled = true
        @raster = RasterConfig.new
        @blend = BlendConfig.new
        @vertex_shader_name = nil
        @passes = [] of EffectPass
      end

      def vertex_shader(name : String)
        @vertex_shader_name = name
      end

      def vertex_wave(amplitude : Float32, frequency : Float32)
        @wave_deform = true
        @wave_amplitude = amplitude
        @wave_frequency = frequency
      end

      def add_pass(effect : EffectType, intensity : Float32 = 1.0_f32, alpha : UInt8 = 128_u8)
        @passes << EffectPass.new(effect, intensity, alpha)
      end

      def transform_vertex(vx : Float32, vy : Float32, vz : Float32, time : Float32) : Tuple(Float32, Float32, Float32)
        if @wave_deform
          offset_y = Math.sin(vx * @wave_frequency + time * 3.0_f32) * @wave_amplitude
          {vx, vy + offset_y, vz}
        else
          {vx, vy, vz}
        end
      end
    end

    # Pipeline builder helper:
    def self.pipeline(name : String, &block : Pipeline -> Nil) : Pipeline
      pipe = Pipeline.new(name)
      yield pipe
      pipe
    end

    # Builds and yields a new `Pipeline` block, returning the configured pipeline.
    def self.create(name : String, &block : Pipeline -> Nil) : Pipeline
      pipe = Pipeline.new(name)
      yield pipe
      pipe
    end
  end
end
