require "./spec_helper"

describe Citrine::Importers::MeshImporter do
  it "imports Wavefront OBJ and exports Citrine Binary Mesh (.cbm)" do
    sample_obj = <<-OBJ
    # Cube sample
    v 0.0 0.0 0.0
    v 1.0 0.0 0.0
    v 1.0 1.0 0.0
    vt 0.0 0.0
    vt 1.0 0.0
    vt 1.0 1.0
    vn 0.0 0.0 1.0
    vn 0.0 0.0 1.0
    vn 0.0 0.0 1.0
    f 1/1/1 2/2/2 3/3/3
    OBJ

    mesh = Citrine::Importers::MeshImporter.import_obj(sample_obj, "test_triangle")
    mesh.vertex_count.should eq(3)
    mesh.index_count.should eq(3)
    mesh.vertices.size.should eq(9)
    mesh.vertices[0].should eq(0.0_f32)
    mesh.vertices[3].should eq(1.0_f32)
    mesh.vertices[7].should eq(1.0_f32)

    cbm_bytes = mesh.to_cbm
    cbm_bytes.size.should be > 32
    # Verify CBM1 magic
    String.new(cbm_bytes[0..3]).should eq("CBM1")

    # Verify 16-byte aligned vertex stride (32 bytes per vertex)
    Citrine::Importers::MeshVertex::STRIDE.should eq(32)
    (Citrine::Importers::MeshVertex::STRIDE % 16).should eq(0)
  end

  it "imports glTF JSON format into indexed mesh" do
    gltf_json = <<-JSON
    {
      "asset": { "version": "2.0" },
      "meshes": [
        {
          "name": "gltf_quad",
          "primitives": [
            {
              "mode": 4,
              "attributes": {
                "POSITION": 0
              }
            }
          ]
        }
      ]
    }
    JSON

    mesh = Citrine::Importers::MeshImporter.import_gltf(gltf_json)
    mesh.name.should eq("gltf_quad")
    cbm = mesh.to_cbm
    String.new(cbm[0..3]).should eq("CBM1")
  end
end
