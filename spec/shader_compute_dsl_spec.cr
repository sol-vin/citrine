require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/shader"
require "../src/stubs/citrine/compute"
require "../src/citrine/compiler/shader_compiler"

describe "Citrine::Shader & Citrine::Compute DSL" do
  describe "Programmable Vector & Matrix Math" do
    it "performs Vec3 dot and cross products" do
      v1 = Citrine::Shader::Vec3.new(1.0, 0.0, 0.0)
      v2 = Citrine::Shader::Vec3.new(0.0, 1.0, 0.0)
      v1.dot(v2).should eq(0.0_f32)

      cross = v1.cross(v2)
      cross.x.should eq(0.0_f32)
      cross.y.should eq(0.0_f32)
      cross.z.should eq(1.0_f32)
    end

    it "normalizes vectors correctly" do
      v = Citrine::Shader::Vec3.new(0.0, 3.0, 4.0)
      norm = v.normalize
      norm.length.should be_close(1.0_f32, 0.001_f32)
      norm.y.should be_close(0.6_f32, 0.001_f32)
      norm.z.should be_close(0.8_f32, 0.001_f32)
    end

    it "multiplies Mat4 and Vec4" do
      mat = Citrine::Shader::Mat4.identity
      vec = Citrine::Shader::Vec4.new(1.0, 2.0, 3.0, 1.0)
      res = mat * vec
      res.x.should eq(1.0_f32)
      res.y.should eq(2.0_f32)
      res.z.should eq(3.0_f32)
      res.w.should eq(1.0_f32)
    end
  end

  describe "Programmable Vertex Shader DSL" do
    it "declares a programmable vertex shader" do
      vs = Citrine::Shader.vertex "TestVertexShader" do |s|
        s.uniform :mvp, "Mat4"
        s.uniform :light_dir, "Vec3"
        s.input :position, "Vec4"
        s.input :normal, "Vec3"
        s.output :out_pos, "Vec4"
        s.output :out_color, "Vec4"

        s.main do |pos, norm, uv, col|
          { pos, col, uv }
        end
      end

      vs.name.should eq("TestVertexShader")
      vs.uniforms.size.should eq(2)
      vs.inputs.size.should eq(2)
      vs.outputs.size.should eq(2)
      vs.body.should_not be_nil

      # Compile to VU1 microcode
      bytes = Citrine::ShaderCompiler.compile_vertex_shader(vs)
      bytes.size.should be > 0
      vs.microcode_bytes.should_not be_nil
    end

    it "configures rasterizer and blend pipeline" do
      pipe = Citrine::Shader.pipeline "CustomPipeline" do |p|
        p.vertex_shader "TestVertexShader"
        p.raster.depth_test = Citrine::Shader::DepthFunc::LEqual
        p.raster.cull_mode = Citrine::Shader::CullMode::Back
        p.blend.a = :source_color
        p.blend.b = :zero
        p.blend.c = :fixed_alpha
        p.blend.d = :dest_color
        p.blend.fixed_alpha = 160_u8
      end

      pipe.raster.depth_test.should eq(Citrine::Shader::DepthFunc::LEqual)
      pipe.blend.fixed_alpha.should eq(160_u8)

      alpha_reg = Citrine::ShaderCompiler.generate_gs_alpha_from_config(pipe.blend)
      alpha_reg.should be > 0_u64
    end
  end

  describe "Citrine::Compute (VU0 Micro Mode Compute Shaders)" do
    it "declares and dispatches a compute kernel" do
      executed_indices = [] of Int32

      kernel = Citrine::Compute.kernel "TestParticleKernel" do |k|
        k.buffer :positions, "Vec4", size: 64
        k.uniform :dt, "Float32"

        k.main do |id|
          executed_indices << id
        end
      end

      kernel.name.should eq("TestParticleKernel")
      kernel.buffers.size.should eq(1)

      Citrine::Compute.dispatch(kernel, count: 16)
      Citrine::Compute.sync

      executed_indices.size.should eq(16)
      executed_indices.should eq((0..15).to_a)
      Citrine::Compute.busy?.should be_false
    end
  end
end
