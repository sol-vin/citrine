require "../spec_helper"
require "../../src/citrine/core/vu1"
require "../../src/citrine/dsl/vu1"

describe "Citrine.vu1_program & Citrine::VU1 (Declarative VU1 Microcode DSL)" do
  describe "Declarative Program Builder & Symbolic Register Aliasing" do
    it "builds a VU1 microprogram via Citrine.vu1_program with symbolic register aliases and auto_halt" do
      prog = Citrine.vu1_program("aliased_transform", auto_halt: true) do |vu|
        vu.alias_vf(:pos, :vf01)
        vu.alias_vf(:vel, :vf02)
        vu.alias_vf(:out_pos, :vf03)
        vu.alias_vi(:ptr, :vi01)

        vu.lq(:pos, :ptr, 0)
        vu.lq(:vel, :ptr, 1)
        vu.add(:out_pos, :pos, :vel, mask: :xyz)
        vu.nop(3)
        vu.sq(:out_pos, :ptr, 2)
      end

      prog.name.should eq("aliased_transform")
      # 2 LQ + 1 ADD + 3 NOP + 1 SQ + 2 auto_halt (NOP[E] + delay NOP) = 9 instructions
      prog.size.should eq(9)
      prog.byte_size.should eq(72)
      prog.hazard_report.clean?.should be_true
      prog.instructions[-2].upper.flag_e?.should be_true
      prog.instructions[-1].upper.flag_e?.should be_false
    end

    it "emits hazard-free counted hardware loops via vu.loop without ViBranchHazard" do
      prog = Citrine.vu1_program("counted_vertex_loop") do |vu|
        vu.iaddiu(:vi01, :vi00, 0)
        vu.loop(:vi02, count: 16, name: :vtx_loop) do
          vu.lqi(:vf01, :vi01)
          vu.add(:vf01, :vf01, :vf00, mask: :xyz)
          vu.nop(3)
          vu.sqi(:vf01, :vi03)
        end
        vu.end_program
      end

      prog.labels.has_key?("vtx_loop").should be_true
      prog.hazard_report.has_errors?.should be_false
      prog.hazard_report.clean?.should be_true
    end
  end

  describe "Vector & Matrix Math Macros" do
    it "expands load_matrix4, mat4_mul_vec4, and compile-time mat4_mul_vec4_macro" do
      prog = Citrine.vu1_program("matrix_vector_transform") do |vu|
        vu.load_matrix4(:vi01, offset: 0, rows: [:vf01, :vf02, :vf03, :vf04])
        vu.lq(:vf05, :vi01, 4)

        # Runtime builder method
        vu.mat4_mul_vec4(:vf06, [:vf01, :vf02, :vf03, :vf04], :vf05, wait_fmac: true)

        # Compile-time macro expansion
        Citrine::VU1.mat4_mul_vec4_macro(vu, :vf07, :vf01, :vf02, :vf03, :vf04, :vf05)
        vu.end_program
      end

      prog.hazard_report.has_errors?.should be_false
      prog.hazard_report.clean?.should be_true
      # Verify MULAx, MADDAy, MADDAz, MADDw opcodes at PC 5..8
      prog.instructions[5].upper.op.should eq(Citrine::VU1::UpperOp::MULABC)
      prog.instructions[5].upper.bc.should eq(Citrine::VU1::Broadcast::X)
      prog.instructions[6].upper.op.should eq(Citrine::VU1::UpperOp::MADDABC)
      prog.instructions[6].upper.bc.should eq(Citrine::VU1::Broadcast::Y)
      prog.instructions[7].upper.op.should eq(Citrine::VU1::UpperOp::MADDABC)
      prog.instructions[7].upper.bc.should eq(Citrine::VU1::Broadcast::Z)
      prog.instructions[8].upper.op.should eq(Citrine::VU1::UpperOp::MADDBC)
      prog.instructions[8].upper.bc.should eq(Citrine::VU1::Broadcast::W)
      prog.instructions[8].upper.fd.should eq(6_u8)
    end

    it "expands 16-instruction 4x4 matrix-matrix multiplication (mat4_mul_mat4)" do
      prog = Citrine.vu1_program("mat4_concat") do |vu|
        vu.mat4_mul_mat4(
          dst_rows: [:vf09, :vf10, :vf11, :vf12],
          lhs_rows: [:vf01, :vf02, :vf03, :vf04],
          rhs_rows: [:vf05, :vf06, :vf07, :vf08]
        )
        vu.end_program
      end

      # 16 matrix-multiply instructions + 2 end_program instructions = 18
      prog.size.should eq(18)
      prog.hazard_report.clean?.should be_true
    end

    it "expands dot3, dot4, cross3, and normalize3 without pipeline hazards" do
      prog = Citrine.vu1_program("vector_algebra") do |vu|
        vu.dot3(:vf03, :vf01, :vf02, scratch_vf: :vf28, wait_fmac: true)
        vu.dot4(:vf04, :vf01, :vf02, scratch_vf: :vf29, wait_fmac: true)
        vu.cross3(:vf05, :vf01, :vf02, wait_fmac: true)
        Citrine::VU1.cross3_macro(vu, :vf06, :vf01, :vf02)
        vu.normalize3(:vf07, :vf01, scratch_vf: :vf30, wait_fmac: true)
        vu.end_program
      end

      prog.hazard_report.has_errors?.should be_false
      prog.hazard_report.warnings.should be_empty
    end

    it "expands perspective_divide, vec_lerp, clamp_01, and directional_light" do
      prog = Citrine.vu1_program("lighting_and_projection") do |vu|
        # Perspective divide with viewport scale (vf10) and offset (vf11) + FTOI4
        vu.perspective_divide(:vf08, :vf06, scale_vf: :vf10, offset_vf: :vf11, ftoi4_convert: true, wait_fmac: true)

        # Linear interpolation by float immediate (LOI) and by register lane
        vu.vec_lerp(:vf12, :vf01, :vf02, 0.5_f32, scratch_vf: :vf30, wait_fmac: true)
        vu.vec_lerp(:vf13, :vf01, :vf02, :vf09, scratch_vf: :vf30, wait_fmac: true)

        # [0..1] hardware clamp using vf00
        vu.clamp_01(:vf14, :vf12, mask: :xyz, wait_fmac: true)

        # Lambertian directional lighting with ambient and FTOI0 conversion
        vu.directional_light(
          dst_rgba_vf: :vf15,
          normal_vf: :vf02,
          light_dir_vf: :vf03,
          light_color_vf: :vf04,
          ambient_vf: :vf05,
          scratch_vf: :vf30,
          to_int: true,
          wait_fmac: true
        )
        vu.end_program
      end

      prog.hazard_report.has_errors?.should be_false
      prog.hazard_report.warnings.should be_empty
    end
  end

  describe "GS XGKICK Double-Buffered GIF Tag Emission & VIF1 Stream Packing" do
    it "builds 128-bit GS GIFTag headers and emits double-buffered XGKICK microcode" do
      prog = Citrine.vu1_program("double_buffered_triangle_kick") do |vu|
        vu.double_buffer(base: 0, offset: 512, input_offset: 0, kick_offset_a: 256, kick_offset_b: 384)

        vu.xgkick_double_buffer(
          base_vi: :vi01,
          out_vi: :vi02,
          giftag_vf: :vf31,
          giftag_src_offset: 0,
          kick_offset: 256,
          primitive: :triangle,
          nloop: 3,
          eop: true,
          pre: true,
          gouraud: true,
          textured: true,
          regs: [:st, :rgbaq, :xyz2]
        ) do
          # Load MVP matrix and transform 1 vertex inside kick block
          vu.load_matrix4(:vi01, offset: 1, rows: [:vf01, :vf02, :vf03, :vf04])
          vu.lq(:vf05, :vi01, 5)
          vu.mat4_mul_vec4(:vf06, [:vf01, :vf02, :vf03, :vf04], :vf05, wait_fmac: true)
          vu.ftoi4(:vf07, :vf06)
          vu.nop(3)
          vu.sq(:vf07, :vi02, 1)
        end

        vu.end_program
      end

      prog.hazard_report.clean?.should be_true
      prog.double_buffer.should_not be_nil
      db = prog.double_buffer.not_nil!
      db.base_qwc.should eq(0_u16)
      db.offset_qwc.should eq(512_u16)
      db.kick_offset_a.should eq(256_u16)

      prog.gif_tags.size.should eq(1)
      tag = prog.gif_tags[0]
      tag.nloop.should eq(3_u16)
      tag.eop.should be_true
      tag.pre.should be_true
      tag.nreg.should eq(3_u8)
      # REGS: ST (0x02), RGBAQ (0x01), XYZ2 (0x05) -> 0x512
      tag.regs.should eq(0x512_u64)

      # Verify VIF1 double-buffered packet packing with 2 vertex batches
      batch_a = [
        1.0_f32, 0.0_f32, 0.0_f32, 1.0_f32,
        0.0_f32, 1.0_f32, 0.0_f32, 1.0_f32,
        0.0_f32, 0.0_f32, 1.0_f32, 1.0_f32,
      ]
      batch_b = [
        2.0_f32, 0.0_f32, 0.0_f32, 1.0_f32,
        0.0_f32, 2.0_f32, 0.0_f32, 1.0_f32,
        0.0_f32, 0.0_f32, 2.0_f32, 1.0_f32,
      ]

      vif_bytes = Citrine::VU1.vif_packet(prog, batches: [batch_a, batch_b])
      (vif_bytes.size % 16).should eq(0)
      vif_bytes.size.should be > prog.byte_size
    end

    it "prevents back-to-back XGKICK stall hazards when ensure_no_stall is enabled and supports ping-pong buffer swapping" do
      prog = Citrine.vu1_program("ping_pong_xgkick") do |vu|
        vu.init_ping_pong_buffers(out_vi: :vi02, sum_vi: :vi03, offset_a: 256, offset_b: 384)
        vu.emit_gif_tag(:vi02, giftag_vf: :vf31, primitive: :sprite, nloop: 2, regs: [:rgbaq, :xyz2])
        vu.xgkick(:vi02, ensure_no_stall: true)
        vu.swap_xgkick_buffer(out_vi: :vi02, sum_vi: :vi03)
        vu.emit_gif_tag(:vi02, giftag_vf: :vf31, primitive: :sprite, nloop: 2, regs: [:rgbaq, :xyz2])
        vu.xgkick(:vi02, ensure_no_stall: true)
        vu.end_program
      end

      prog.hazard_report.clean?.should be_true
      prog.hazard_report.stall_cycles.should eq(0)
      prog.gif_tags.size.should eq(2)
    end
  end
end
