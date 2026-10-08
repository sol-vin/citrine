require "../../gs/gif_packet_builder"

module Citrine
  module ISO
    class PhaseExtractor
      alias DrawCommand = Citrine::GS::DrawCommand
      alias Phase = Citrine::GS::Phase

      def self.emit_cbt_texture_spans(
        commands : Array(DrawCommand),
        path : String,
        start_x : Int32,
        start_y : Int32,
        dest_w : Int32 = 128,
        dest_h : Int32 = 128,
        grid_res : Int32 = 64,
      )
        return unless File.exists?(path)
        bytes = File.read(path).to_slice
        return unless bytes.size > 16 && String.new(bytes[0, 4]) == "CBT1"

        w = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[4, 2]).to_i
        h = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[6, 2]).to_i
        has_palette = bytes[9] == 1_u8

        if has_palette
          pal_size = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[10, 4]).to_i
          pal = bytes[14, pal_size]
          pixels = bytes[14 + pal_size + 4, w * h]

          grid_res.times do |gy|
            gx = 0
            while gx < grid_res
              px = ((gx * w) // grid_res).clamp(0, w - 1)
              py = ((gy * h) // grid_res).clamp(0, h - 1)
              pal_idx = pixels[py * w + px].to_i
              a = (pal_idx * 4 + 3 < pal.size) ? pal[pal_idx * 4 + 3].to_u32 : 255_u32

              # Transparent pixel (index 0 or alpha < 32)
              if pal_idx == 0 || a < 32_u32
                gx += 1
                next
              end

              r = pal[pal_idx * 4].to_u32
              g = pal[pal_idx * 4 + 1].to_u32
              b = pal[pal_idx * 4 + 2].to_u32
              color = (a << 24) | (b << 16) | (g << 8) | r

              span_len = 1
              while (gx + span_len) < grid_res
                npx = (((gx + span_len) * w) // grid_res).clamp(0, w - 1)
                npal_idx = pixels[py * w + npx].to_i
                na = (npal_idx * 4 + 3 < pal.size) ? pal[npal_idx * 4 + 3].to_u32 : 255_u32
                break if npal_idx == 0 || na < 32_u32

                nr = pal[npal_idx * 4].to_u32
                ng = pal[npal_idx * 4 + 1].to_u32
                nb = pal[npal_idx * 4 + 2].to_u32
                ncolor = (na << 24) | (nb << 16) | (ng << 8) | nr
                break if ncolor != color
                span_len += 1
              end

              x1 = start_x + (gx * dest_w // grid_res)
              y1 = start_y + (gy * dest_h // grid_res)
              x2 = start_x + ((gx + span_len) * dest_w // grid_res)
              y2 = start_y + ((gy + 1) * dest_h // grid_res)
              commands << DrawCommand.new(DrawCommand::Type::Rect, x1, y1, x2, y2, color: color)

              gx += span_len
            end
          end
        else
          # Unpaletted 32-bit RGBA
          pixels = bytes[14, w * h * 4]

          grid_res.times do |gy|
            gx = 0
            while gx < grid_res
              px = ((gx * w) // grid_res).clamp(0, w - 1)
              py = ((gy * h) // grid_res).clamp(0, h - 1)
              p_offset = (py * w + px) * 4
              r = pixels[p_offset].to_u32
              g = pixels[p_offset + 1].to_u32
              b = pixels[p_offset + 2].to_u32
              a = pixels[p_offset + 3].to_u32

              if a < 32_u32
                gx += 1
                next
              end

              color = (a << 24) | (b << 16) | (g << 8) | r

              span_len = 1
              while (gx + span_len) < grid_res
                npx = (((gx + span_len) * w) // grid_res).clamp(0, w - 1)
                np_offset = (py * w + npx) * 4
                na = pixels[np_offset + 3].to_u32
                break if na < 32_u32

                nr = pixels[np_offset].to_u32
                ng = pixels[np_offset + 1].to_u32
                nb = pixels[np_offset + 2].to_u32
                ncolor = (na << 24) | (nb << 16) | (ng << 8) | nr
                break if ncolor != color
                span_len += 1
              end

              x1 = start_x + (gx * dest_w // grid_res)
              y1 = start_y + (gy * dest_h // grid_res)
              x2 = start_x + ((gx + span_len) * dest_w // grid_res)
              y2 = start_y + ((gy + 1) * dest_h // grid_res)
              commands << DrawCommand.new(DrawCommand::Type::Rect, x1, y1, x2, y2, color: color)

              gx += span_len
            end
          end
        end
      end

      def self.decode_coord(val : Int64?, is_float : Bool = false) : Float32
        return 0.0_f32 unless val
        u = (val & 0xFFFFFFFF_i64).to_u32
        return 0.0_f32 if u == 0_u32
        bytes = Bytes[(u & 0xFF).to_u8, ((u >> 8) & 0xFF).to_u8, ((u >> 16) & 0xFF).to_u8, ((u >> 24) & 0xFF).to_u8]
        f = IO::ByteFormat::LittleEndian.decode(Float32, bytes) rescue 0.0_f32
        if is_float
          return f unless f.nan? || f.infinite?
        end
        if !f.nan? && !f.infinite? && f.abs < 20000.0_f32 && f.abs > 1e-7_f32
          f
        else
          val.to_f32
        end
      end

      def self.encode_f32(f : Float32) : Int64
        bytes = Bytes.new(4)
        IO::ByteFormat::LittleEndian.encode(f, bytes)
        IO::ByteFormat::LittleEndian.decode(UInt32, bytes).to_i64
      end

      def self.project_3d_point(
        px : Float32, py : Float32, pz : Float32,
        cam_pos : Tuple(Float32, Float32, Float32),
        cam_tgt : Tuple(Float32, Float32, Float32),
        cam_up : Tuple(Float32, Float32, Float32),
      ) : Tuple(Int32, Int32)?
        fx = cam_tgt[0] - cam_pos[0]
        fy = cam_tgt[1] - cam_pos[1]
        fz = cam_tgt[2] - cam_pos[2]
        len_f = Math.sqrt(fx * fx + fy * fy + fz * fz)
        len_f = 1.0_f32 if len_f == 0.0_f32
        fx /= len_f; fy /= len_f; fz /= len_f

        rx = fy * cam_up[2] - fz * cam_up[1]
        ry = fz * cam_up[0] - fx * cam_up[2]
        rz = fx * cam_up[1] - fy * cam_up[0]
        len_r = Math.sqrt(rx * rx + ry * ry + rz * rz)
        len_r = 1.0_f32 if len_r == 0.0_f32
        rx /= len_r; ry /= len_r; rz /= len_r

        ux = ry * fz - rz * fy
        uy = rz * fx - rx * fz
        uz = rx * fy - ry * fx

        dx = px - cam_pos[0]
        dy = py - cam_pos[1]
        dz = pz - cam_pos[2]

        xc = dx * rx + dy * ry + dz * rz
        yc = dx * ux + dy * uy + dz * uz
        zc = dx * fx + dy * fy + dz * fz

        return nil if zc <= 0.2_f32

        focal = 540.0_f32
        sx = (320.0_f32 + (xc * focal / zc)).to_i32
        sy = (224.0_f32 - (yc * focal / zc)).to_i32
        {sx, sy}
      end

      def self.emit_3d_grid(
        commands : Array(DrawCommand),
        slices : Int32,
        spacing : Float32,
        color : UInt32,
        cam_pos : Tuple(Float32, Float32, Float32),
        cam_tgt : Tuple(Float32, Float32, Float32),
        cam_up : Tuple(Float32, Float32, Float32),
      )
        half = slices // 2
        (-half..half).each do |s|
          p1 = project_3d_point(s.to_f32 * spacing, 0.0_f32, -half.to_f32 * spacing, cam_pos, cam_tgt, cam_up)
          p2 = project_3d_point(s.to_f32 * spacing, 0.0_f32, half.to_f32 * spacing, cam_pos, cam_tgt, cam_up)
          if p1 && p2
            commands << DrawCommand.new(DrawCommand::Type::Line, p1[0], p1[1], p2[0], p2[1], color: color)
          end
          p3 = project_3d_point(-half.to_f32 * spacing, 0.0_f32, s.to_f32 * spacing, cam_pos, cam_tgt, cam_up)
          p4 = project_3d_point(half.to_f32 * spacing, 0.0_f32, s.to_f32 * spacing, cam_pos, cam_tgt, cam_up)
          if p3 && p4
            commands << DrawCommand.new(DrawCommand::Type::Line, p3[0], p3[1], p4[0], p4[1], color: color)
          end
        end
      end

      def self.emit_3d_cube(
        commands : Array(DrawCommand),
        x : Float32, y : Float32, z : Float32,
        w : Float32, h : Float32, d : Float32,
        color : UInt32,
        cam_pos : Tuple(Float32, Float32, Float32),
        cam_tgt : Tuple(Float32, Float32, Float32),
        cam_up : Tuple(Float32, Float32, Float32),
      )
        hw = w / 2.0_f32
        hh = h / 2.0_f32
        hd = d / 2.0_f32

        corners = [
          {x - hw, y - hh, z - hd},
          {x - hw, y - hh, z + hd},
          {x - hw, y + hh, z - hd},
          {x - hw, y + hh, z + hd},
          {x + hw, y - hh, z - hd},
          {x + hw, y - hh, z + hd},
          {x + hw, y + hh, z - hd},
          {x + hw, y + hh, z + hd},
        ]

        faces = [
          {[1, 5, 7, 3], 0.0_f32, 0.0_f32, 1.0_f32, 0.90_f32},  # Front (+Z)
          {[4, 0, 2, 6], 0.0_f32, 0.0_f32, -1.0_f32, 0.70_f32}, # Back (-Z)
          {[3, 7, 6, 2], 0.0_f32, 1.0_f32, 0.0_f32, 1.00_f32},  # Top (+Y)
          {[0, 4, 5, 1], 0.0_f32, -1.0_f32, 0.0_f32, 0.50_f32}, # Bottom (-Y)
          {[5, 4, 6, 7], 1.0_f32, 0.0_f32, 0.0_f32, 0.85_f32},  # Right (+X)
          {[0, 1, 3, 2], -1.0_f32, 0.0_f32, 0.0_f32, 0.65_f32}, # Left (-X)
        ]

        faces.each do |face_indices, nx, ny, nz, shade|
          fcx = x + nx * hw
          fcy = y + ny * hh
          fcz = z + nz * hd
          v_dx = cam_pos[0] - fcx
          v_dy = cam_pos[1] - fcy
          v_dz = cam_pos[2] - fcz
          dot = v_dx * nx + v_dy * ny + v_dz * nz
          next if dot <= 0.0_f32

          pts = face_indices.map { |ci| project_3d_point(corners[ci][0], corners[ci][1], corners[ci][2], cam_pos, cam_tgt, cam_up) }
          if pts.all?
            p1 = pts[0].not_nil!
            p2 = pts[1].not_nil!
            p3 = pts[2].not_nil!
            p4 = pts[3].not_nil!

            a = (color >> 24) & 0xFF
            b = (((color >> 16) & 0xFF) * shade).to_u32.clamp(0_u32, 255_u32)
            g = (((color >> 8) & 0xFF) * shade).to_u32.clamp(0_u32, 255_u32)
            r = ((color & 0xFF) * shade).to_u32.clamp(0_u32, 255_u32)
            shaded_color = (a << 24) | (b << 16) | (g << 8) | r

            commands << DrawCommand.new(
              DrawCommand::Type::Quad,
              p1[0], p1[1], p2[0], p2[1], p3[0], p3[1], p4[0], p4[1],
              color: shaded_color
            )
          end
        end
      end

      def self.emit_3d_cube_wires(
        commands : Array(DrawCommand),
        x : Float32, y : Float32, z : Float32,
        w : Float32, h : Float32, d : Float32,
        color : UInt32,
        cam_pos : Tuple(Float32, Float32, Float32),
        cam_tgt : Tuple(Float32, Float32, Float32),
        cam_up : Tuple(Float32, Float32, Float32),
      )
        hw = w / 2.0_f32
        hh = h / 2.0_f32
        hd = d / 2.0_f32

        corners = [
          {x - hw, y - hh, z - hd},
          {x - hw, y - hh, z + hd},
          {x - hw, y + hh, z - hd},
          {x - hw, y + hh, z + hd},
          {x + hw, y - hh, z - hd},
          {x + hw, y - hh, z + hd},
          {x + hw, y + hh, z - hd},
          {x + hw, y + hh, z + hd},
        ]

        edges = [
          {0, 1}, {1, 3}, {3, 2}, {2, 0},
          {4, 5}, {5, 7}, {7, 6}, {6, 4},
          {0, 4}, {1, 5}, {2, 6}, {3, 7},
        ]

        edges.each do |e1, e2|
          c1 = corners[e1]
          c2 = corners[e2]
          p1 = project_3d_point(c1[0], c1[1], c1[2], cam_pos, cam_tgt, cam_up)
          p2 = project_3d_point(c2[0], c2[1], c2[2], cam_pos, cam_tgt, cam_up)
          if p1 && p2
            commands << DrawCommand.new(DrawCommand::Type::Line, p1[0], p1[1], p2[0], p2[1], color: color)
          end
        end
      end
    end
  end
end
