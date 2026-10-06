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

  it "imports binary GLB container and decodes geometry, materials, and UVs" do
    # 1. Build synthetic BIN chunk (3 positions = 36 bytes, 3 UVs = 24 bytes, 3 indices = 6 bytes)
    bin_io = IO::Memory.new
    # Positions (Float32): (0, 0, 0), (2, 0, 0), (0, 3, 0)
    [0.0_f32, 0.0_f32, 0.0_f32, 2.0_f32, 0.0_f32, 0.0_f32, 0.0_f32, 3.0_f32, 0.0_f32].each do |f|
      bin_io.write_bytes(f, IO::ByteFormat::LittleEndian)
    end
    # UVs (Float32): (0.0, 0.0), (1.0, 0.0), (0.0, 1.0)
    [0.0_f32, 0.0_f32, 1.0_f32, 0.0_f32, 0.0_f32, 1.0_f32].each do |f|
      bin_io.write_bytes(f, IO::ByteFormat::LittleEndian)
    end
    # Indices (UInt16): 0, 1, 2
    [0_u16, 1_u16, 2_u16].each do |idx|
      bin_io.write_bytes(idx, IO::ByteFormat::LittleEndian)
    end
    bin_bytes = bin_io.to_slice

    # 2. Build JSON chunk
    json_text = <<-JSON
    {
      "asset": { "version": "2.0" },
      "buffers": [ { "byteLength": #{bin_bytes.size} } ],
      "bufferViews": [
        { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
        { "buffer": 0, "byteOffset": 36, "byteLength": 24 },
        { "buffer": 0, "byteOffset": 60, "byteLength": 6 }
      ],
      "accessors": [
        { "bufferView": 0, "byteOffset": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
        { "bufferView": 1, "byteOffset": 0, "componentType": 5126, "count": 3, "type": "VEC2" },
        { "bufferView": 2, "byteOffset": 0, "componentType": 5123, "count": 3, "type": "SCALAR" }
      ],
      "materials": [
        {
          "name": "red_glow",
          "pbrMetallicRoughness": {
            "baseColorFactor": [1.0, 0.2, 0.1, 1.0]
          },
          "doubleSided": true
        }
      ],
      "meshes": [
        {
          "name": "hero_ship",
          "primitives": [
            {
              "material": 0,
              "indices": 2,
              "attributes": {
                "POSITION": 0,
                "TEXCOORD_0": 1
              }
            }
          ]
        }
      ]
    }
    JSON
    json_bytes = json_text.to_slice

    # 3. Assemble GLB container
    glb_io = IO::Memory.new
    # 12-byte header
    glb_io.write("glTF".to_slice)
    glb_io.write_bytes(2_u32, IO::ByteFormat::LittleEndian) # Version 2
    total_len = 12 + 8 + json_bytes.size + 8 + bin_bytes.size
    glb_io.write_bytes(total_len.to_u32, IO::ByteFormat::LittleEndian)

    # Chunk 0: JSON
    glb_io.write_bytes(json_bytes.size.to_u32, IO::ByteFormat::LittleEndian)
    glb_io.write("JSON".to_slice)
    glb_io.write(json_bytes)

    # Chunk 1: BIN
    glb_io.write_bytes(bin_bytes.size.to_u32, IO::ByteFormat::LittleEndian)
    glb_io.write("BIN\0".to_slice)
    glb_io.write(bin_bytes)

    # 4. Import GLB
    model = Citrine::Importers::MeshImporter.import_glb(glb_io.to_slice, "test_glb")
    model.meshes.size.should eq(1)
    model.materials.size.should eq(1)

    mesh = model.meshes[0]
    mesh.name.should eq("hero_ship")
    mesh.vertex_count.should eq(3)
    mesh.indices.should eq([0_u16, 1_u16, 2_u16])
    mesh.vertices[0].should eq(0.0_f32)
    mesh.vertices[3].should eq(2.0_f32)
    mesh.vertices[7].should eq(3.0_f32)

    # UV checks
    mesh.texcoords[0].should eq(0.0_f32)
    mesh.texcoords[2].should eq(1.0_f32)

    # Material checks
    mat = model.materials[0]
    mat.name.should eq("red_glow")
    mat.diffuse_color[0].should eq(255_u8) # Red ~ 1.0 * 255
    mat.cull_mode.should eq(0_u8) # doubleSided == true -> CullMode::None

    # 5. Export to CBM2 format and verify header
    cbm2 = model.to_cbm
    String.new(cbm2[0..3]).should eq("CBM2")
    version = IO::ByteFormat::LittleEndian.decode(UInt16, cbm2[4..5])
    version.should eq(2_u16)
    mat_count = IO::ByteFormat::LittleEndian.decode(UInt16, cbm2[6..7])
    mat_count.should eq(1_u16)
    mesh_count = IO::ByteFormat::LittleEndian.decode(UInt16, cbm2[8..9])
    mesh_count.should eq(1_u16)
  end
end
