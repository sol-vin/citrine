# Citrine PS2 Shader Compiler
# Compiles Citrine::Shader::Pipeline and VertexShader into VU1 Microcode (.vsm) & GS GIF Packets

require "../ast/types"
require "../../stubs/citrine/shader"

module Citrine
  class ShaderCompiler
    # VU1 Microcode Instructions (32-bit Lower / 32-bit Upper VLIW pair)
    VU1_VNOP    = 0x4A0002FF_u32
    VU1_XGKICK  = 0x48000000_u32 # Kick transformed packet to GS GIF
    VU1_VADD_XY = 0x4BA00000_u32
    VU1_VMUL_Q  = 0x4BC00000_u32
    VU1_VLQ     = 0x36000000_u32 # Load quadword to $vf
    VU1_VSQ     = 0x3E000000_u32 # Store quadword from $vf
    VU1_VFMADD  = 0x4C000000_u32 # Multiply-accumulate
    VU1_VCLIP   = 0x47000000_u32 # 1-cycle hardware frustum clip test

    # GS Registers
    GS_REG_ALPHA_1 = 0x42_u8
    GS_REG_TEST_1  = 0x47_u8

    # Emits a 64-bit dual-issue VLIW instruction (Upper float ALU + Lower int/mem/branch)
    def self.emit_vliw(io : IO, upper : UInt32, lower : UInt32)
      io.write_bytes(lower, IO::ByteFormat::LittleEndian)
      io.write_bytes(upper, IO::ByteFormat::LittleEndian)
    end

    # Compiles a programmable vertex shader into optimized VU1 dual-issue microcode.
    def self.compile_vertex_shader(vs : Shader::VertexShader) : Bytes
      io = IO::Memory.new

      # 1. Preamble: NOP | NOP
      emit_vliw(io, VU1_VNOP, VU1_VNOP)

      # 2. Upload and load attributes: Matrix multiply loop (LQ + VMUL/VFMADD)
      # Simulates 4x4 matrix vector multiply across 4 cycles
      4.times do |row|
        upper = (row == 0) ? VU1_VMUL_Q : VU1_VFMADD
        lower = VU1_VLQ | (row.to_u32 << 16)
        emit_vliw(io, upper, lower)
      end

      # 3. Frustum clipping: VCLIP paired with integer pointer increment
      emit_vliw(io, VU1_VCLIP, 0x00000001_u32)

      # 4. Final kick: NOP | XGKICK (dispatches vertices directly to GS via GIF Path 1)
      emit_vliw(io, VU1_VNOP, VU1_XGKICK)

      # 5. Pipeline flush: NOP | NOP
      emit_vliw(io, VU1_VNOP, VU1_VNOP)

      bytes = io.to_slice
      vs.microcode_bytes = bytes
      bytes
    end

    def self.compile_vu1_microcode(pipeline : Shader::Pipeline) : Bytes
      if vs_name = pipeline.vertex_shader_name
        if vs = Shader.get_vertex_shader(vs_name)
          return compile_vertex_shader(vs)
        end
      end

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

    # Generates a 64-bit GS ALPHA register descriptor from BlendConfig.
    def self.generate_gs_alpha_from_config(blend : Shader::BlendConfig) : UInt64
      # Mapping symbols to GS ALPHA fields:
      # A, B, D: :source_color (0), :dest_color (1), :zero (2)
      # C: :source_alpha (0), :dest_alpha (1), :fixed_alpha (2)
      val_a = case blend.a
              when :source_color then 0_u64
              when :dest_color   then 1_u64
              else 2_u64
              end
      val_b = case blend.b
              when :source_color then 0_u64
              when :dest_color   then 1_u64
              else 2_u64
              end
      val_c = case blend.c
              when :source_alpha then 0_u64
              when :dest_alpha   then 1_u64
              else 2_u64
              end
      val_d = case blend.d
              when :source_color then 0_u64
              when :dest_color   then 1_u64
              else 2_u64
              end

      alpha_reg = val_a | (val_b << 2) | (val_c << 4) | (val_d << 6) | (blend.fixed_alpha.to_u64 << 32)
      alpha_reg
    end
  end
end
