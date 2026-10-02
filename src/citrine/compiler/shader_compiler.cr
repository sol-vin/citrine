# Citrine PS2 Shader Compiler
# Compiles Citrine::Shader::Pipeline into VU1 Microcode (.vsm) & GS GIF Packets

require "../ast/types"
require "../../stubs/citrine/shader"

module Citrine
  class ShaderCompiler
    # VU1 Microcode Instructions (32-bit Lower / 32-bit Upper VLIW pair)
    VU1_VNOP    = 0x4A0002FF_u32
    VU1_XGKICK  = 0x48000000_u32 # Kick transformed packet to GS GIF
    VU1_VADD_XY = 0x4BA00000_u32
    VU1_VMUL_Q  = 0x4BC00000_u32

    # GS Registers
    GS_REG_ALPHA_1 = 0x42_u8
    GS_REG_TEST_1  = 0x47_u8

    def self.compile_vu1_microcode(pipeline : Shader::Pipeline) : Bytes
      io = IO::Memory.new

      # Header / Microcode preamble
      # 1. vnop (Upper) | vnop (Lower)
      io.write_bytes(VU1_VNOP, IO::ByteFormat::LittleEndian)
      io.write_bytes(VU1_VNOP, IO::ByteFormat::LittleEndian)

      if pipeline.wave_deform
        # Emit wave vertex deformation microcode loop
        # vmul.xyzw vf01, vf01, vf02 (frequency scaling)
        io.write_bytes(VU1_VMUL_Q, IO::ByteFormat::LittleEndian)
        io.write_bytes(VU1_VNOP, IO::ByteFormat::LittleEndian)

        # vadd.xyzw vf03, vf03, vf04 (amplitude displacement)
        io.write_bytes(VU1_VADD_XY, IO::ByteFormat::LittleEndian)
        io.write_bytes(VU1_VNOP, IO::ByteFormat::LittleEndian)
      end

      # xgkick: dump transformed vertex packet directly to GS GIF
      io.write_bytes(VU1_XGKICK, IO::ByteFormat::LittleEndian)
      io.write_bytes(VU1_VNOP, IO::ByteFormat::LittleEndian)

      io.to_slice
    end

    def self.generate_gs_blend_packet(pass : Shader::EffectPass) : UInt64
      # GS ALPHA register configuration:
      # Bits 0-1: A (0=Cs, 1=Cd, 2=0)
      # Bits 2-3: B (0=Cs, 1=Cd, 2=0)
      # Bits 4-5: C (0=As, 1=Ad, 2=FIX)
      # Bits 6-7: D (0=Cs, 1=Cd, 2=0)
      # Bits 32-39: FIX alpha value
      case pass.effect
      when Shader::EffectType::Bloom
        # Additive blend: (Cs - 0) * FIX + Cd -> A=0, B=2, C=2, D=1
        0x00000000_00000021_u64 | (pass.alpha_blend.to_u64 << 32)
      when Shader::EffectType::MotionBlur
        # Blend with accumulation: (Cs - Cd) * As + Cd -> A=0, B=1, C=0, D=1
        0x00000000_00000044_u64 | (pass.alpha_blend.to_u64 << 32)
      else
        # Standard alpha blend: (Cs - Cd) * As + Cd
        0x00000000_00000044_u64
      end
    end
  end
end
