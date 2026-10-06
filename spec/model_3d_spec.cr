require "./spec_helper"
require "../src/stubs/citrine/draw3d"

describe "Citrine 3D Subsystem (Meshes, Materials, Models & Procedural Generation)" do
  describe BoundingBox do
    it "initializes and expands bounds correctly" do
      box = BoundingBox.new
      box.update(-2.0_f32, 0.0_f32, -3.0_f32)
      box.update(4.0_f32, 5.0_f32, 1.0_f32)

      box.min_x.should eq(-2.0_f32)
      box.min_y.should eq(0.0_f32)
      box.min_z.should eq(-3.0_f32)
      box.max_x.should eq(4.0_f32)
      box.max_y.should eq(5.0_f32)
      box.max_z.should eq(1.0_f32)

      box.center.x.should eq(1.0_f32)
      box.center.y.should eq(2.5_f32)
      box.center.z.should eq(-1.0_f32)

      box.size.x.should eq(6.0_f32)
      box.size.y.should eq(5.0_f32)
      box.size.z.should eq(4.0_f32)
    end
  end

  describe Matrix4 do
    it "creates identity, translation, scaling, and rotates vectors" do
      id = Matrix4.identity
      tx, ty, tz = id.transform(1.0_f32, 2.0_f32, 3.0_f32)
      tx.should eq(1.0_f32)
      ty.should eq(2.0_f32)
      tz.should eq(3.0_f32)

      trans = Matrix4.translation(10.0_f32, -5.0_f32, 20.0_f32)
      tx, ty, tz = trans.transform(1.0_f32, 2.0_f32, 3.0_f32)
      tx.should eq(11.0_f32)
      ty.should eq(-3.0_f32)
      tz.should eq(23.0_f32)

      scale = Matrix4.scaling(2.0_f32, 3.0_f32, 0.5_f32)
      tx, ty, tz = scale.transform(4.0_f32, 2.0_f32, 10.0_f32)
      tx.should eq(8.0_f32)
      ty.should eq(6.0_f32)
      tz.should eq(5.0_f32)
    end
  end

  describe Material do
    it "initializes default and custom materials" do
      mat = Material.default
      mat.color.should eq(Color::White)
      mat.cull_mode.should eq(CullMode::Back)
      mat.blend_mode.should eq(BlendMode3D::Opaque)
      mat.wireframe.should be_false

      red_mat = Material.from_color(Color::Red)
      red_mat.color.should eq(Color::Red)
    end
  end

  describe Mesh do
    it "generates procedural cube with 24 vertices, 36 indices, and 6 faces" do
      cube = Mesh.gen_cube(2.0_f32, 2.0_f32, 2.0_f32)
      cube.name.should eq("cube")
      cube.vertex_count.should eq(24)
      cube.triangle_count.should eq(12)
      cube.index_count.should eq(36)

      # 24 vertices * 3 coords = 72 floats
      cube.vertices.size.should eq(72)
      cube.normals.size.should eq(72)
      # 24 vertices * 2 UVs = 48 floats
      cube.texcoords.size.should eq(48)

      # Verify bounds
      cube.bounds.min_x.should eq(-1.0_f32)
      cube.bounds.max_x.should eq(1.0_f32)
      cube.bounds.min_y.should eq(-1.0_f32)
      cube.bounds.max_y.should eq(1.0_f32)
      cube.bounds.min_z.should eq(-1.0_f32)
      cube.bounds.max_z.should eq(1.0_f32)

      # Verify UV coordinates are within [0.0, 1.0]
      cube.texcoords.each do |uv|
        uv.should be >= 0.0_f32
        uv.should be <= 1.0_f32
      end
    end

    it "generates procedural plane (ground mesh)" do
      plane = Mesh.gen_plane(10.0_f32, 10.0_f32, 2, 2)
      plane.name.should eq("plane")
      # (2 + 1) * (2 + 1) = 9 vertices
      plane.vertex_count.should eq(9)
      # 2 * 2 quads * 2 triangles = 8 triangles
      plane.triangle_count.should eq(8)

      # All plane normals point up (+Y)
      plane.normals.each_slice(3) do |norm|
        norm[0].should eq(0.0_f32)
        norm[1].should eq(1.0_f32)
        norm[2].should eq(0.0_f32)
      end
    end

    it "generates procedural UV sphere" do
      sphere = Mesh.gen_sphere(2.5_f32, 8, 8)
      sphere.name.should eq("sphere")
      sphere.vertex_count.should be > 0
      sphere.triangle_count.should be > 0

      # Check that all vertices are on sphere surface (dist approx radius)
      sphere.vertices.each_slice(3) do |v|
        dist = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2])
        dist.should be_close(2.5_f32, 0.05_f32)
      end
    end

    it "generates procedural cylinder with caps" do
      cyl = Mesh.gen_cylinder(1.5_f32, 4.0_f32, 8)
      cyl.name.should eq("cylinder")
      cyl.vertex_count.should be > 16
      cyl.triangle_count.should be > 16
      cyl.bounds.min_y.should eq(-2.0_f32)
      cyl.bounds.max_y.should eq(2.0_f32)
    end

    it "generates procedural cone" do
      cone = Mesh.gen_cone(1.0_f32, 3.0_f32, 8)
      cone.name.should eq("cone")
      cone.bounds.min_y.should eq(0.0_f32)
      cone.bounds.max_y.should eq(3.0_f32)
    end

    it "generates procedural torus" do
      torus = Mesh.gen_torus(3.0_f32, 0.5_f32, 8, 8)
      torus.name.should eq("torus")
      torus.vertex_count.should be > 0
      torus.triangle_count.should be > 0
    end
  end

  describe Model do
    it "assembles meshes and materials into a composite model" do
      model = Model.new("test_robot")
      cube = Mesh.gen_cube(1.0_f32, 1.0_f32, 1.0_f32)
      plane = Mesh.gen_plane(4.0_f32, 4.0_f32)

      mat1 = Material.from_color(Color::Red)
      mat2 = Material.from_color(Color::Green)

      model.meshes << cube
      model.meshes << plane
      model.materials << mat1
      model.materials << mat2
      model.mesh_materials << 0 << 1
      model.recalculate_bounds

      model.meshes.size.should eq(2)
      model.materials.size.should eq(2)
      model.bounds.min_x.should eq(-2.0_f32)
      model.bounds.max_x.should eq(2.0_f32)
    end
  end
end
