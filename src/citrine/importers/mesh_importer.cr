require "json"
require "base64"

module Citrine
  module Importers
    struct BoundingBox
      property min_x : Float32
      property min_y : Float32
      property min_z : Float32
      property max_x : Float32
      property max_y : Float32
      property max_z : Float32

      def initialize(
        @min_x = Float32::MAX, @min_y = Float32::MAX, @min_z = Float32::MAX,
        @max_x = -Float32::MAX, @max_y = -Float32::MAX, @max_z = -Float32::MAX
      )
      end

      def update(x : Number, y : Number, z : Number)
        fx = x.to_f32
        fy = y.to_f32
        fz = z.to_f32
        @min_x = fx if fx < @min_x
        @min_y = fy if fy < @min_y
        @min_z = fz if fz < @min_z
        @max_x = fx if fx > @max_x
        @max_y = fy if fy > @max_y
        @max_z = fz if fz > @max_z
      end

      def update(b : BoundingBox)
        update(b.min_x, b.min_y, b.min_z)
        update(b.max_x, b.max_y, b.max_z)
      end
    end

    struct MeshVertex
      STRIDE = 32 # 16-byte aligned for Emotion Engine DMA
    end

    # Material definition for imported 3D models
    class Material
      property name : String
      property texture_path : String
      property diffuse_color : StaticArray(UInt8, 4)
      property cull_mode : UInt8   # 0: None, 1: Back, 2: Front
      property blend_mode : UInt8  # 0: Opaque, 1: Alpha, 2: Additive
      property embedded_image_bytes : Bytes?
      property embedded_image_mime : String?

      def initialize(
        @name : String = "material",
        @texture_path : String = "",
        @diffuse_color : StaticArray(UInt8, 4) = StaticArray[255_u8, 255_u8, 255_u8, 255_u8],
        @cull_mode : UInt8 = 1_u8,
        @blend_mode : UInt8 = 0_u8,
        @embedded_image_bytes : Bytes? = nil,
        @embedded_image_mime : String? = nil
      )
      end
    end

    # Mesh geometry containing vertex streams and index buffer
    class Mesh
      property name : String
      property vertices : Array(Float32)     # [x, y, z, ...]
      property normals : Array(Float32)      # [nx, ny, nz, ...]
      property texcoords : Array(Float32)    # [u, v, ...]
      property colors : Array(UInt8)         # [r, g, b, a, ...]
      property indices : Array(UInt16)
      property bounds : BoundingBox
      property material_index : Int32

      def initialize(@name : String = "mesh", @material_index : Int32 = 0)
        @vertices = [] of Float32
        @normals = [] of Float32
        @texcoords = [] of Float32
        @colors = [] of UInt8
        @indices = [] of UInt16
        @bounds = BoundingBox.new
      end

      def vertex_count : Int32
        @vertices.size // 3
      end

      def triangle_count : Int32
        @indices.size // 3
      end

      def index_count : Int32
        @indices.size
      end

      def to_cbm : Bytes
        MeshImporter.export_cbm(self)
      end

      def to_cbm2(material : Material? = nil) : Bytes
        MeshImporter.export_cbm2(self, material)
      end
    end

    # Composite 3D model containing multiple meshes and materials
    class Model
      property name : String
      property meshes : Array(Mesh)
      property materials : Array(Material)
      property bounds : BoundingBox

      def initialize(@name : String = "model")
        @meshes = [] of Mesh
        @materials = [] of Material
        @bounds = BoundingBox.new
      end

      def recalculate_bounds
        @bounds = BoundingBox.new
        @meshes.each do |mesh|
          @bounds.update(mesh.bounds)
        end
      end

      def to_cbm : Bytes
        MeshImporter.export_cbm2(self)
      end
    end

    class MeshImporter
      # Parses Wavefront .obj files
      def self.import_obj(content : String, name : String = "obj_mesh") : Mesh
        mesh = Mesh.new(name)
        raw_positions = [] of Float32
        raw_normals = [] of Float32
        raw_uvs = [] of Float32

        content.each_line do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")

          parts = line.split(/\s+/)
          case parts[0]
          when "v"
            if parts.size >= 4
              x = parts[1].to_f32
              y = parts[2].to_f32
              z = parts[3].to_f32
              raw_positions << x << y << z
              mesh.bounds.update(x, y, z)
            end
          when "vn"
            if parts.size >= 4
              raw_normals << parts[1].to_f32 << parts[2].to_f32 << parts[3].to_f32
            end
          when "vt"
            if parts.size >= 3
              raw_uvs << parts[1].to_f32 << parts[2].to_f32
            end
          when "f"
            # Parse face vertices e.g. f 1/1/1 2/2/2 3/3/3
            face_verts = parts[1..]
            # Triangulate polygon fans
            (1...(face_verts.size - 1)).each do |i|
              [0, i, i + 1].each do |idx|
                v_str = face_verts[idx]
                indices = v_str.split("/")
                pos_idx = indices[0].to_i - 1

                # Append position
                px = raw_positions[pos_idx * 3]? || 0.0_f32
                py = raw_positions[pos_idx * 3 + 1]? || 0.0_f32
                pz = raw_positions[pos_idx * 3 + 2]? || 0.0_f32
                mesh.vertices << px << py << pz

                # Append UV
                if indices.size > 1 && !indices[1].empty?
                  uv_idx = indices[1].to_i - 1
                  mesh.texcoords << (raw_uvs[uv_idx * 2]? || 0.0_f32) << (raw_uvs[uv_idx * 2 + 1]? || 0.0_f32)
                else
                  mesh.texcoords << 0.0_f32 << 0.0_f32
                end

                # Append normal
                if indices.size > 2 && !indices[2].empty?
                  norm_idx = indices[2].to_i - 1
                  mesh.normals << (raw_normals[norm_idx * 3]? || 0.0_f32) << (raw_normals[norm_idx * 3 + 1]? || 1.0_f32) << (raw_normals[norm_idx * 3 + 2]? || 0.0_f32)
                else
                  mesh.normals << 0.0_f32 << 1.0_f32 << 0.0_f32
                end

                mesh.indices << (mesh.indices.size.to_u16)
              end
            end
          end
        end

        mesh
      end

      # Parses Wavefront .obj file into a Model wrapper
      def self.import_obj_model(content : String, name : String = "obj_model") : Model
        mesh = import_obj(content, name)
        model = Model.new(name)
        model.meshes << mesh
        model.materials << Material.new("default")
        model.recalculate_bounds
        model
      end

      # Parses glTF JSON and returns the primary Mesh (preserves backward compatibility)
      def self.import_gltf(content : String, name : String = "gltf_mesh") : Mesh
        model = import_gltf_model(content, nil, name)
        model.meshes.first? || Mesh.new(name)
      end

      # Parses Binary GLB (.glb) container into a full Model (multi-mesh, materials, embedded textures)
      def self.import_glb(bytes : Bytes, name : String = "glb_mesh") : Model
        io = IO::Memory.new(bytes)
        magic = io.read_string(4)
        raise "Invalid GLB header: #{magic}" unless magic == "glTF"

        version = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        length = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        _ = version
        _ = length

        # Chunk 0: JSON Chunk
        json_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        json_type = io.read_string(4)
        raise "Expected JSON chunk in GLB, got #{json_type}" unless json_type == "JSON"

        json_bytes = Bytes.new(json_len)
        io.read_fully(json_bytes)
        json_str = String.new(json_bytes)

        # Check whether chunk was 4-byte padded or not
        json_padding = (4 - (json_len % 4)) % 4
        if json_padding > 0 && io.pos + json_padding + 8 <= bytes.size
          # If skipping padding matches a chunk header type, skip it; otherwise don't
          type_with_pad = String.new(bytes[io.pos + json_padding + 4, 3]) rescue ""
          type_without_pad = String.new(bytes[io.pos + 4, 3]) rescue ""
          if type_with_pad == "BIN" || type_with_pad == "JSO"
            io.skip(json_padding)
          elsif type_without_pad != "BIN" && type_without_pad != "JSO"
            io.skip(json_padding)
          end
        end

        # Chunk 1: Binary Buffer Chunk (optional)
        bin_data : Bytes? = nil
        if io.pos + 8 <= bytes.size
          bin_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          bin_type = io.read_string(4)
          if bin_type.starts_with?("BIN")
            rem_len = (bytes.size - io.pos).to_i64
            actual_len = (bin_len.to_i64 < rem_len ? bin_len.to_i64 : rem_len).to_i32
            bin_data = Bytes.new(actual_len)
            io.read_fully(bin_data)
          end
        end

        import_gltf_model(json_str, bin_data, name)
      end

      # Parses glTF 2.0 JSON format and binary buffer into a complete Model structure
      def self.import_gltf_model(content : String, bin_data : Bytes? = nil, name : String = "gltf_model") : Model
        json = JSON.parse(content)
        model = Model.new(name)

        # 1. Resolve Buffers
        buffers = [] of Bytes
        if json_buffers = json["buffers"]?.try(&.as_a?)
          json_buffers.each_with_index do |buf_node, idx|
            if idx == 0 && bin_data
              buffers << bin_data
            elsif uri = buf_node["uri"]?.try(&.as_s?)
              if uri.starts_with?("data:application/octet-stream;base64,") || uri.starts_with?("data:application/gltf-buffer;base64,")
                b64 = uri.split(",", 2)[1]
                buffers << Base64.decode(b64)
              else
                buffers << Bytes.empty
              end
            else
              buffers << (bin_data || Bytes.empty)
            end
          end
        elsif bin_data
          buffers << bin_data
        end

        buffer_views = json["bufferViews"]?.try(&.as_a?) || [] of JSON::Any
        accessors = json["accessors"]?.try(&.as_a?) || [] of JSON::Any

        # 2. Extract Materials
        if json_materials = json["materials"]?.try(&.as_a?)
          json_materials.each_with_index do |mat_node, mat_idx|
            mat_name = mat_node["name"]?.try(&.as_s?) || "mat_#{mat_idx}"
            mat = Material.new(mat_name)

            if pbr = mat_node["pbrMetallicRoughness"]?
              if base_color = pbr["baseColorFactor"]?.try(&.as_a?)
                r = (base_color[0].as_f * 255.0).clamp(0.0, 255.0).to_u8
                g = (base_color[1].as_f * 255.0).clamp(0.0, 255.0).to_u8
                b = (base_color[2].as_f * 255.0).clamp(0.0, 255.0).to_u8
                a = (base_color[3].as_f * 255.0).clamp(0.0, 255.0).to_u8
                mat.diffuse_color = StaticArray[r, g, b, a]
              end

              # Texture reference
              if tex_info = pbr["baseColorTexture"]?
                tex_idx = tex_info["index"].as_i
                if textures = json["textures"]?.try(&.as_a?)
                  if tex = textures[tex_idx]?
                    img_idx = tex["source"].as_i
                    if images = json["images"]?.try(&.as_a?)
                      if img = images[img_idx]?
                        if bv_idx = img["bufferView"]?.try(&.as_i?)
                          if bv = buffer_views[bv_idx]?
                            b_idx = bv["buffer"]?.try(&.as_i?) || 0
                            offset = bv["byteOffset"]?.try(&.as_i64?) || 0_i64
                            len = bv["byteLength"].as_i64
                            if target_buf = buffers[b_idx]?
                              if offset + len <= target_buf.size
                                mat.embedded_image_bytes = target_buf[offset, len].dup
                                mat.embedded_image_mime = img["mimeType"]?.try(&.as_s?) || "image/png"
                              end
                            end
                          end
                        elsif uri = img["uri"]?.try(&.as_s?)
                          if uri.starts_with?("data:image/")
                            parts = uri.split(",", 2)
                            mat.embedded_image_bytes = Base64.decode(parts[1])
                            mat.embedded_image_mime = parts[0].sub("data:", "").sub(";base64", "")
                          else
                            mat.texture_path = uri
                          end
                        end
                      end
                    end
                  end
                end
              end
            end

            # Culling flag: glTF doubleSided true means CullMode::None (0)
            if mat_node["doubleSided"]?.try(&.as_bool?)
              mat.cull_mode = 0_u8
            else
              mat.cull_mode = 1_u8
            end

            model.materials << mat
          end
        end

        # Ensure at least one default material
        if model.materials.empty?
          model.materials << Material.new("default")
        end

        # 3. Extract Meshes & Primitives
        if json_meshes = json["meshes"]?.try(&.as_a?)
          json_meshes.each do |mesh_node|
            mesh_name = mesh_node["name"]?.try(&.as_s?) || "mesh"
            if primitives = mesh_node["primitives"]?.try(&.as_a?)
              primitives.each_with_index do |prim, prim_idx|
                sub_name = primitives.size == 1 ? mesh_name : "#{mesh_name}_#{prim_idx}"
                sub_mesh = Mesh.new(sub_name)
                mat_idx = prim["material"]?.try(&.as_i?) || 0
                sub_mesh.material_index = mat_idx

                attrs = prim["attributes"]?

                # Read POSITION attribute
                if pos_acc_idx = attrs.try(&.[]?("POSITION")).try(&.as_i?)
                  read_accessor_floats(accessors, buffer_views, buffers, pos_acc_idx) do |v, count|
                    sub_mesh.vertices.concat(v)
                    # Compute bounds
                    i = 0
                    while i + 2 < v.size
                      sub_mesh.bounds.update(v[i], v[i + 1], v[i + 2])
                      i += 3
                    end
                  end
                end

                # Read NORMAL attribute
                if norm_acc_idx = attrs.try(&.[]?("NORMAL")).try(&.as_i?)
                  read_accessor_floats(accessors, buffer_views, buffers, norm_acc_idx) do |norms, _|
                    sub_mesh.normals.concat(norms)
                  end
                else
                  # Fill default normals if missing
                  sub_mesh.vertex_count.times do
                    sub_mesh.normals << 0.0_f32 << 1.0_f32 << 0.0_f32
                  end
                end

                # Read TEXCOORD_0 attribute
                if uv_acc_idx = attrs.try(&.[]?("TEXCOORD_0")).try(&.as_i?)
                  read_accessor_floats(accessors, buffer_views, buffers, uv_acc_idx) do |uvs, _|
                    sub_mesh.texcoords.concat(uvs)
                  end
                else
                  # Fill default zero UVs
                  sub_mesh.vertex_count.times do
                    sub_mesh.texcoords << 0.0_f32 << 0.0_f32
                  end
                end

                # Read Indices
                if idx_acc_idx = prim["indices"]?.try(&.as_i?)
                  read_accessor_indices(accessors, buffer_views, buffers, idx_acc_idx) do |indices|
                    sub_mesh.indices.concat(indices)
                  end
                else
                  # Generate sequential indices if unindexed
                  sub_mesh.vertex_count.times do |i|
                    sub_mesh.indices << i.to_u16
                  end
                end

                model.meshes << sub_mesh
              end
            end
          end
        end

        model.recalculate_bounds
        model
      end

      # Decodes glTF accessor float array (VEC2, VEC3, VEC4, SCALAR)
      private def self.read_accessor_floats(
        accessors : Array(JSON::Any),
        buffer_views : Array(JSON::Any),
        buffers : Array(Bytes),
        accessor_idx : Int32,
        &block : Array(Float32), Int32 -> Nil
      )
        return unless acc = accessors[accessor_idx]?
        bv_idx = acc["bufferView"]?.try(&.as_i?)
        return unless bv_idx && (bv = buffer_views[bv_idx]?)

        b_idx = bv["buffer"]?.try(&.as_i?) || 0
        return unless buf = buffers[b_idx]?

        bv_offset = bv["byteOffset"]?.try(&.as_i64?) || 0_i64
        acc_offset = acc["byteOffset"]?.try(&.as_i64?) || 0_i64
        total_offset = bv_offset + acc_offset
        count = acc["count"].as_i
        type_str = acc["type"].as_s
        comp_type = acc["componentType"].as_i

        components = case type_str
                     when "SCALAR" then 1
                     when "VEC2"   then 2
                     when "VEC3"   then 3
                     when "VEC4"   then 4
                     else 1
                     end

        stride = bv["byteStride"]?.try(&.as_i?) || (components * sizeof(Float32))
        res = Array(Float32).new(count * components)

        count.times do |elem_idx|
          elem_offset = total_offset + elem_idx * stride
          components.times do |c_idx|
            byte_pos = elem_offset + c_idx * sizeof(Float32)
            if byte_pos + 4 <= buf.size
              val = IO::ByteFormat::LittleEndian.decode(Float32, buf[byte_pos, 4])
              res << val
            else
              res << 0.0_f32
            end
          end
        end

        yield res, count
      end

      # Decodes glTF accessor index buffer (UNSIGNED_BYTE, UNSIGNED_SHORT, UNSIGNED_INT)
      private def self.read_accessor_indices(
        accessors : Array(JSON::Any),
        buffer_views : Array(JSON::Any),
        buffers : Array(Bytes),
        accessor_idx : Int32,
        &block : Array(UInt16) -> Nil
      )
        return unless acc = accessors[accessor_idx]?
        bv_idx = acc["bufferView"]?.try(&.as_i?)
        return unless bv_idx && (bv = buffer_views[bv_idx]?)

        b_idx = bv["buffer"]?.try(&.as_i?) || 0
        return unless buf = buffers[b_idx]?

        bv_offset = bv["byteOffset"]?.try(&.as_i64?) || 0_i64
        acc_offset = acc["byteOffset"]?.try(&.as_i64?) || 0_i64
        total_offset = bv_offset + acc_offset
        count = acc["count"].as_i
        comp_type = acc["componentType"].as_i

        indices = Array(UInt16).new(count)
        io = IO::Memory.new(buf)

        case comp_type
        when 5121 # UNSIGNED_BYTE
          io.pos = total_offset
          count.times do
            if io.pos < buf.size
              indices << io.read_byte.not_nil!.to_u16
            else
              indices << 0_u16
            end
          end
        when 5123 # UNSIGNED_SHORT
          io.pos = total_offset
          count.times do
            if io.pos + 2 <= buf.size
              indices << io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
            else
              indices << 0_u16
            end
          end
        when 5125 # UNSIGNED_INT
          io.pos = total_offset
          count.times do
            if io.pos + 4 <= buf.size
              u32_val = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              indices << u32_val.to_u16 # Clamped to 16-bit
            else
              indices << 0_u16
            end
          end
        end

        yield indices
      end

      # Exports mesh to PS2 Citrine Binary Mesh (.cbm) v1 format (backward compatibility)
      def self.export_cbm(mesh : Mesh) : Bytes
        io = IO::Memory.new

        # Header: Magic "CBM1"
        io.write("CBM1".to_slice)
        io.write_bytes(1_u16, IO::ByteFormat::LittleEndian) # Version 1
        io.write_bytes(mesh.vertex_count.to_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(mesh.indices.size.to_u32, IO::ByteFormat::LittleEndian)

        # Bounding Box
        io.write_bytes(mesh.bounds.min_x, IO::ByteFormat::LittleEndian)
        io.write_bytes(mesh.bounds.min_y, IO::ByteFormat::LittleEndian)
        io.write_bytes(mesh.bounds.min_z, IO::ByteFormat::LittleEndian)
        io.write_bytes(mesh.bounds.max_x, IO::ByteFormat::LittleEndian)
        io.write_bytes(mesh.bounds.max_y, IO::ByteFormat::LittleEndian)
        io.write_bytes(mesh.bounds.max_z, IO::ByteFormat::LittleEndian)

        # Interleaved Vertices: [posX, posY, posZ, normX, normY, normZ, u, v]
        mesh.vertex_count.times do |i|
          vx = mesh.vertices[i * 3]? || 0.0_f32
          vy = mesh.vertices[i * 3 + 1]? || 0.0_f32
          vz = mesh.vertices[i * 3 + 2]? || 0.0_f32
          nx = mesh.normals[i * 3]? || 0.0_f32
          ny = mesh.normals[i * 3 + 1]? || 1.0_f32
          nz = mesh.normals[i * 3 + 2]? || 0.0_f32
          u = mesh.texcoords[i * 2]? || 0.0_f32
          v = mesh.texcoords[i * 2 + 1]? || 0.0_f32

          io.write_bytes(vx, IO::ByteFormat::LittleEndian)
          io.write_bytes(vy, IO::ByteFormat::LittleEndian)
          io.write_bytes(vz, IO::ByteFormat::LittleEndian)
          io.write_bytes(nx, IO::ByteFormat::LittleEndian)
          io.write_bytes(ny, IO::ByteFormat::LittleEndian)
          io.write_bytes(nz, IO::ByteFormat::LittleEndian)
          io.write_bytes(u, IO::ByteFormat::LittleEndian)
          io.write_bytes(v, IO::ByteFormat::LittleEndian)
        end

        # Index buffer
        mesh.indices.each do |idx|
          io.write_bytes(idx, IO::ByteFormat::LittleEndian)
        end

        io.to_slice
      end

      # Exports a single Mesh and Material to CBM2 format
      def self.export_cbm2(mesh : Mesh, material : Material? = nil) : Bytes
        model = Model.new(mesh.name)
        model.meshes << mesh
        model.materials << (material || Material.new("default"))
        model.recalculate_bounds
        export_cbm2(model)
      end

      # Exports complete Model to PS2 Citrine Binary Model (.cbm) v2 format
      # Preserves materials, multiple mesh chunks, texture names, and 16-byte alignment
      def self.export_cbm2(model : Model) : Bytes
        io = IO::Memory.new

        # 1. Header: Magic "CBM2" (36 bytes)
        io.write("CBM2".to_slice)
        io.write_bytes(2_u16, IO::ByteFormat::LittleEndian) # Version 2
        io.write_bytes(model.materials.size.to_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(model.meshes.size.to_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u16, IO::ByteFormat::LittleEndian) # Flags

        # Overall Model Bounding Box
        io.write_bytes(model.bounds.min_x, IO::ByteFormat::LittleEndian)
        io.write_bytes(model.bounds.min_y, IO::ByteFormat::LittleEndian)
        io.write_bytes(model.bounds.min_z, IO::ByteFormat::LittleEndian)
        io.write_bytes(model.bounds.max_x, IO::ByteFormat::LittleEndian)
        io.write_bytes(model.bounds.max_y, IO::ByteFormat::LittleEndian)
        io.write_bytes(model.bounds.max_z, IO::ByteFormat::LittleEndian)

        # 2. Material Table (72 bytes per material)
        model.materials.each do |mat|
          # Name (32 bytes fixed)
          name_bytes = Bytes.new(32, 0_u8)
          mat.name.to_slice[0, Math.min(31, mat.name.bytesize)].copy_to(name_bytes.to_unsafe, Math.min(31, mat.name.bytesize))
          io.write(name_bytes)

          # Texture path on disc (32 bytes fixed)
          tex_bytes = Bytes.new(32, 0_u8)
          mat.texture_path.to_slice[0, Math.min(31, mat.texture_path.bytesize)].copy_to(tex_bytes.to_unsafe, Math.min(31, mat.texture_path.bytesize))
          io.write(tex_bytes)

          # Diffuse RGBA tint (4 bytes)
          io.write_byte(mat.diffuse_color[0])
          io.write_byte(mat.diffuse_color[1])
          io.write_byte(mat.diffuse_color[2])
          io.write_byte(mat.diffuse_color[3])

          # Cull mode (1 byte), Blend mode (1 byte), Reserved (2 bytes)
          io.write_byte(mat.cull_mode)
          io.write_byte(mat.blend_mode)
          io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
        end

        # 3. Meshes
        model.meshes.each do |mesh|
          io.write_bytes(mesh.material_index.to_u16, IO::ByteFormat::LittleEndian)
          io.write_bytes(0_u16, IO::ByteFormat::LittleEndian) # Flags
          io.write_bytes(mesh.vertex_count.to_u32, IO::ByteFormat::LittleEndian)
          io.write_bytes(mesh.indices.size.to_u32, IO::ByteFormat::LittleEndian)

          # Mesh Bounding Box (24 bytes)
          io.write_bytes(mesh.bounds.min_x, IO::ByteFormat::LittleEndian)
          io.write_bytes(mesh.bounds.min_y, IO::ByteFormat::LittleEndian)
          io.write_bytes(mesh.bounds.min_z, IO::ByteFormat::LittleEndian)
          io.write_bytes(mesh.bounds.max_x, IO::ByteFormat::LittleEndian)
          io.write_bytes(mesh.bounds.max_y, IO::ByteFormat::LittleEndian)
          io.write_bytes(mesh.bounds.max_z, IO::ByteFormat::LittleEndian)

          # Interleaved Vertices (32 bytes each: pos xyz, norm xyz, uv)
          mesh.vertex_count.times do |i|
            vx = mesh.vertices[i * 3]? || 0.0_f32
            vy = mesh.vertices[i * 3 + 1]? || 0.0_f32
            vz = mesh.vertices[i * 3 + 2]? || 0.0_f32
            nx = mesh.normals[i * 3]? || 0.0_f32
            ny = mesh.normals[i * 3 + 1]? || 1.0_f32
            nz = mesh.normals[i * 3 + 2]? || 0.0_f32
            u = mesh.texcoords[i * 2]? || 0.0_f32
            v = mesh.texcoords[i * 2 + 1]? || 0.0_f32

            io.write_bytes(vx, IO::ByteFormat::LittleEndian)
            io.write_bytes(vy, IO::ByteFormat::LittleEndian)
            io.write_bytes(vz, IO::ByteFormat::LittleEndian)
            io.write_bytes(nx, IO::ByteFormat::LittleEndian)
            io.write_bytes(ny, IO::ByteFormat::LittleEndian)
            io.write_bytes(nz, IO::ByteFormat::LittleEndian)
            io.write_bytes(u, IO::ByteFormat::LittleEndian)
            io.write_bytes(v, IO::ByteFormat::LittleEndian)
          end

          # Indices
          mesh.indices.each do |idx|
            io.write_bytes(idx, IO::ByteFormat::LittleEndian)
          end
        end

        io.to_slice
      end
    end
  end
end
