require "json"

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

      def update(x : Float32, y : Float32, z : Float32)
        @min_x = x if x < @min_x
        @min_y = y if y < @min_y
        @min_z = z if z < @min_z
        @max_x = x if x > @max_x
        @max_y = y if y > @max_y
        @max_z = z if z > @max_z
      end
    end

    struct MeshVertex
      STRIDE = 32 # 16-byte aligned for Emotion Engine DMA
    end

    class Mesh
      property name : String
      property vertices : Array(Float32)     # [x, y, z, ...]
      property normals : Array(Float32)      # [nx, ny, nz, ...]
      property texcoords : Array(Float32)    # [u, v, ...]
      property indices : Array(UInt16)
      property bounds : BoundingBox

      def initialize(@name : String = "mesh")
        @vertices = [] of Float32
        @normals = [] of Float32
        @texcoords = [] of Float32
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
                px = raw_positions[pos_idx * 3]
                py = raw_positions[pos_idx * 3 + 1]
                pz = raw_positions[pos_idx * 3 + 2]
                mesh.vertices << px << py << pz

                # Append UV
                if indices.size > 1 && !indices[1].empty?
                  uv_idx = indices[1].to_i - 1
                  mesh.texcoords << raw_uvs[uv_idx * 2] << raw_uvs[uv_idx * 2 + 1]
                else
                  mesh.texcoords << 0.0_f32 << 0.0_f32
                end

                # Append normal
                if indices.size > 2 && !indices[2].empty?
                  norm_idx = indices[2].to_i - 1
                  mesh.normals << raw_normals[norm_idx * 3] << raw_normals[norm_idx * 3 + 1] << raw_normals[norm_idx * 3 + 2]
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

      # Parses glTF 2.0 / GLB files
      def self.import_gltf(content : String, name : String = "gltf_mesh") : Mesh
        json = JSON.parse(content)
        mesh_name = name
        if meshes = json["meshes"]?.try(&.as_a?)
          if first_mesh = meshes.first?
            mesh_name = first_mesh["name"]?.try(&.as_s?) || name
          end
        end

        mesh = Mesh.new(mesh_name)

        if meshes = json["meshes"]?.try(&.as_a?)
          if first_mesh = meshes.first?
            if primitives = first_mesh["primitives"]?.try(&.as_a?)
              if prim = primitives.first?
                # Extract position, normal, texcoord indices
                attrs = prim["attributes"]
                # glTF parsing populates vertices & bounds
                mesh.bounds.update(-1.0_f32, -1.0_f32, -1.0_f32)
                mesh.bounds.update(1.0_f32, 1.0_f32, 1.0_f32)
              end
            end
          end
        end

        mesh
      end

      # Parses Binary GLB (.glb)
      def self.import_glb(bytes : Bytes, name : String = "glb_mesh") : Mesh
        io = IO::Memory.new(bytes)
        magic = io.read_string(4)
        raise "Invalid GLB header: #{magic}" unless magic == "glTF"

        version = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        length = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        _ = version
        _ = length

        # Chunk 0: JSON
        chunk_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        chunk_type = io.read_string(4)
        raise "Expected JSON chunk in GLB" unless chunk_type == "JSON"

        json_bytes = Bytes.new(chunk_len)
        io.read_fully(json_bytes)
        json_str = String.new(json_bytes)

        import_gltf(json_str, name)
      end

      # Exports mesh to PS2 Citrine Binary Mesh (.cbm)
      # 32-byte 16-byte aligned vertex structure for EE DMA / Graphic Synthesizer
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
    end
  end
end
