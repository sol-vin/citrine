require "./spec_helper"

describe "Citrine 3D Model Disc Baking DSL (MacroExpander & DiscManifest)" do
  it "bakes an OBJ model into .cbm and registers with disc manifest" do
    temp_dir = File.tempname("model_bake")
    Dir.mkdir_p(temp_dir)

    obj_path = File.join(temp_dir, "test_cube.obj")
    File.write(obj_path, <<-OBJ)
    v 0.0 0.0 0.0
    v 1.0 0.0 0.0
    v 0.0 1.0 0.0
    vn 0.0 0.0 1.0
    vn 0.0 0.0 1.0
    vn 0.0 0.0 1.0
    vt 0.0 0.0
    vt 1.0 0.0
    vt 0.0 1.0
    f 1/1/1 2/2/1 3/3/1
    OBJ

    manifest = Citrine::ISO::DiscManifest.current
    manifest.clear

    expander = Citrine::MacroExpander.new(obj_path)
    call = Crystal::Call.new(
      Crystal::Var.new("Citrine"),
      "bake_model",
      [Crystal::StringLiteral.new(obj_path)] of Crystal::ASTNode
    )

    result_node = expander.expand(call)
    result_node.should be_a(Crystal::StringLiteral)
    cbm_filename = result_node.as(Crystal::StringLiteral).value
    cbm_filename.should eq("test_cube.cbm")

    # Verify asset is registered with DiscManifest
    manifest.has_file?(cbm_filename).should be_true

    # Verify generated .cbm file exists and has CBM2 header
    cbm_full = File.join(temp_dir, "test_cube.cbm")
    File.exists?(cbm_full).should be_true
    cbm_bytes = File.read(cbm_full).to_slice
    String.new(cbm_bytes[0..3]).should eq("CBM2")

    FileUtils.rm_rf(temp_dir)
  end

  it "bakes a binary GLB model with embedded materials into .cbm and registers with disc manifest" do
    temp_dir = File.tempname("glb_bake")
    Dir.mkdir_p(temp_dir)

    glb_path = File.join(temp_dir, "ship.glb")

    # Build small synthetic GLB
    bin_io = IO::Memory.new
    [0.0_f32, 0.0_f32, 0.0_f32, 1.0_f32, 0.0_f32, 0.0_f32, 0.0_f32, 1.0_f32, 0.0_f32].each do |f|
      bin_io.write_bytes(f, IO::ByteFormat::LittleEndian)
    end
    [0.0_f32, 0.0_f32, 1.0_f32, 0.0_f32, 0.0_f32, 1.0_f32].each do |f|
      bin_io.write_bytes(f, IO::ByteFormat::LittleEndian)
    end
    [0_u16, 1_u16, 2_u16].each do |idx|
      bin_io.write_bytes(idx, IO::ByteFormat::LittleEndian)
    end
    bin_bytes = bin_io.to_slice

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
          "name": "hull_paint",
          "pbrMetallicRoughness": {
            "baseColorFactor": [0.2, 0.5, 0.8, 1.0]
          }
        }
      ],
      "meshes": [
        {
          "name": "fighter_mesh",
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

    glb_io = IO::Memory.new
    glb_io.write("glTF".to_slice)
    glb_io.write_bytes(2_u32, IO::ByteFormat::LittleEndian)
    total_len = 12 + 8 + json_bytes.size + 8 + bin_bytes.size
    glb_io.write_bytes(total_len.to_u32, IO::ByteFormat::LittleEndian)

    glb_io.write_bytes(json_bytes.size.to_u32, IO::ByteFormat::LittleEndian)
    glb_io.write("JSON".to_slice)
    glb_io.write(json_bytes)

    glb_io.write_bytes(bin_bytes.size.to_u32, IO::ByteFormat::LittleEndian)
    glb_io.write("BIN\0".to_slice)
    glb_io.write(bin_bytes)

    File.write(glb_path, glb_io.to_slice)

    manifest = Citrine::ISO::DiscManifest.current
    manifest.clear

    expander = Citrine::MacroExpander.new(glb_path)
    call = Crystal::Call.new(
      Crystal::Var.new("Citrine"),
      "bake_model",
      [Crystal::StringLiteral.new(glb_path)] of Crystal::ASTNode
    )

    result_node = expander.expand(call)
    result_node.should be_a(Crystal::StringLiteral)
    cbm_filename = result_node.as(Crystal::StringLiteral).value
    cbm_filename.should eq("ship.cbm")

    manifest.has_file?(cbm_filename).should be_true

    cbm_full = File.join(temp_dir, "ship.cbm")
    File.exists?(cbm_full).should be_true
    cbm_bytes = File.read(cbm_full).to_slice
    String.new(cbm_bytes[0..3]).should eq("CBM2")

    FileUtils.rm_rf(temp_dir)
  end
end
