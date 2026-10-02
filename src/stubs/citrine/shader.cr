# Citrine PlayStation 2 Shader Framework (VU1 Microcode & GS Multi-Pass)
# Modular hardware abstraction - require "citrine/shader"

module Citrine
  module Shader
    enum EffectType
      Default
      Bloom
      MotionBlur
      Scanlines
      ColorGrade
      HeatHaze
      CelShading
    end

    class EffectPass
      property effect : EffectType
      property intensity : Float32
      property alpha_blend : UInt8

      def initialize(@effect : EffectType, @intensity : Float32 = 1.0_f32, @alpha_blend : UInt8 = 128_u8)
      end
    end

    class Pipeline
      property name : String
      property wave_deform : Bool
      property wave_amplitude : Float32
      property wave_frequency : Float32
      property lighting_enabled : Bool
      getter passes : Array(EffectPass)

      def initialize(@name : String)
        @wave_deform = false
        @wave_amplitude = 0.0_f32
        @wave_frequency = 0.0_f32
        @lighting_enabled = true
        @passes = [] of EffectPass
      end

      # Configures VU1 Coprocessor 2 Vertex Shading Pipeline
      def vertex_wave(amplitude : Float32, frequency : Float32)
        @wave_deform = true
        @wave_amplitude = amplitude
        @wave_frequency = frequency
      end

      # Configures GS 48 GB/s Multi-Pass Render-to-Texture Effect
      def add_pass(effect : EffectType, intensity : Float32 = 1.0_f32, alpha : UInt8 = 128_u8)
        @passes << EffectPass.new(effect, intensity, alpha)
      end

      # Applies per-vertex VU1 deformation to a 3D vertex
      def transform_vertex(vx : Float32, vy : Float32, vz : Float32, time : Float32) : Tuple(Float32, Float32, Float32)
        if @wave_deform
          offset_y = Math.sin(vx * @wave_frequency + time * 3.0_f32) * @wave_amplitude
          {vx, vy + offset_y, vz}
        else
          {vx, vy, vz}
        end
      end
    end

    def self.create(name : String, &block : Pipeline -> Nil) : Pipeline
      pipe = Pipeline.new(name)
      yield pipe
      pipe
    end
  end
end
