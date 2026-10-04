# Citrine PlayStation 2 Shader Framework (VU1 Microcode & GS Multi-Pass)
# Modular hardware abstraction - require "citrine/shader"

module Citrine
  # Programmable shading pipeline leveraging Vector Unit 1 (VU1) microcode
  # for geometric vertex shaders and Graphics Synthesizer multi-pass rendering for post-processing.
  module Shader
    # Post-processing and rasterization effect types.
    enum EffectType
      # Standard unshaded rasterization.
      Default
      # Brightness extraction and gaussian blur accumulation.
      Bloom
      # Framebuffer temporal accumulation blur.
      MotionBlur
      # CRT-style raster scanline overlay.
      Scanlines
      # Color matrix remapping / look-up table tint.
      ColorGrade
      # Framebuffer UV displacement heat distortion.
      HeatHaze
      # Toon lighting quantization with black silhouette outlining.
      CelShading
    end

    # Represents an individual post-processing pass dispatched to the GS.
    class EffectPass
      # Effect filter type.
      property effect : EffectType
      # Effect intensity multiplier.
      property intensity : Float32
      # Hardware alpha blend factor (0-255).
      property alpha_blend : UInt8

      # Creates a new effect pass.
      def initialize(@effect : EffectType, @intensity : Float32 = 1.0_f32, @alpha_blend : UInt8 = 128_u8)
      end
    end

    # Configurable shader pipeline coordinating VU1 vertex microcode and GS multi-pass chains.
    class Pipeline
      # Pipeline human-readable name.
      property name : String
      # Enables sinusoidal vertex displacement wave deformation.
      property wave_deform : Bool
      # Wave deformation height amplitude in world units.
      property wave_amplitude : Float32
      # Wave deformation spatial frequency.
      property wave_frequency : Float32
      # Enables hardware directional lighting calculations.
      property lighting_enabled : Bool
      # Ordered list of post-processing passes.
      getter passes : Array(EffectPass)

      # Creates a new named shader pipeline.
      def initialize(@name : String)
        @wave_deform = false
        @wave_amplitude = 0.0_f32
        @wave_frequency = 0.0_f32
        @lighting_enabled = true
        @passes = [] of EffectPass
      end

      # Configures VU1 Coprocessor 2 Vertex Shading Pipeline sinusoidal wave parameters.
      def vertex_wave(amplitude : Float32, frequency : Float32)
        @wave_deform = true
        @wave_amplitude = amplitude
        @wave_frequency = frequency
      end

      # Appends a GS 48 GB/s multi-pass render-to-texture effect to the pipeline.
      def add_pass(effect : EffectType, intensity : Float32 = 1.0_f32, alpha : UInt8 = 128_u8)
        @passes << EffectPass.new(effect, intensity, alpha)
      end

      # Applies per-vertex VU1 deformation to vertex `(vx, vy, vz)` at simulation timestamp `time`.
      def transform_vertex(vx : Float32, vy : Float32, vz : Float32, time : Float32) : Tuple(Float32, Float32, Float32)
        if @wave_deform
          offset_y = Math.sin(vx * @wave_frequency + time * 3.0_f32) * @wave_amplitude
          {vx, vy + offset_y, vz}
        else
          {vx, vy, vz}
        end
      end
    end

    # Builds and yields a new `Pipeline` block, returning the configured pipeline.
    def self.create(name : String, &block : Pipeline -> Nil) : Pipeline
      pipe = Pipeline.new(name)
      yield pipe
      pipe
    end
  end
end
