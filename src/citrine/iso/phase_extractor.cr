require "../gs/gif_packet_builder"
require "../ast/types"
require "../compiler/opcode"
require "./regex_engine"

module Citrine
  module ISO
    class ProgramProfile
      property phases : Array(Citrine::GS::Phase)
      property boot_messages : Array(String)
      property loop_start_phase : Int32
      property is_animated : Bool
      property has_button_checks : Bool
      property is_inline_assembly : Bool
      property inline_asm_words : Array(UInt32)
      property has_audio : Bool
      property num_tracks : Int32
      property bank_dur_ms : UInt32
      property frames_per_bank : UInt32

      def initialize(
        @phases = [] of Citrine::GS::Phase,
        @boot_messages = [] of String,
        @loop_start_phase = 0,
        @is_animated = false,
        @has_button_checks = false,
        @is_inline_assembly = false,
        @inline_asm_words = [] of UInt32,
        @has_audio = false,
        @num_tracks = 1,
        @bank_dur_ms = 1195_u32,
        @frames_per_bank = 72_u32
      )
      end
    end

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
        grid_res : Int32 = 64
      )
        return unless File.exists?(path)
        bytes = File.read(path).to_slice
        return unless bytes.size > 16 && String.new(bytes[0, 4]) == "CBT1"

        w = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[4, 2]).to_i
        h = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[6, 2]).to_i
        pal_size = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[10, 4]).to_i
        pal = bytes[14, pal_size]
        pixels = bytes[14 + pal_size + 4, w * h]

        step_x = w // grid_res
        step_y = h // grid_res

        grid_res.times do |gy|
          gx = 0
          while gx < grid_res
            px = (gx * step_x).clamp(0, w - 1)
            py = (gy * step_y).clamp(0, h - 1)
            pal_idx = pixels[py * w + px].to_i
            r = pal[pal_idx * 4].to_u32
            g = pal[pal_idx * 4 + 1].to_u32
            b = pal[pal_idx * 4 + 2].to_u32
            color = 0xFF000000_u32 | (b << 16) | (g << 8) | r

            span_len = 1
            while (gx + span_len) < grid_res
              npx = ((gx + span_len) * step_x).clamp(0, w - 1)
              npal_idx = pixels[py * w + npx].to_i
              nr = pal[npal_idx * 4].to_u32
              ng = pal[npal_idx * 4 + 1].to_u32
              nb = pal[npal_idx * 4 + 2].to_u32
              ncolor = 0xFF000000_u32 | (nb << 16) | (ng << 8) | nr
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



      def self.decode_coord(val : Int64?) : Float32
        return 0.0_f32 unless val
        u = (val & 0xFFFFFFFF_i64).to_u32
        return 0.0_f32 if u == 0_u32
        bytes = Bytes[(u & 0xFF).to_u8, ((u >> 8) & 0xFF).to_u8, ((u >> 16) & 0xFF).to_u8, ((u >> 24) & 0xFF).to_u8]
        f = IO::ByteFormat::LittleEndian.decode(Float32, bytes) rescue 0.0_f32
        if !f.nan? && !f.infinite? && f.abs < 2000.0_f32 && f.abs > 0.001_f32
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
        cam_up : Tuple(Float32, Float32, Float32)
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
        cam_up : Tuple(Float32, Float32, Float32)
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
        cam_up : Tuple(Float32, Float32, Float32)
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
        cam_up : Tuple(Float32, Float32, Float32)
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
          {0, 4}, {1, 5}, {2, 6}, {3, 7}
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

class ChannelInstance
  property capacity : Int32
  property items : Array(Int64)
  def initialize(@capacity : Int32)
    @items = [] of Int64
  end
end

class FiberFrame
  property pc : Int32
  property instructions : Array(UInt32)
  property caller_dest : Int32
  property caller_reg_base : Int32

  def initialize(@pc : Int32, @instructions : Array(UInt32), @caller_dest : Int32, @caller_reg_base : Int32)
  end
end

class FiberContext
  property fn_idx : Int32
  property pc : Int32
  property regs : Array(Int64)
  property done : Bool = false
  property instructions : Array(UInt32)
  property call_stack : Array(FiberFrame)
  property reg_base : Int32

  def initialize(@fn_idx : Int32, @instructions : Array(UInt32), num_regs : Int32 = 64)
    @pc = 0
    @regs = Array(Int64).new(1024, 0_i64)
    @done = false
    @call_stack = [] of FiberFrame
    @reg_base = 0
  end
end

struct CVal
  property type : UInt8
  property u32_val : UInt32
  property str_val : String
  property f32_val : Float32
  def initialize(@type : UInt8, @u32_val : UInt32 = 0_u32, @str_val : String = "", @f32_val : Float32 = 0.0_f32)
  end
end

struct FnEntry
  property name_idx : UInt32
  property argc : UInt8
  property num_regs : UInt8
  property offset : UInt32
  property count : UInt32
  def initialize(@name_idx, @argc, @num_regs, @offset, @count)
  end
end

struct CallFrame
  property return_pc : Int32
  property caller_instructions : Array(UInt32)
  property caller_dest : Int32
  property caller_reg_base : Int32
  def initialize(@return_pc, @caller_instructions, @caller_dest, @caller_reg_base)
  end
end

struct AllocationRecord
  property base_addr : Int64
  property size_bytes : Int32
  property context_name : String
  property freed : Bool
  property is_object : Bool
  property is_struct : Bool
  property field_count : Int32

  def initialize(@base_addr, @size_bytes, @context_name, @freed = false, @is_object = false, @is_struct = false, @field_count = 0)
  end
end

getter has_button_checks : Bool = false
getter inline_asm_words = [] of UInt32
getter is_inline_assembly : Bool = false
property has_audio : Bool = false

def self.build_default_runner_elf(cbc_bytes : Bytes? = nil, input_schedule : Array(VirtualInput) = [] of VirtualInput, vag_bytes : Bytes? = nil) : Bytes
  builder = new
  builder.generate(cbc_bytes, input_schedule, vag_bytes)
end

      def self.extract(cbc_bytes : Bytes?) : ProgramProfile
        new.extract(cbc_bytes)
      end

      def extract(cbc_bytes : Bytes?) : ProgramProfile
        boot_messages = [] of String
        loop_start_phase = 0
        has_button_checks = false
        is_inline_assembly = false
        inline_asm_words = [] of UInt32
        has_audio = false
        is_animated = false
        phases = [] of Phase

        magic = cbc_bytes ? (cbc_bytes.size >= 4 ? String.new(cbc_bytes[0..3]) : "") : ""
        is_cbc2 = (magic == "CBC2")
        if cbc_bytes && cbc_bytes.size > 20 && (magic == "CBC1" || is_cbc2)
    begin
      io = IO::Memory.new(cbc_bytes)
      io.read_string(4) # "CBC1" or "CBC2"
      io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      num_fns = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      num_consts = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      num_strings = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

      strings = [] of String
      num_strings.times do
        len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        strings << io.read_string(len)
      end

      constants = [] of CVal
      num_consts.times do
        ctype = io.read_byte.not_nil!
        case ctype
        when 2 # Int32
          v = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
          constants << CVal.new(ctype, (v.to_i64 & 0xFFFFFFFF_u64).to_u32)
        when 5 # Color
          v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          constants << CVal.new(ctype, v)
        when 6 # StringRef
          s_idx = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
          constants << CVal.new(ctype, 0_u32, strings[s_idx]? || "")
        when 3 # Float32
          f = io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
          constants << CVal.new(ctype, self.class.encode_f32(f).to_u32, f32_val: f)
        when 4 # Vec2
          io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
          io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
          constants << CVal.new(ctype, 0_u32)
        when 1 # Bool
          b = io.read_byte.not_nil!
          constants << CVal.new(ctype, b.to_u32)
        else
          io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          constants << CVal.new(ctype, 0_u32)
        end
      end

      fns = [] of FnEntry
      num_fns.times do
        n_idx = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        argc = io.read_byte.not_nil!
        num_regs = io.read_byte.not_nil!
        off = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        cnt = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        fns << FnEntry.new(n_idx, argc, num_regs, off, cnt)
      end

      instructions_start_pos = io.pos

      has_button_checks = false
      has_drawing = false
      has_audio = false
      inline_asm_words.clear
      fns.each do |fn|
        io.pos = instructions_start_pos + (fn.offset.to_i64 * 4)
        fn.count.times do
          instr = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          if is_cbc2
            instr_obj = Instruction.new(instr)
            is_call_native = (instr_obj.opcode == Opcode::CallNative)
            is_inline_asm  = (instr_obj.opcode == Opcode::InlineAsm)
          else
            op = ((instr >> 24) & 0xFF_u32).to_i
            is_call_native = (op == 52)
            is_inline_asm  = (op == 72)
          end
          nat = (instr & 0xFF_u32).to_i
          if is_call_native
            if (nat >= 40 && nat <= 43) || (nat >= 45 && nat <= 48)
              has_button_checks = true
            end
            if nat == 10 || nat == 11 || (nat >= 20 && nat <= 34) || (nat >= 100 && nat <= 111)
              has_drawing = true
            end
            if (nat >= 35 && nat <= 37) || (nat >= 220 && nat <= 224) || nat == 233 || nat == 234
              has_audio = true
            end
          elsif is_inline_asm
            imm = (instr & 0xFFFF_u32).to_i
            if imm < constants.size
              inline_asm_words << constants[imm].u32_val
            end
          end
        end
      end
      is_inline_assembly = !inline_asm_words.empty?
      has_audio ||= strings.any? do |s|
        down = s.downcase
        down.ends_with?(".vag") || down.ends_with?(".wav") || down.ends_with?(".cas") ||
          down.includes?("cdda") || down.includes?("cd-da") || s.includes?("SPU2")
      end

      main_fn = fns.find { |f| strings[f.name_idx]? == "__main__" }
      if main_fn
        io.pos = instructions_start_pos + (main_fn.offset.to_i64 * 4)
        instructions = [] of UInt32
        main_fn.count.times do
          instructions << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        end

        regs = Array(Int64).new(1024, 0_i64)
        reg_base = 0
        call_stack = [] of CallFrame
        objects = Hash(Int64, Array(Int64)).new
        object_types = Hash(Int64, Array(UInt8)).new
        next_obj_id = 1_i64
        arrays = Hash(Int64, Array(Int64)).new
        array_types = Hash(Int64, Array(UInt8)).new
        next_arr_id = 1000_i64
        io_streams = Hash(Int64, IO::Memory).new
        next_io_id = 2000_i64
        memory = Hash(Int64, Int64).new
        next_heap_addr = 0x00200000_i64
        object_classes = Hash(Int64, UInt32).new
        active_context_name = ""
        scratch_pool_base = 0x00400000_i64
        scratch_pool_ptr = scratch_pool_base
        allocations = Hash(Int64, AllocationRecord).new
        free_list = [] of Tuple(Int64, Int32)
        compiled_regexes = Hash(Int64, SimpleRegex).new
        next_regex_id = 5000_i64
        vec2_store = Hash(Int64, Tuple(Int64, Int64)).new
        next_vec2_id = 10000_i64
        loaded_textures = Hash(Int64, String).new
        channels = Hash(Int64, ChannelInstance).new
        next_chan_id = 7000_i64
        active_fibers = [] of FiberContext
        is_float_reg = Array(Bool).new(1024, false)
        reg_types = Array(UInt8).new(1024, 2_u8)
        active_camera : Tuple(Tuple(Float32, Float32, Float32), Tuple(Float32, Float32, Float32), Tuple(Float32, Float32, Float32))? = nil
        rand_state = 0x517cc1b727220a95_u64
        current_commands = [] of DrawCommand
        phases = [] of Phase
        pc = 0
        max_steps = 2_000_000
        steps = 0
        first_frame_done = false
        in_main_loop = false
        current_loop_message : String? = nil
        cycle_counter = 147_456_000_u64

        simulated_button_press = false
        button_phase_count = 0

        is_animated = false
        has_dynamic_frame_text = false
        animation_checked = false
        prev_frame_cmds = [] of DrawCommand
        max_anim_frames = 60
        anim_frame_count = 0
        frames_per_bank = 16
        max_banks = 3
        simulated_btn_id = 0

        while pc >= 0 && pc < instructions.size && steps < max_steps && !first_frame_done
          steps += 1
          instr = instructions[pc]
          if is_cbc2
            instr_obj = Instruction.new(instr)
            opcode = instr_obj.legacy_opcode_number
            subop = instr_obj.subop
            dst = instr_obj.dst.to_i
            a = instr_obj.a.to_i
            b = instr_obj.b.to_i
            imm16 = if instr_obj.opcode == Opcode::LoadImm
                      case instr_obj.subop
                      when LoadImmSubOp::Nil.value then 0_i64
                      when LoadImmSubOp::Bool.value then (instr_obj.imm16 != 0 ? 1_i64 : 0_i64)
                      when LoadImmSubOp::Int16.value then instr_obj.branch_offset.to_i64
                      when LoadImmSubOp::UInt16.value then instr_obj.imm16.to_i64
                      when LoadImmSubOp::Upper16.value then (instr_obj.imm16.to_i64 << 16)
                      when LoadImmSubOp::Zero.value then 0_i64
                      when LoadImmSubOp::MinusOne.value then -1_i64
                      else instr_obj.imm16.to_i64
                      end
                    else
                      instr_obj.imm16.to_i64
                    end
            imm16_signed = if instr_obj.opcode == Opcode::Jump
                             instr_obj.jump_offset24.to_i64
                           else
                             instr_obj.branch_offset.to_i64
                           end
            offset8 = instr_obj.offset8.to_i
          else
            opcode = (instr >> 24) & 0xFF
            subop = 0_u8
            dst = ((instr >> 16) & 0xFF).to_i
            a = ((instr >> 8) & 0xFF).to_i
            b = (instr & 0xFF).to_i
            imm16 = (instr & 0xFFFF).to_i64
            val16 = (instr & 0xFFFF).to_i32
            imm16_signed = (val16 >= 0x8000 ? val16 - 0x10000 : val16).to_i64
            offset8 = (b >= 0x80 ? b - 0x100 : b)
          end

          dst_r = (reg_base + dst).clamp(0, 1023)
          a_r = (reg_base + a).clamp(0, 1023)
          b_r = (reg_base + b).clamp(0, 1023)

          pc += 1

          case opcode
          when 0 # Nop
          when 1 # Move
            regs[dst_r] = regs[a_r]
            reg_types[dst_r] = reg_types[a_r]
            is_float_reg[dst_r] = is_float_reg[a_r]
          when 2 # LoadNil
            regs[dst_r] = 0_i64
            reg_types[dst_r] = 0_u8
            is_float_reg[dst_r] = false
          when 3 # LoadBool
            regs[dst_r] = imm16
            reg_types[dst_r] = 1_u8
            is_float_reg[dst_r] = false
          when 4 # LoadInt
            regs[dst_r] = imm16
            reg_types[dst_r] = 2_u8
            is_float_reg[dst_r] = false
          when 5 # LoadConst
            if imm16 < constants.size
              c = constants[imm16]
              case c.type
              when 2 # Int32
                regs[dst_r] = c.u32_val.to_i32!.to_i64
                reg_types[dst_r] = 2_u8
                is_float_reg[dst_r] = false
              when 3 # Float32
                regs[dst_r] = self.class.encode_f32(c.f32_val)
                reg_types[dst_r] = 3_u8
                is_float_reg[dst_r] = true
              when 5 # Color
                regs[dst_r] = c.u32_val.to_i64
                reg_types[dst_r] = 5_u8
                is_float_reg[dst_r] = false
              when 1 # Bool
                regs[dst_r] = c.u32_val.to_i64
                reg_types[dst_r] = 1_u8
                is_float_reg[dst_r] = false
              when 6 # String
                regs[dst_r] = imm16.to_i64
                reg_types[dst_r] = 7_u8
                is_float_reg[dst_r] = false
              else
                regs[dst_r] = imm16.to_i64
                reg_types[dst_r] = 2_u8
                is_float_reg[dst_r] = false
              end
            else
              regs[dst_r] = imm16.to_i64
              reg_types[dst_r] = 2_u8
              is_float_reg[dst_r] = false
            end
          when 10 # Add
            if is_float_reg[a_r] || is_float_reg[b_r]
              is_float_reg[dst_r] = true
              fa = self.class.decode_coord(regs[a_r])
              fb = self.class.decode_coord(regs[b_r])
              regs[dst_r] = self.class.encode_f32(fa + fb)
            else
              is_float_reg[dst_r] = false
              regs[dst_r] = regs[a_r] &+ regs[b_r]
            end
          when 11 # Sub
            if is_float_reg[a_r] || is_float_reg[b_r]
              is_float_reg[dst_r] = true
              fa = self.class.decode_coord(regs[a_r])
              fb = self.class.decode_coord(regs[b_r])
              regs[dst_r] = self.class.encode_f32(fa - fb)
            else
              is_float_reg[dst_r] = false
              regs[dst_r] = regs[a_r] &- regs[b_r]
            end
          when 12 # Mul
            if is_float_reg[a_r] || is_float_reg[b_r]
              is_float_reg[dst_r] = true
              fa = self.class.decode_coord(regs[a_r])
              fb = self.class.decode_coord(regs[b_r])
              regs[dst_r] = self.class.encode_f32(fa * fb)
            else
              is_float_reg[dst_r] = false
              regs[dst_r] = regs[a_r] &* regs[b_r]
            end
          when 13 # Div
            if is_float_reg[a_r] || is_float_reg[b_r]
              is_float_reg[dst_r] = true
              fa = self.class.decode_coord(regs[a_r])
              fb = self.class.decode_coord(regs[b_r])
              regs[dst_r] = self.class.encode_f32(fb != 0.0_f32 ? (fa / fb) : 0.0_f32)
            else
              is_float_reg[dst_r] = false
              regs[dst_r] = regs[b_r] != 0 ? (regs[a_r] // regs[b_r]) : 0_i64
            end
          when 14 # Mod
            regs[dst_r] = regs[b_r] != 0 ? (regs[a_r] % regs[b_r]) : 0_i64
            is_float_reg[dst_r] = false
          when 15 # Neg
            if is_float_reg[a_r]
              is_float_reg[dst_r] = true
              fa = self.class.decode_coord(regs[a_r])
              regs[dst_r] = self.class.encode_f32(-fa)
            else
              is_float_reg[dst_r] = false
              regs[dst_r] = 0_i64 &- regs[a_r]
            end
          when 16 # BitAnd
            regs[dst_r] = regs[a_r] & regs[b_r]
            reg_types[dst_r] = (reg_types[a_r] == 1_u8 && reg_types[b_r] == 1_u8) ? 1_u8 : 2_u8
            is_float_reg[dst_r] = false
          when 17 # BitOr
            regs[dst_r] = regs[a_r] | regs[b_r]
            reg_types[dst_r] = (reg_types[a_r] == 1_u8 && reg_types[b_r] == 1_u8) ? 1_u8 : 2_u8
            is_float_reg[dst_r] = false
          when 18 # BitXor
            regs[dst_r] = regs[a_r] ^ regs[b_r]
            reg_types[dst_r] = (reg_types[a_r] == 1_u8 && reg_types[b_r] == 1_u8) ? 1_u8 : 2_u8
            is_float_reg[dst_r] = false
          when 19 # ShiftLeft
            shift = (regs[b_r] & 0x3F).to_i
            regs[dst_r] = ((regs[a_r].to_u64! << shift) & 0xFFFFFFFFFFFFFFFF_u64).to_i64!
            reg_types[dst_r] = 2_u8
            is_float_reg[dst_r] = false
          when 20 # Vec2New
            id = next_vec2_id
            next_vec2_id += 1
            vec2_store[id] = {regs[a_r], regs[b_r]}
            regs[dst_r] = id
          when 21 # Vec2GetX
            id = regs[a_r]
            regs[dst_r] = vec2_store[id]?.try(&.[0]) || 0_i64
          when 22 # Vec2GetY
            id = regs[a_r]
            regs[dst_r] = vec2_store[id]?.try(&.[1]) || 0_i64
          when 23 # Vec2SetX
            id = regs[dst_r]
            if entry = vec2_store[id]?
              vec2_store[id] = {regs[a_r], entry[1]}
            end
          when 24 # Vec2SetY
            id = regs[dst_r]
            if entry = vec2_store[id]?
              vec2_store[id] = {entry[0], regs[a_r]}
            end
          when 25 # Vec2Add
            id1 = regs[a_r]
            id2 = regs[b_r]
            v1 = vec2_store[id1]? || {0_i64, 0_i64}
            v2 = vec2_store[id2]? || {0_i64, 0_i64}
            new_id = next_vec2_id
            next_vec2_id += 1
            vec2_store[new_id] = {v1[0] &+ v2[0], v1[1] &+ v2[1]}
            regs[dst_r] = new_id
          when 27 # ShiftRight
            shift = (regs[b_r] & 0x3F).to_i
            regs[dst_r] = (regs[a_r].to_u64! >> shift).to_i64!
          when 28 # BitNot
            regs[dst_r] = ~regs[a_r]
          when 30 # Eq
            val_a = regs[a_r]
            val_b = regs[b_r]
            is_eq = if val_a == val_b
                      true
                    else
                      str_a = if val_a >= 0 && val_a < constants.size && constants[val_a.to_i]?.try(&.type) == 6_u8
                                constants[val_a.to_i].str_val
                              elsif val_a >= 0 && val_a <= Int32::MAX && strings[val_a.to_i32!]?
                                strings[val_a.to_i32!]
                              else
                                nil
                              end
                      str_b = if val_b >= 0 && val_b < constants.size && constants[val_b.to_i]?.try(&.type) == 6_u8
                                constants[val_b.to_i].str_val
                              elsif val_b >= 0 && val_b <= Int32::MAX && strings[val_b.to_i32!]?
                                strings[val_b.to_i32!]
                              else
                                nil
                              end
                      if str_a && str_b
                        str_a == str_b
                      else
                        false
                      end
                    end
            regs[dst_r] = is_eq ? 1_i64 : 0_i64
            reg_types[dst_r] = 1_u8
          when 31 # Ne
            val_a = regs[a_r]
            val_b = regs[b_r]
            is_eq = if val_a == val_b
                      true
                    else
                      str_a = if val_a >= 0 && val_a < constants.size && constants[val_a.to_i]?.try(&.type) == 6_u8
                                constants[val_a.to_i].str_val
                              elsif val_a >= 0 && val_a <= Int32::MAX && strings[val_a.to_i32!]?
                                strings[val_a.to_i32!]
                              else
                                nil
                              end
                      str_b = if val_b >= 0 && val_b < constants.size && constants[val_b.to_i]?.try(&.type) == 6_u8
                                constants[val_b.to_i].str_val
                              elsif val_b >= 0 && val_b <= Int32::MAX && strings[val_b.to_i32!]?
                                strings[val_b.to_i32!]
                              else
                                nil
                              end
                      if str_a && str_b
                        str_a == str_b
                      else
                        false
                      end
                    end
            regs[dst_r] = !is_eq ? 1_i64 : 0_i64
            reg_types[dst_r] = 1_u8
          when 32 # Lt
            regs[dst_r] = (if is_float_reg[a_r] || is_float_reg[b_r]
                             self.class.decode_coord(regs[a_r]) < self.class.decode_coord(regs[b_r])
                           else
                             regs[a_r] < regs[b_r]
                           end) ? 1_i64 : 0_i64
            reg_types[dst_r] = 1_u8
            is_float_reg[dst_r] = false
          when 33 # Le
            regs[dst_r] = (if is_float_reg[a_r] || is_float_reg[b_r]
                             self.class.decode_coord(regs[a_r]) <= self.class.decode_coord(regs[b_r])
                           else
                             regs[a_r] <= regs[b_r]
                           end) ? 1_i64 : 0_i64
            reg_types[dst_r] = 1_u8
            is_float_reg[dst_r] = false
          when 34 # Gt
            regs[dst_r] = (if is_float_reg[a_r] || is_float_reg[b_r]
                             self.class.decode_coord(regs[a_r]) > self.class.decode_coord(regs[b_r])
                           else
                             regs[a_r] > regs[b_r]
                           end) ? 1_i64 : 0_i64
            reg_types[dst_r] = 1_u8
            is_float_reg[dst_r] = false
          when 35 # Ge
            regs[dst_r] = (if is_float_reg[a_r] || is_float_reg[b_r]
                             self.class.decode_coord(regs[a_r]) >= self.class.decode_coord(regs[b_r])
                           else
                             regs[a_r] >= regs[b_r]
                           end) ? 1_i64 : 0_i64
            reg_types[dst_r] = 1_u8
            is_float_reg[dst_r] = false
          when 40 # Jump
            target_pc = pc + imm16_signed
            if imm16_signed < 0 && target_pc >= 0 && target_pc < instructions.size
              target_instr = instructions[target_pc]
              is_win_open = if is_cbc2
                              t_obj = Instruction.new(target_instr)
                              t_obj.opcode == Opcode::CallNative && (target_instr & 0xFF) == 3
                            else
                              target_opcode = (target_instr >> 24) & 0xFF
                              target_native = target_instr & 0xFF
                              target_opcode == 52 && target_native == 3
                            end
              if is_win_open
                if phases.empty?
                  phases << Phase.new(current_commands.dup, 0_u32)
                  first_frame_done = true
                end
              end
            end
            pc += imm16_signed
          when 41 # JumpIfTrue
            cond_t = reg_types[dst_r]
            is_truthy = !(cond_t == 0_u8 || (cond_t == 1_u8 && regs[dst_r] == 0_i64))
            pc += imm16_signed if is_truthy
          when 42 # JumpIfFalse
            cond_t = reg_types[dst_r]
            is_falsy = cond_t == 0_u8 || (cond_t == 1_u8 && regs[dst_r] == 0_i64)
            pc += imm16_signed if is_falsy
          when 50 # Call
            target_fn_idx = imm16.to_i
            if target_fn = fns[target_fn_idx]?
              saved_pos = io.pos
              io.pos = instructions_start_pos + (target_fn.offset.to_i64 * 4)
              fn_instructions = [] of UInt32
              target_fn.count.times do
                fn_instructions << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              end
              io.pos = saved_pos

              fn_name = strings[target_fn.name_idx]? || "fn_#{target_fn_idx}"

              call_stack << CallFrame.new(pc, instructions, dst_r, reg_base)
              reg_base = (reg_base + dst + 1).clamp(0, 1000)
              instructions = fn_instructions
              pc = 0
            end
          when 51 # Return
            if frame = call_stack.pop?
              ret_val = regs[dst_r]
              ret_type = reg_types[dst_r]
              reg_base = frame.caller_reg_base
              regs[frame.caller_dest] = ret_val
              reg_types[frame.caller_dest] = ret_type
              instructions = frame.caller_instructions
              pc = frame.return_pc
            else
              break
            end
          when 70 # Halt
            break
          when 72 # InlineAsm
            if imm16 < constants.size
              c_val = constants[imm16]
              word = c_val.u32_val
              if (word & 0xFFE0F800_u32) == 0x40004800_u32 # mfc0 $rt, $9 (COP0 Count)
                rt = ((word >> 16) & 0x1F).to_i
                cycle_counter &+= 147_456_u64
                regs[dst_r] = cycle_counter.to_i64
                if rt != 0
                  regs[(reg_base + rt).clamp(0, 1023)] = cycle_counter.to_i64
                end
              else
                if dst != 0
                  v0_val = regs[(reg_base + 2).clamp(0, 1023)]? || 1_i64
                  regs[dst_r] = v0_val
                end
              end
            end
          when 26 # ColorOp
            r_val = (regs[a_r] & 0xFF).to_u32
            g_val = (regs[b_r] & 0xFF).to_u32
            regs[dst_r] = (0xFF000000_u32 | (g_val << 8) | r_val).to_i64
          when 73 # BranchCmp
            val_a = regs[dst_r]
            val_b = regs[a_r]
            cond = if is_float_reg[dst_r] || is_float_reg[a_r]
                     fa = self.class.decode_coord(val_a)
                     fb = self.class.decode_coord(val_b)
                     case subop
                     when 0 then fa == fb
                     when 1 then fa != fb
                     when 2 then fa < fb
                     when 3 then fa <= fb
                     when 4 then fa > fb
                     when 5 then fa >= fb
                     else false
                     end
                   else
                     case subop
                     when 0 then val_a == val_b
                     when 1 then val_a != val_b
                     when 2 then val_a < val_b
                     when 3 then val_a <= val_b
                     when 4 then val_a > val_b
                     when 5 then val_a >= val_b
                     else false
                     end
                   end
            pc += offset8 if cond
          when 74 # LoopDecBr
            if subop == 2
              regs[dst_r] &+= 1
              pc += offset8 if regs[dst_r] < regs[a_r]
            elsif subop == 1
              regs[dst_r] &-= 1
              pc += imm16_signed if regs[dst_r] >= 0
            else
              regs[dst_r] &-= 1
              pc += imm16_signed if regs[dst_r] != 0
            end
          when 75 # FusedMadd
            case subop
            when 0 then regs[dst_r] = regs[dst_r] &+ (regs[a_r] &* regs[b_r])
            when 1 then regs[dst_r] = regs[dst_r] &- (regs[a_r] &* regs[b_r])
            else regs[dst_r] = regs[dst_r] &+ (regs[a_r] &* regs[b_r])
            end
          when 76 # FiberOp
            case subop
            when 0 # Spawn
              target_fn_idx = imm16.to_i
              if target_fn = fns[target_fn_idx]?
                saved_pos = io.pos
                io.pos = instructions_start_pos + (target_fn.offset.to_i64 * 4)
                fiber_instrs = [] of UInt32
                target_fn.count.times do
                  fiber_instrs << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
                end
                io.pos = saved_pos
                new_fiber = FiberContext.new(target_fn_idx, fiber_instrs, target_fn.num_regs.to_i)
                target_fn.argc.to_i.times do |i|
                  new_fiber.regs[i] = regs[dst_r + 1 + i]
                end
                active_fibers << new_fiber
                regs[dst_r] = active_fibers.size.to_i64
              else
                regs[dst_r] = 0_i64
              end
            when 1 # Yield
              # Fiber yielded in main loop
            end
          when 77 # ChannelOp
            # Channel operations handled via CallNative 80..85
          when 78 # FloatAlu
            fa = self.class.decode_coord(regs[a_r])
            fb = self.class.decode_coord(regs[b_r])
            if subop == 7 # FcvtSW
              is_float_reg[dst_r] = false
              regs[dst_r] = (fa.nan? || fa.infinite? || fa < -9.22e18_f32 || fa > 9.22e18_f32) ? 0_i64 : fa.to_i64
            else
              is_float_reg[dst_r] = true
              fres = case subop
                     when 0 then fa + fb
                     when 1 then fa - fb
                     when 2 then fa * fb
                     when 3 then fb != 0.0_f32 ? (fa / fb) : 0.0_f32
                     when 4 then -fa
                     when 5 then fa.abs
                     when 6 then fa >= 0.0_f32 ? Math.sqrt(fa) : 0.0_f32
                     else fa + fb
                     end
              regs[dst_r] = self.class.encode_f32(fres)
            end
          when 52 # CallNative
            base = a
            base_r = (reg_base + base).clamp(0, 1023)
            native_id = b

            case native_id
            when 3 # WindowOpen
              in_main_loop = true
              regs[dst_r] = 1_i64
            when 40, 41, 42 # ButtonDown, ButtonPressed, ButtonReleased
              regs[dst_r] = 0_i64

            when 45, 46, 47 # ActionPressed, ActionDown, ActionReleased
              act_id = regs[base_r].to_i
              regs[dst_r] = if is_animated && has_button_checks
                              0_i64
                            elsif simulated_button_press
                              1_i64
                            else
                              0_i64
                            end
            when 11 # EndDrawing
              # Rewind Tier 1 Per-Frame Scratch Pool at V-Blank (O(1))
              scratch_pool_ptr = scratch_pool_base
              allocations.reject! do |addr, a|
                if a.is_struct || addr >= scratch_pool_base
                  (a.size_bytes // 4).times { |i| memory.delete(addr + (i * 4)) }
                  true
                else
                  false
                end
              end

              # Step cooperative fibers (e.g. 03 entity coroutines, 09 workers)
              if !active_fibers.empty?
                active_fibers.each do |fiber|
                  next if fiber.done
                  fiber_steps = 0
                  while fiber.pc >= 0 && fiber.pc < fiber.instructions.size && fiber_steps < 500
                    fiber_steps += 1
                    f_instr = fiber.instructions[fiber.pc]
                    fiber.pc += 1

                    f_obj = Instruction.new(f_instr)
                    f_op = f_obj.opcode
                    f_subop = f_obj.subop
                    f_dst = f_obj.dst.to_i
                    f_a = f_obj.a.to_i
                    f_b = f_obj.b.to_i
                    f_dst_r = (fiber.reg_base + f_dst).clamp(0, 1023)
                    f_a_r = (fiber.reg_base + f_a).clamp(0, 1023)
                    f_b_r = (fiber.reg_base + f_b).clamp(0, 1023)

                    if f_op == Opcode::FiberOp && f_subop == FiberSubOp::Yield.value
                      break
                    elsif f_op == Opcode::Return
                      if frame = fiber.call_stack.pop?
                        ret_val = fiber.regs[f_dst_r]
                        fiber.reg_base = frame.caller_reg_base
                        fiber.regs[frame.caller_dest] = ret_val
                        fiber.instructions = frame.instructions
                        fiber.pc = frame.pc
                      else
                        fiber.done = true
                        break
                      end
                    elsif f_op == Opcode::Move
                      fiber.regs[f_dst_r] = fiber.regs[f_a_r]
                    elsif f_op == Opcode::LoadImm
                      imm_val = case f_subop
                                when LoadImmSubOp::Nil.value then 0_i64
                                when LoadImmSubOp::Bool.value then (f_obj.imm16 != 0 ? 1_i64 : 0_i64)
                                when LoadImmSubOp::Int16.value then f_obj.branch_offset.to_i64
                                when LoadImmSubOp::UInt16.value then f_obj.imm16.to_i64
                                when LoadImmSubOp::Upper16.value then (f_obj.imm16.to_i64 << 16)
                                when LoadImmSubOp::Zero.value then 0_i64
                                when LoadImmSubOp::MinusOne.value then -1_i64
                                else f_obj.imm16.to_i64
                                end
                      fiber.regs[f_dst_r] = imm_val
                    elsif f_op == Opcode::LoadConst
                      c_idx = f_obj.imm16.to_i
                      if c_idx < constants.size
                        c = constants[c_idx]
                        fiber.regs[f_dst_r] = c.u32_val.to_i32!.to_i64
                      end
                    elsif f_op == Opcode::Add
                      fiber.regs[f_dst_r] = fiber.regs[f_a_r] &+ fiber.regs[f_b_r]
                    elsif f_op == Opcode::Sub
                      fiber.regs[f_dst_r] = fiber.regs[f_a_r] &- fiber.regs[f_b_r]
                    elsif f_op == Opcode::Mul
                      fiber.regs[f_dst_r] = fiber.regs[f_a_r] &* fiber.regs[f_b_r]
                    elsif f_op == Opcode::DivMod
                      divisor = fiber.regs[f_b_r]
                      fiber.regs[f_dst_r] = divisor != 0 ? (f_subop == DivModSubOp::ModS32.value ? fiber.regs[f_a_r] % divisor : fiber.regs[f_a_r] // divisor) : 0_i64
                    elsif f_op == Opcode::Compare
                      va = fiber.regs[f_a_r]; vb = fiber.regs[f_b_r]
                      cmp_res = case f_subop
                                when CompareSubOp::Eq.value then va == vb
                                when CompareSubOp::Ne.value then va != vb
                                when CompareSubOp::Lt.value then va < vb
                                when CompareSubOp::Le.value then va <= vb
                                when CompareSubOp::Gt.value then va > vb
                                when CompareSubOp::Ge.value then va >= vb
                                else va == vb
                                end
                      fiber.regs[f_dst_r] = cmp_res ? 1_i64 : 0_i64
                    elsif f_op == Opcode::BranchZ
                      cond = fiber.regs[f_dst_r]
                      take = f_subop == BranchZSubOp::Falsy.value ? (cond == 0) : (cond != 0)
                      fiber.pc += f_obj.branch_offset.to_i if take
                    elsif f_op == Opcode::BranchCmp
                      val_a = fiber.regs[f_dst_r]
                      val_b = fiber.regs[f_a_r]
                      cond = case f_subop
                             when 0 then val_a == val_b
                             when 1 then val_a != val_b
                             when 2 then val_a < val_b
                             when 3 then val_a <= val_b
                             when 4 then val_a > val_b
                             when 5 then val_a >= val_b
                             else false
                             end
                      fiber.pc += f_obj.offset8.to_i if cond
                    elsif f_op == Opcode::Jump
                      fiber.pc += f_obj.jump_offset24.to_i
                    elsif f_op == Opcode::Call
                      target_fn_idx = f_obj.imm16.to_i
                      if target_fn = fns[target_fn_idx]?
                        saved_pos = io.pos
                        io.pos = instructions_start_pos + (target_fn.offset.to_i64 * 4)
                        fn_instrs = [] of UInt32
                        target_fn.count.times do
                          fn_instrs << io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
                        end
                        io.pos = saved_pos
                        fiber.call_stack << FiberFrame.new(fiber.pc, fiber.instructions, f_dst_r, fiber.reg_base)
                        fiber.reg_base = (fiber.reg_base + f_dst + 1).clamp(0, 1000)
                        fiber.instructions = fn_instrs
                        fiber.pc = 0
                      end
                    elsif f_op == Opcode::CallNative
                      nat_id = f_b
                      base_idx = f_a_r
                      dst_idx = f_dst_r
                      case nat_id
                      when 151 # ObjectGetField
                        oid = fiber.regs[base_idx]
                        fld = fiber.regs[base_idx + 1].to_i
                        fiber.regs[dst_idx] = memory[oid + 8 + (fld * 4)]? || objects[oid]?.try(&.[fld]?) || 0_i64
                      when 152 # ObjectSetField
                        oid = fiber.regs[base_idx]
                        fld = fiber.regs[base_idx + 1].to_i
                        v = fiber.regs[base_idx + 2]
                        memory[oid + 8 + (fld * 4)] = v
                        if obj = objects[oid]?
                          while obj.size <= fld; obj << 0_i64; end
                          obj[fld] = v
                        end
                        fiber.regs[dst_idx] = v
                      when 80 # ChannelNew
                        cid = next_chan_id; next_chan_id += 1
                        cap = fiber.regs[base_idx].to_i
                        cap = 16 if cap <= 0
                        channels[cid] = ChannelInstance.new(cap)
                        fiber.regs[dst_idx] = cid
                      when 81 # ChannelSend
                        cid = fiber.regs[base_idx]
                        val = fiber.regs[base_idx + 1]
                        if ch = channels[cid]?
                          ch.items << val if ch.items.size < ch.capacity
                        end
                        fiber.regs[dst_idx] = 1_i64
                      when 82, 83 # ChannelReceive, ChannelTryReceive
                        cid = fiber.regs[base_idx]
                        if ch = channels[cid]?
                          fiber.regs[dst_idx] = ch.items.empty? ? 0_i64 : ch.items.shift
                        else
                          fiber.regs[dst_idx] = 0_i64
                        end
                      when 84 # ChannelCount
                        cid = fiber.regs[base_idx]
                        fiber.regs[dst_idx] = channels[cid]?.try(&.items.size.to_i64) || 0_i64
                      when 85 # ChannelCapacity
                        cid = fiber.regs[base_idx]
                        fiber.regs[dst_idx] = channels[cid]?.try(&.capacity.to_i64) || 16_i64
                      end
                    end
                  end
                end
              end

              if current_commands.size > 0
                if phases.empty?
                  phases << Phase.new(current_commands.dup, 0_u32, current_loop_message)
                  current_loop_message = nil
                  prev_frame_cmds = current_commands.dup
                  current_commands = [] of DrawCommand
                else
                  if current_commands != prev_frame_cmds || has_dynamic_frame_text
                    is_animated = true
                  end
                  first_frame_done = true
                end
              end
            when 12 # ClearBackground
              val = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: color)
            when 20 # DrawRectangle
              x = self.class.decode_coord(regs[base_r]).to_i32
              y = self.class.decode_coord(regs[base_r + 1]).to_i32
              w = self.class.decode_coord(regs[base_r + 2]).to_i32
              h = self.class.decode_coord(regs[base_r + 3]).to_i32
              val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x &+ w, y &+ h, color: color)
            when 21 # DrawCircle
              cx = self.class.decode_coord(regs[base_r]).to_i32
              cy = self.class.decode_coord(regs[base_r + 1]).to_i32
              radius = self.class.decode_coord(regs[base_r + 2]).to_i32
              val = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Circle, cx, cy, 0, 0, 0, 0, radius: radius, color: color)
            when 22 # DrawLine
              x1 = self.class.decode_coord(regs[base_r]).to_i32
              y1 = self.class.decode_coord(regs[base_r + 1]).to_i32
              x2 = self.class.decode_coord(regs[base_r + 2]).to_i32
              y2 = self.class.decode_coord(regs[base_r + 3]).to_i32
              val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Line, x1, y1, x2, y2, color: color)
            when 23 # DrawTriangle
              x1 = self.class.decode_coord(regs[base_r]).to_i32
              y1 = self.class.decode_coord(regs[base_r + 1]).to_i32
              x2 = self.class.decode_coord(regs[base_r + 2]).to_i32
              y2 = self.class.decode_coord(regs[base_r + 3]).to_i32
              x3 = self.class.decode_coord(regs[base_r + 4]).to_i32
              y3 = self.class.decode_coord(regs[base_r + 5]).to_i32
              val = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Triangle, x1, y1, x2, y2, x3, y3, color: color)
            when 24 # DrawText
              t_val = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
              text = (t_val < constants.size) ? (constants[t_val]?.try(&.str_val) || "") : ""
              if md = text.match(/Frame:\s*(\d+)/i)
                has_dynamic_frame_text = true
                text = text.sub(md[0], "Frame: 00000")
              end
              x = self.class.decode_coord(regs[base_r + 1]).to_i32
              y = self.class.decode_coord(regs[base_r + 2]).to_i32
              size = self.class.decode_coord(regs[base_r + 3]).to_i32
              val = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Text, x, y, size, 0, color: color, text: text)
            when 25 # BeginMode3D
              cam_id = regs[base_r]
              cam_fields = objects[cam_id]?
              pos_id = (cam_fields && cam_fields.size > 0) ? cam_fields[0] : 0_i64
              tgt_id = (cam_fields && cam_fields.size > 1) ? cam_fields[1] : 0_i64
              up_id  = (cam_fields && cam_fields.size > 2) ? cam_fields[2] : 0_i64

              pos_fields = objects[pos_id]?
              tgt_fields = objects[tgt_id]?
              up_fields  = objects[up_id]?

              c_pos_x = pos_fields ? self.class.decode_coord(pos_fields[0]?) : 0.0_f32
              c_pos_y = pos_fields ? self.class.decode_coord(pos_fields[1]?) : 4.5_f32
              c_pos_z = pos_fields ? self.class.decode_coord(pos_fields[2]?) : 8.5_f32

              c_tgt_x = tgt_fields ? self.class.decode_coord(tgt_fields[0]?) : 0.0_f32
              c_tgt_y = tgt_fields ? self.class.decode_coord(tgt_fields[1]?) : 0.0_f32
              c_tgt_z = tgt_fields ? self.class.decode_coord(tgt_fields[2]?) : 0.0_f32

              c_up_x = up_fields ? self.class.decode_coord(up_fields[0]?) : 0.0_f32
              c_up_y = up_fields ? self.class.decode_coord(up_fields[1]?) : 1.0_f32
              c_up_z = up_fields ? self.class.decode_coord(up_fields[2]?) : 0.0_f32

              if c_pos_x == 0.0_f32 && c_pos_y == 0.0_f32 && c_pos_z == 0.0_f32
                c_pos_y = 4.5_f32
                c_pos_z = 8.5_f32
              end

              active_camera = {
                {c_pos_x, c_pos_y, c_pos_z},
                {c_tgt_x, c_tgt_y, c_tgt_z},
                {c_up_x,  c_up_y,  c_up_z}
              }
            when 26 # EndMode3D
              active_camera = nil
            when 27 # DrawCube
              cam_cfg = active_camera || { {0.0_f32, 4.5_f32, 8.5_f32}, {0.0_f32, 0.0_f32, 0.0_f32}, {0.0_f32, 1.0_f32, 0.0_f32} }
              c_pos, c_tgt, c_up = cam_cfg

              cx = self.class.decode_coord(regs[base_r])
              cy = self.class.decode_coord(regs[base_r + 1])
              cz = self.class.decode_coord(regs[base_r + 2])
              cw = self.class.decode_coord(regs[base_r + 3])
              ch = self.class.decode_coord(regs[base_r + 4])
              cd = self.class.decode_coord(regs[base_r + 5])
              cw = 1.0_f32 if cw <= 0.0_f32
              ch = 1.0_f32 if ch <= 0.0_f32
              cd = 1.0_f32 if cd <= 0.0_f32

              val = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val

              self.class.emit_3d_cube(current_commands, cx, cy, cz, cw, ch, cd, color, c_pos, c_tgt, c_up)
            when 28 # DrawCubeWires
              cam_cfg = active_camera || { {0.0_f32, 4.5_f32, 8.5_f32}, {0.0_f32, 0.0_f32, 0.0_f32}, {0.0_f32, 1.0_f32, 0.0_f32} }
              c_pos, c_tgt, c_up = cam_cfg

              cx = self.class.decode_coord(regs[base_r])
              cy = self.class.decode_coord(regs[base_r + 1])
              cz = self.class.decode_coord(regs[base_r + 2])
              cw = self.class.decode_coord(regs[base_r + 3])
              ch = self.class.decode_coord(regs[base_r + 4])
              cd = self.class.decode_coord(regs[base_r + 5])
              cw = 1.0_f32 if cw <= 0.0_f32
              ch = 1.0_f32 if ch <= 0.0_f32
              cd = 1.0_f32 if cd <= 0.0_f32

              val = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val

              self.class.emit_3d_cube_wires(current_commands, cx, cy, cz, cw, ch, cd, color, c_pos, c_tgt, c_up)
            when 29 # DrawGrid
              cam_cfg = active_camera || { {0.0_f32, 4.5_f32, 8.5_f32}, {0.0_f32, 0.0_f32, 0.0_f32}, {0.0_f32, 1.0_f32, 0.0_f32} }
              c_pos, c_tgt, c_up = cam_cfg
              slices = regs[base_r].to_i
              slices = 16 if slices <= 0
              spacing = self.class.decode_coord(regs[base_r + 1])
              spacing = 1.0_f32 if spacing <= 0.0_f32

              self.class.emit_3d_grid(current_commands, slices, spacing, 0xFF4A4A5A_u32, c_pos, c_tgt, c_up)
            when 100 # DrawQuad (decomposes to 2 triangles)
              x1 = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
              y1 = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
              x2 = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
              y2 = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
              x3 = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_i32!
              y3 = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_i32!
              x4 = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_i32!
              y4 = (regs[base_r + 7] & 0xFFFFFFFF_i64).to_i32!
              val = (regs[base_r + 8] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Quad, x1, y1, x2, y2, x3, y3, x4, y4, color: color)
            when 30 # LoadTexture
              t_val = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
              tex_path = (t_val < constants.size) ? (constants[t_val]?.try(&.str_val) || "") : ""
              tid = (loaded_textures.size + 1).to_i64
              loaded_textures[tid] = tex_path
              regs[dst_r] = tid
            when 31 # DrawTexture
              tex_id = regs[base_r]
              tex_name = loaded_textures[tex_id]? || ""
              dest_x = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
              dest_y = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
              found_file = if !tex_name.empty? && File.exists?(tex_name)
                             tex_name
                           elsif !tex_name.empty? && (entry = Dir.glob("**/#{File.basename(tex_name)}").first?)
                             entry
                           else
                             nil
                           end
              if found_file
                self.class.emit_cbt_texture_spans(current_commands, found_file, dest_x, dest_y, dest_w: 128, dest_h: 128, grid_res: 64)
              else
                current_commands << DrawCommand.new(DrawCommand::Type::Rect, dest_x, dest_y, dest_x + 128, dest_y + 128, color: 0xFF2A1F18_u32)
              end
              regs[dst_r] = 0_i64
            when 32 # DrawTextureRec(id, sx, sy, sw, sh, dx, dy[, tint])
              tex_id = regs[base_r]
              tex_name = loaded_textures[tex_id]? || ""
              dest_w = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
              dest_h = (regs[base_r + 4] & 0xFFFFFFFF_i64).to_i32!
              dest_x = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_i32!
              dest_y = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_i32!
              dest_w = 128 if dest_w <= 0
              dest_h = 128 if dest_h <= 0
              found_file = if !tex_name.empty? && File.exists?(tex_name)
                             tex_name
                           elsif !tex_name.empty? && (entry = Dir.glob("**/#{File.basename(tex_name)}").first?)
                             entry
                           else
                             nil
                           end
              if found_file
                self.class.emit_cbt_texture_spans(current_commands, found_file, dest_x, dest_y, dest_w: dest_w, dest_h: dest_h, grid_res: {dest_w, 64}.min)
              else
                current_commands << DrawCommand.new(DrawCommand::Type::Rect, dest_x, dest_y, dest_x + dest_w, dest_y + dest_h, color: 0xFF2A1F18_u32)
              end
              regs[dst_r] = 0_i64
            when 230 # DrawRectangleRotated(x, y, w, h, angle, ox, oy, color)
              x = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
              y = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
              w = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
              h = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
              val = (regs[base_r + 7] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x + w, y + h, color: color)
            when 231 # DrawRoundedRectangle(x, y, w, h, radius, color)
              x = (regs[base_r] & 0xFFFFFFFF_i64).to_i32!
              y = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
              w = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
              h = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
              val = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Rect, x, y, x + w, y + h, color: color)
            when 232 # DrawTextRotated(text, x, y, size, angle, ox, oy, color)
              t_idx = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
              text = (t_idx < constants.size) ? (constants[t_idx]?.try(&.str_val) || "") : ""
              x = (regs[base_r + 1] & 0xFFFFFFFF_i64).to_i32!
              y = (regs[base_r + 2] & 0xFFFFFFFF_i64).to_i32!
              size = (regs[base_r + 3] & 0xFFFFFFFF_i64).to_i32!
              val = (regs[base_r + 7] & 0xFFFFFFFF_i64).to_u32
              color = (val < constants.size) ? (constants[val]?.try(&.u32_val) || val) : val
              current_commands << DrawCommand.new(DrawCommand::Type::Text, x, y, size, 0, color: color, text: text)
            when 237 # DrawTexturePro(id, sx, sy, sw, sh, dx, dy, dw, dh, rot, ox, oy, tint, flip_flags)
              tex_id = regs[base_r]
              tex_name = loaded_textures[tex_id]? || ""
              dest_x = (regs[base_r + 5] & 0xFFFFFFFF_i64).to_i32!
              dest_y = (regs[base_r + 6] & 0xFFFFFFFF_i64).to_i32!
              dest_w = (regs[base_r + 7] & 0xFFFFFFFF_i64).to_i32!
              dest_h = (regs[base_r + 8] & 0xFFFFFFFF_i64).to_i32!
              dest_w = 128 if dest_w <= 0
              dest_h = 128 if dest_h <= 0
              found_file = if !tex_name.empty? && File.exists?(tex_name)
                             tex_name
                           elsif !tex_name.empty? && (entry = Dir.glob("**/#{File.basename(tex_name)}").first?)
                             entry
                           else
                             nil
                           end
              if found_file
                self.class.emit_cbt_texture_spans(current_commands, found_file, dest_x, dest_y, dest_w: dest_w, dest_h: dest_h, grid_res: {dest_w, 64}.min)
              else
                current_commands << DrawCommand.new(DrawCommand::Type::Rect, dest_x, dest_y, dest_x + dest_w, dest_y + dest_h, color: 0xFF2A1F18_u32)
              end
              regs[dst_r] = 0_i64
            when 35 # LoadSound
              boot_messages << "[CITRINE SPU2] Loaded ADPCM Sound Sample"
              regs[dst_r] = 1_i64
            when 36 # PlaySound
              boot_messages << "[CITRINE SPU2] Play Sound Voice 0 (Pitch: 44.1kHz, Vol: 0x3FFF)"
              has_audio = true
              regs[dst_r] = 1_i64
            when 37 # StopSound
              boot_messages << "[CITRINE SPU2] Stop Sound Voice 0"
              regs[dst_r] = 0_i64
            when 90 # LoadVideo
              boot_messages << "[CITRINE IPU] Initialized MPEG-2 / PSS Video Stream"
              regs[dst_r] = 1_i64
            when 91 # PlayVideo
              boot_messages << "[CITRINE IPU] Streaming Video via DMA Channel 3"
              regs[dst_r] = 1_i64
            when 92 # DrawVideoFrame
              regs[dst_r] = 1_i64
            when 93 # VideoFinished
              regs[dst_r] = 0_i64
            when 94 # PauseVideo
              boot_messages << "[CITRINE IPU] Video Playback Paused"
              regs[dst_r] = 0_i64
            when 95 # StopVideo
              boot_messages << "[CITRINE IPU] Video Playback Stopped"
              regs[dst_r] = 0_i64
            when 65 # Sleep(seconds)
              sec = regs[base_r].to_i
              sec = 1 if sec <= 0
              delay_frames = (sec * 60).to_u32
              phases << Phase.new(current_commands.dup, delay_frames, current_loop_message)
              current_loop_message = nil
              if phases.size >= 10
                first_frame_done = true
              end
            when 70, 71 # Log / puts / print / debug_puts / debug_log
              t_idx = regs[base_r].to_i
              text = constants[t_idx]?.try(&.str_val) || ""
              unless text.empty?
                if in_main_loop
                  if cur = current_loop_message
                    current_loop_message = "#{cur}\n#{text}"
                  else
                    current_loop_message = text
                  end
                else
                  boot_messages << text
                end
              end
              unless has_drawing
                if current_commands.empty?
                  current_commands << DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32)
                end
                text_count = current_commands.count { |c| c.type == DrawCommand::Type::Text }
                if text_count >= 12
                  if first_idx = current_commands.index { |c| c.type == DrawCommand::Type::Text }
                    current_commands.delete_at(first_idx)
                  end
                  new_cmds = [] of DrawCommand
                  text_idx = 0
                  current_commands.each do |c|
                    if c.type == DrawCommand::Type::Text
                      new_cmds << DrawCommand.new(c.type, c.x1, 60 + (text_idx * 28), c.x2, c.y2, c.x3, c.y3, radius: c.radius, color: c.color, text: c.text)
                      text_idx += 1
                    else
                      new_cmds << c
                    end
                  end
                  current_commands = new_cmds
                end
                y_pos = 60 + (current_commands.count { |c| c.type == DrawCommand::Type::Text } * 28)
                current_commands << DrawCommand.new(DrawCommand::Type::Text, 60, y_pos, 20, 0, color: 0xFFFFFFFF_u32, text: text)
              end
            when 80 # ChannelNew
              cid = next_chan_id
              next_chan_id += 1
              cap = regs[base_r].to_i
              cap = 16 if cap <= 0
              channels[cid] = ChannelInstance.new(cap)
              regs[dst_r] = cid
            when 81 # ChannelSend
              cid = regs[base_r]
              val = regs[base_r + 1]
              if ch = channels[cid]?
                ch.items << val if ch.items.size < ch.capacity
              end
              regs[dst_r] = 1_i64
            when 82 # ChannelReceive
              cid = regs[base_r]
              if ch = channels[cid]?
                regs[dst_r] = ch.items.empty? ? 0_i64 : ch.items.shift
              else
                regs[dst_r] = 0_i64
              end
            when 83 # ChannelTryReceive
              cid = regs[base_r]
              if ch = channels[cid]?
                regs[dst_r] = ch.items.empty? ? 0_i64 : ch.items.shift
              else
                regs[dst_r] = 0_i64
              end
            when 84 # ChannelCount
              cid = regs[base_r]
              regs[dst_r] = channels[cid]?.try(&.items.size.to_i64) || 0_i64
            when 85 # ChannelCapacity
              cid = regs[base_r]
              regs[dst_r] = channels[cid]?.try(&.capacity.to_i64) || 16_i64
            when 99 # Panic
              t_idx = regs[base_r].to_i
              text = constants[t_idx]?.try(&.str_val) || "Citrine PS2 VM Panic"
              boot_messages << "[CITRINE PANIC] #{text}"
            when 120 # ArrayNew
              arr_id = next_arr_id
              next_arr_id += 1
              arrays[arr_id] = [] of Int64
              array_types[arr_id] = [] of UInt8
              regs[dst_r] = arr_id
              reg_types[dst_r] = 5_u8 # TYPE_ARRAY
            when 121 # ArrayGet
              arr_id = regs[base_r]
              idx = regs[base_r + 1].to_i
              if arr = arrays[arr_id]?
                regs[dst_r] = arr[idx]? || 0_i64
                reg_types[dst_r] = array_types[arr_id]?.try(&.[idx]?) || 2_u8
              elsif arr_id >= 0x00100000_i64
                target_addr = arr_id + (idx.to_i64 * 4)
                if target_addr == 0x70000010_i64 || target_addr == 0x70000018_i64
                  regs[dst_r] = simulated_button_press ? 0x4000_i64 : 0_i64
                  reg_types[dst_r] = 2_u8
                else
                  regs[dst_r] = memory[target_addr]? || 0_i64
                  reg_types[dst_r] = 2_u8
                end
              else
                regs[dst_r] = 0_i64
                reg_types[dst_r] = 0_u8
              end
            when 122 # ArraySet
              arr_id = regs[base_r]
              idx = regs[base_r + 1].to_i
              val = regs[base_r + 2]
              val_t = reg_types[base_r + 2]
              if arr = arrays[arr_id]?
                while arr.size <= idx
                  arr << 0_i64
                end
                arr[idx] = val
                if arr_t = array_types[arr_id]?
                  while arr_t.size <= idx
                    arr_t << 2_u8
                  end
                  arr_t[idx] = val_t
                end
              elsif arr_id >= 0x00100000_i64
                target_addr = arr_id + (idx.to_i64 * 4)
                memory[target_addr] = val
              end
              regs[dst_r] = val
              reg_types[dst_r] = val_t
            when 123 # ArrayPush
              arr_id = regs[base_r]
              val = regs[base_r + 1]
              val_t = reg_types[base_r + 1]
              if arr = arrays[arr_id]?
                arr << val
              end
              if arr_t = array_types[arr_id]?
                arr_t << val_t
              end
              regs[dst_r] = arr_id
              reg_types[dst_r] = 5_u8 # TYPE_ARRAY
            when 124 # ArrayPop
              arr_id = regs[base_r]
              regs[dst_r] = arrays[arr_id]?.try(&.pop?) || 0_i64
              reg_types[dst_r] = array_types[arr_id]?.try(&.pop?) || 2_u8
            when 125 # ArraySize / StringSize
              id = regs[base_r]
              if arr = arrays[id]?
                regs[dst_r] = arr.size.to_i64
              elsif id >= 0 && id < constants.size && constants[id.to_i]?.try(&.type) == 6_u8
                regs[dst_r] = constants[id.to_i].str_val.size.to_i64
              elsif id >= 0 && id < strings.size && (s = strings[id.to_i]?)
                regs[dst_r] = s.size.to_i64
              else
                regs[dst_r] = 0_i64
              end
              reg_types[dst_r] = 2_u8 # TYPE_INT32
            when 126 # ArrayClear
              arr_id = regs[base_r]
              arrays[arr_id]?.try(&.clear)
              array_types[arr_id]?.try(&.clear)
              regs[dst_r] = 0_i64
              reg_types[dst_r] = 0_u8 # TYPE_NIL
            when 130 # StaticArrayNew
              sz = regs[base_r].to_i
              def_val = regs[base_r + 1]
              arr_id = next_arr_id
              next_arr_id += 1
              arrays[arr_id] = Array(Int64).new(sz, def_val)
              regs[dst_r] = arr_id
            when 131 # StaticArrayGet
              arr_id = regs[base_r]
              idx = regs[base_r + 1].to_i
              regs[dst_r] = arrays[arr_id]?.try(&.[idx]?) || 0_i64
            when 132 # StaticArraySet
              arr_id = regs[base_r]
              idx = regs[base_r + 1].to_i
              val = regs[base_r + 2]
              if arr = arrays[arr_id]?
                while arr.size <= idx
                  arr << 0_i64
                end
                arr[idx] = val
              end
              regs[dst_r] = val
            when 133 # StaticArraySize
              arr_id = regs[base_r]
              regs[dst_r] = (arrays[arr_id]?.try(&.size) || 0).to_i64
            when 140 # MemoryIONew
              io_id = next_io_id
              next_io_id += 1
              io_streams[io_id] = IO::Memory.new
              regs[dst_r] = io_id
            when 141 # MemoryIOWriteByte
              io_id = regs[base_r]
              byte = (regs[base_r + 1] & 0xFF).to_u8
              io_streams[io_id]?.try(&.write_byte(byte))
              regs[dst_r] = 1_i64
            when 142 # MemoryIOWrite
              io_id = regs[base_r]
              t_idx = regs[base_r + 1].to_i
              str = constants[t_idx]?.try(&.str_val) || ""
              io_streams[io_id]?.try(&.print(str))
              regs[dst_r] = str.bytesize.to_i64
            when 143 # MemoryIOPuts
              io_id = regs[base_r]
              t_idx = regs[base_r + 1].to_i
              str = constants[t_idx]?.try(&.str_val) || ""
              io_streams[io_id]?.try(&.puts(str))
              boot_messages << str unless str.empty?
              regs[dst_r] = (str.bytesize + 1).to_i64
            when 144 # MemoryIOToS
              io_id = regs[base_r]
              str = io_streams[io_id]?.try(&.to_s) || ""
              s_idx = strings.index(str) || (strings << str; strings.size - 1)
              constants << CVal.new(6_u8, 0_u32, str)
              regs[dst_r] = (constants.size - 1).to_i64
            when 145 # MemoryIORewind
              io_id = regs[base_r]
              io_streams[io_id]?.try(&.rewind)
              regs[dst_r] = 0_i64
            when 146 # MemoryIOPos
              io_id = regs[base_r]
              regs[dst_r] = (io_streams[io_id]?.try(&.pos) || 0).to_i64
            when 147 # MemoryIOSize
              io_id = regs[base_r]
              regs[dst_r] = (io_streams[io_id]?.try(&.size) || 0).to_i64
            when 148 # MemoryIOClear
              io_id = regs[base_r]
              io_streams[io_id]?.try(&.clear)
              regs[dst_r] = 0_i64
            when 150 # ObjectNew
              cid = (regs[base_r] & 0xFFFFFFFF_i64).to_u32
              field_count = regs[base_r + 1].to_i
              is_struct = (regs[base_r + 2]? || 0_i64) == 1_i64
              size_bytes = (8 + (field_count * 4) + 7) & ~7 # 8-byte aligned

              if is_struct
                obj_addr = scratch_pool_ptr
                scratch_pool_ptr += size_bytes
              else
                found_idx = free_list.index { |(_, sz)| sz >= size_bytes }
                if found_idx
                  obj_addr, _ = free_list.delete_at(found_idx)
                else
                  obj_addr = next_heap_addr
                  next_heap_addr += size_bytes
                end
              end

              memory[obj_addr] = cid.to_i64
              memory[obj_addr + 4] = field_count.to_i64
              field_count.times do |i|
                memory[obj_addr + 8 + (i * 4)] = 0_i64
              end

              allocations[obj_addr] = AllocationRecord.new(
                obj_addr, size_bytes, active_context_name,
                freed: false, is_object: true, is_struct: is_struct, field_count: field_count
              )
              object_classes[obj_addr] = cid
              objects[obj_addr] = Array(Int64).new(field_count, 0_i64)
              object_types[obj_addr] = Array(UInt8).new(field_count, 2_u8)
              regs[dst_r] = obj_addr
              reg_types[dst_r] = 6_u8 # TYPE_OBJECT
            when 151 # ObjectGetField
              obj_id = regs[base_r]
              f_idx = regs[base_r + 1].to_i
              if alloc = allocations[obj_id]?
                if alloc.freed
                  boot_messages << "[CITRINE MEMORY ERROR] Use-after-free: read from freed object at 0x#{obj_id.to_s(16)}"
                  regs[dst_r] = 0_i64
                  reg_types[dst_r] = 0_u8
                elsif f_idx < 0 || f_idx >= alloc.field_count
                  boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} for field_count #{alloc.field_count}"
                  regs[dst_r] = 0_i64
                  reg_types[dst_r] = 0_u8
                else
                  regs[dst_r] = memory[obj_id + 8 + (f_idx * 4)]? || 0_i64
                  reg_types[dst_r] = object_types[obj_id]?.try(&.[f_idx]?) || 2_u8
                end
              elsif obj = objects[obj_id]?
                if f_idx < 0 || f_idx >= obj.size
                  boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} for size #{obj.size}"
                  regs[dst_r] = 0_i64
                  reg_types[dst_r] = 0_u8
                else
                  regs[dst_r] = obj[f_idx]? || 0_i64
                  reg_types[dst_r] = object_types[obj_id]?.try(&.[f_idx]?) || 2_u8
                end
              else
                regs[dst_r] = memory[obj_id + 8 + (f_idx * 4)]? || 0_i64
                reg_types[dst_r] = object_types[obj_id]?.try(&.[f_idx]?) || 2_u8
              end
            when 152 # ObjectSetField
              obj_id = regs[base_r]
              f_idx = regs[base_r + 1].to_i
              val = regs[base_r + 2]
              val_t = reg_types[base_r + 2]
              if alloc = allocations[obj_id]?
                if alloc.freed
                  boot_messages << "[CITRINE MEMORY ERROR] Use-after-free: write to freed object at 0x#{obj_id.to_s(16)}"
                elsif f_idx < 0 || f_idx >= alloc.field_count
                  boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} for field_count #{alloc.field_count}"
                else
                  memory[obj_id + 8 + (f_idx * 4)] = val
                  if obj = objects[obj_id]?
                    while obj.size <= f_idx; obj << 0_i64; end
                    obj[f_idx] = val
                  end
                  if obj_t = object_types[obj_id]?
                    while obj_t.size <= f_idx; obj_t << 2_u8; end
                    obj_t[f_idx] = val_t
                  end
                end
              elsif obj = objects[obj_id]?
                if f_idx < 0
                  boot_messages << "[CITRINE PANIC] Object field index out of bounds: slot #{f_idx} < 0"
                else
                  while obj.size <= f_idx; obj << 0_i64; end
                  obj[f_idx] = val
                  if obj_t = object_types[obj_id]?
                    while obj_t.size <= f_idx; obj_t << 2_u8; end
                    obj_t[f_idx] = val_t
                  end
                  memory[obj_id + 8 + (f_idx * 4)] = val
                end
              else
                memory[obj_id + 8 + (f_idx * 4)] = val
              end
              regs[dst_r] = val
              reg_types[dst_r] = val_t
            when 153 # StructCopy
              src_addr = regs[base_r]
              if alloc = allocations[src_addr]?
                size_bytes = alloc.size_bytes
                copy_addr = scratch_pool_ptr
                scratch_pool_ptr += size_bytes
                (size_bytes // 4).times do |i|
                  memory[copy_addr + (i * 4)] = memory[src_addr + (i * 4)]? || 0_i64
                end
                allocations[copy_addr] = AllocationRecord.new(
                  copy_addr, size_bytes, active_context_name,
                  freed: false, is_object: true, is_struct: true, field_count: alloc.field_count
                )
                if cid = object_classes[src_addr]?
                  object_classes[copy_addr] = cid
                end
                if obj = objects[src_addr]?
                  objects[copy_addr] = obj.dup
                end
                if obj_t = object_types[src_addr]?
                  object_types[copy_addr] = obj_t.dup
                end
                regs[dst_r] = copy_addr
                reg_types[dst_r] = 6_u8
              else
                regs[dst_r] = src_addr
                reg_types[dst_r] = reg_types[base_r]
              end
            when 160 # PointerMalloc
              cnt = regs[base_r].to_i
              cnt = 1 if cnt <= 0
              size_bytes = ((cnt * 4) + 7) & ~7 # 8-byte aligned

              found_idx = free_list.index { |(_, sz)| sz >= size_bytes }
              if found_idx
                ptr_addr, _ = free_list.delete_at(found_idx)
              else
                ptr_addr = next_heap_addr
                next_heap_addr += size_bytes
              end

              cnt.times { |i| memory[ptr_addr + (i.to_i64 * 4)] = 0_i64 }
              allocations[ptr_addr] = AllocationRecord.new(
                ptr_addr, size_bytes, active_context_name,
                freed: false, is_object: false, is_struct: false
              )
              regs[dst_r] = ptr_addr
            when 161 # PointerGet
              addr = regs[base_r]
              idx = regs[base_r + 1]
              if addr < 0x00100000_i64 && idx == 0_i64
                regs[dst_r] = addr
              else
                target_addr = addr + (idx * 4)
                if alloc = allocations[addr]?
                  if alloc.freed
                    boot_messages << "[CITRINE MEMORY ERROR] Use-after-free detected at address 0x#{target_addr.to_s(16)}"
                  end
                end
                if target_addr == 0x70000010_i64 || target_addr == 0x70000018_i64
                  regs[dst_r] = simulated_button_press ? 0x4000_i64 : 0_i64
                elsif target_addr == 0x10000800_i64
                  rand_state = (rand_state &* 6364136223846793005_u64) &+ 1442695040888963407_u64
                  regs[dst_r] = (((rand_state >> 32) ^ (steps * 13)) & 0xFFFF_u64).to_i64
                elsif target_addr == 0x12001000_i64
                  rand_state = (rand_state &* 6364136223846793005_u64) &+ 1442695040888963407_u64
                  regs[dst_r] = (((rand_state >> 16) ^ (steps * 7)) & 0xFFFF_u64).to_i64
              elsif arr = arrays[addr]?
                if idx < 0 || idx >= arr.size
                  boot_messages << "[CITRINE PANIC] Array index out of bounds: #{idx}"
                  regs[dst_r] = 0_i64
                else
                  regs[dst_r] = arr[idx.to_i]? || 0_i64
                end
              else
                regs[dst_r] = memory[target_addr]? || 0_i64
              end
            end
            when 162 # PointerSet
              addr = regs[base_r]
              idx = regs[base_r + 1]
              val = regs[base_r + 2]
              target_addr = addr + (idx * 4)
              if alloc = allocations[addr]?
                if alloc.freed
                  boot_messages << "[CITRINE MEMORY ERROR] Use-after-free detected at address 0x#{target_addr.to_s(16)}"
                end
              end
              if target_addr >= 0x00100000_i64 && target_addr < 0x00200000_i64
                boot_messages << "[CITRINE PANIC] Memory protection violation: attempt to write to read-only code space at 0x#{target_addr.to_s(16)}"
              elsif arr = arrays[addr]?
                if idx < 0
                  boot_messages << "[CITRINE PANIC] Array index out of bounds: #{idx} < 0"
                else
                  while arr.size <= idx.to_i
                    arr << 0_i64
                  end
                  arr[idx.to_i] = val
                end
              else
                memory[target_addr] = val
              end
              regs[dst_r] = val
            when 163 # PointerOffset
              addr = regs[base_r]
              off = regs[base_r + 1]
              regs[dst_r] = addr + (off * 4)
            when 164 # PointerAddress
              regs[dst_r] = regs[base_r]
            when 165 # PointerNew
              regs[dst_r] = regs[base_r]
            when 166 # BoxNew
              val = regs[base_r]
              box_addr = next_heap_addr
              next_heap_addr += 4_i64
              memory[box_addr] = val
              regs[dst_r] = box_addr
            when 167 # BoxUnbox
              box_addr = regs[base_r]
              regs[dst_r] = memory[box_addr]? || 0_i64
            when 168 # PointerFree
              addr = regs[base_r]
              if alloc = allocations[addr]?
                if alloc.freed
                  boot_messages << "[CITRINE MEMORY ERROR] Double free detected on pointer 0x#{addr.to_s(16)}"
                else
                  alloc.freed = true
                  (alloc.size_bytes // 4).times do |i|
                    memory.delete(addr + (i * 4))
                  end
                  objects.delete(addr)
                  arrays.delete(addr)
                  free_list << {addr, alloc.size_bytes}
                end
              elsif memory.has_key?(addr) || objects.has_key?(addr) || arrays.has_key?(addr)
                memory.delete(addr)
                objects.delete(addr)
                arrays.delete(addr)
              else
                boot_messages << "[CITRINE MEMORY ERROR] Free called on unallocated pointer 0x#{addr.to_s(16)}"
              end
              regs[dst_r] = 0_i64
            when 170 # TypeIsA
              val = regs[base_r]
              raw_tid = regs[base_r + 1]
              target_id = if raw_tid < 0 && raw_tid >= -32768
                            (raw_tid & 0xFFFF_i64).to_u32
                          else
                            (raw_tid & 0xFFFFFFFF_i64).to_u32
                          end
              is_match = false
              if target_id == TypeKind::Nil.value
                is_match = val == 0_i64
              elsif target_id == TypeKind::Bool.value
                is_match = val == 0_i64 || val == 1_i64
              elsif target_id == TypeKind::Int32.value
                is_match = !object_classes.has_key?(val) && !arrays.has_key?(val) && !(val >= 0 && val < constants.size && constants[val.to_i]?.try(&.type) == 6_u8) && (val >= -2147483648_i64 && val <= 2147483647_i64)
              elsif target_id == TypeKind::Float32.value
                is_match = true
              elsif target_id == TypeKind::String.value
                is_match = val < constants.size && constants[val.to_i]?.try(&.type) == 6_u8
              elsif target_id == TypeKind::Array.value
                is_match = arrays.has_key?(val)
              elsif target_id == TypeKind::Pointer.value
                is_match = val >= 0x00100000_i64
              elsif target_id == TypeKind::Box.value
                is_match = val >= 0x00100000_i64
              elsif obj_cid = object_classes[val]?
                is_match = obj_cid == target_id
              end
              regs[dst_r] = is_match ? 1_i64 : 0_i64
              reg_types[dst_r] = 1_u8 # TYPE_BOOL
            when 171 # TypeAsCast
              val = regs[base_r]
              regs[dst_r] = val
              reg_types[dst_r] = reg_types[base_r]
            when 180 # ContextSet
              s_idx = regs[base_r].to_i
              ctx_str = constants[s_idx]?.try(&.str_val) || ""
              active_context_name = ctx_str
              regs[dst_r] = s_idx.to_i64
            when 181 # ContextClear
              s_idx = regs[base_r].to_i
              ctx_str = constants[s_idx]?.try(&.str_val) || ""
              reclaimed_bytes = 0_i64
              allocations.reject! do |addr, a|
                if a.context_name == ctx_str
                  a.freed = true
                  (a.size_bytes // 4).times { |i| memory.delete(addr + (i * 4)) }
                  objects.delete(addr)
                  arrays.delete(addr)
                  free_list << {addr, a.size_bytes}
                  reclaimed_bytes += a.size_bytes
                  true
                else
                  false
                end
              end
              active_context_name = ""
              regs[dst_r] = reclaimed_bytes
            when 182 # MemoryStats
              active_bytes = allocations.values.reject(&.freed).sum(&.size_bytes)
              regs[dst_r] = active_bytes.to_i64
            when 185 # GCCycle / GC.collect
              marked_objects = Set(Int64).new
              marked_arrays = Set(Int64).new
              (0...regs.size).each do |r|
                val = regs[r]
                marked_objects << val if objects.has_key?(val)
                marked_arrays << val if arrays.has_key?(val)
              end
              memory.each do |addr, val|
                if addr >= 0x00300000_i64 && addr < 0x00310000_i64
                  marked_objects << val if objects.has_key?(val)
                  marked_arrays << val if arrays.has_key?(val)
                end
              end
              changed = true
              while changed
                changed = false
                marked_objects.to_a.each do |oid|
                  if fields = objects[oid]?
                    fields.each do |fval|
                      if objects.has_key?(fval) && !marked_objects.includes?(fval)
                        marked_objects << fval
                        changed = true
                      elsif arrays.has_key?(fval) && !marked_arrays.includes?(fval)
                        marked_arrays << fval
                        changed = true
                      end
                    end
                  end
                end
                marked_arrays.to_a.each do |aid|
                  if elems = arrays[aid]?
                    elems.each do |eval|
                      if objects.has_key?(eval) && !marked_objects.includes?(eval)
                        marked_objects << eval
                        changed = true
                      elsif arrays.has_key?(eval) && !marked_arrays.includes?(eval)
                        marked_arrays << eval
                        changed = true
                      end
                    end
                  end
                end
              end
              reclaimed = 0_i64
              objects.reject! do |oid, _|
                if marked_objects.includes?(oid)
                  false
                else
                  reclaimed += 1
                  true
                end
              end
              arrays.reject! do |aid, _|
                if marked_arrays.includes?(aid)
                  false
                else
                  reclaimed += 1
                  true
                end
              end
              regs[dst_r] = reclaimed
            when 186 # StringStrip
              s_val = regs[base_r]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              stripped = raw.strip
              strings << stripped unless strings.includes?(stripped)
              c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == stripped } ||
                      (constants << CVal.new(6_u8, 0_u32, stripped); constants.size - 1)
              regs[dst_r] = c_idx.to_i64
              reg_types[dst_r] = 7_u8 # TYPE_STRING
            when 187 # StringDowncase
              s_val = regs[base_r]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              down = raw.downcase
              strings << down unless strings.includes?(down)
              c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == down } ||
                      (constants << CVal.new(6_u8, 0_u32, down); constants.size - 1)
              regs[dst_r] = c_idx.to_i64
              reg_types[dst_r] = 7_u8 # TYPE_STRING
            when 188 # StringUpcase
              s_val = regs[base_r]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              up = raw.upcase
              strings << up unless strings.includes?(up)
              c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == up } ||
                      (constants << CVal.new(6_u8, 0_u32, up); constants.size - 1)
              regs[dst_r] = c_idx.to_i64
              reg_types[dst_r] = 7_u8 # TYPE_STRING
            when 189 # StringIncludes
              s_val = regs[base_r]
              sub_val = regs[base_r + 1]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              sub = if sub_val < constants.size && constants[sub_val.to_i]?.try(&.type) == 6_u8
                      constants[sub_val.to_i].str_val
                    else
                      strings[sub_val.to_i]? || ""
                    end
              regs[dst_r] = raw.includes?(sub) ? 1_i64 : 0_i64
              reg_types[dst_r] = 1_u8 # TYPE_BOOL
            when 190 # RegexNew
              s_val = regs[base_r]
              pat = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              rid = next_regex_id
              next_regex_id += 1
              compiled_regexes[rid] = SimpleRegex.new(pat)
              regs[dst_r] = rid
            when 191 # RegexMatch
              arg0 = regs[base_r]
              arg1 = regs[base_r + 1]
              target_str = ""
              re : SimpleRegex? = nil

              if compiled_regexes.has_key?(arg1)
                re = compiled_regexes[arg1]
                target_str = if arg0 < constants.size && constants[arg0.to_i]?.try(&.type) == 6_u8
                               constants[arg0.to_i].str_val
                             else
                               strings[arg0.to_i]? || ""
                             end
              elsif compiled_regexes.has_key?(arg0)
                re = compiled_regexes[arg0]
                target_str = if arg1 < constants.size && constants[arg1.to_i]?.try(&.type) == 6_u8
                               constants[arg1.to_i].str_val
                             else
                               strings[arg1.to_i]? || ""
                             end
              else
                pat = if arg1 < constants.size && constants[arg1.to_i]?.try(&.type) == 6_u8
                        constants[arg1.to_i].str_val
                      else
                        strings[arg1.to_i]? || ""
                      end
                re = SimpleRegex.new(pat)
                target_str = if arg0 < constants.size && constants[arg0.to_i]?.try(&.type) == 6_u8
                               constants[arg0.to_i].str_val
                             else
                               strings[arg0.to_i]? || ""
                             end
              end

              m_pos = re.try(&.match(target_str))
              regs[dst_r] = m_pos ? m_pos.to_i64 : -1_i64
            when 192 # StringStartsWith
              s_val = regs[base_r]
              sub_val = regs[base_r + 1]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              sub = if sub_val < constants.size && constants[sub_val.to_i]?.try(&.type) == 6_u8
                      constants[sub_val.to_i].str_val
                    else
                      strings[sub_val.to_i]? || ""
                    end
              regs[dst_r] = raw.starts_with?(sub) ? 1_i64 : 0_i64
              reg_types[dst_r] = 1_u8 # TYPE_BOOL
            when 193 # StringEndsWith
              s_val = regs[base_r]
              sub_val = regs[base_r + 1]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              sub = if sub_val < constants.size && constants[sub_val.to_i]?.try(&.type) == 6_u8
                      constants[sub_val.to_i].str_val
                    else
                      strings[sub_val.to_i]? || ""
                    end
              regs[dst_r] = raw.ends_with?(sub) ? 1_i64 : 0_i64
              reg_types[dst_r] = 1_u8 # TYPE_BOOL
            when 194 # StringSplit
              s_val = regs[base_r]
              delim_val = regs[base_r + 1]
              raw = if s_val < constants.size && constants[s_val.to_i]?.try(&.type) == 6_u8
                      constants[s_val.to_i].str_val
                    else
                      strings[s_val.to_i]? || ""
                    end
              delim = if delim_val < constants.size && constants[delim_val.to_i]?.try(&.type) == 6_u8
                        constants[delim_val.to_i].str_val
                      else
                        strings[delim_val.to_i]? || " "
                      end
              parts = raw.split(delim)
              arr_id = next_arr_id
              next_arr_id += 1
              arr_elems = [] of Int64
              parts.each do |part|
                strings << part unless strings.includes?(part)
                c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == part } ||
                        (constants << CVal.new(6_u8, 0_u32, part); constants.size - 1)
                arr_elems << c_idx.to_i64
              end
              arrays[arr_id] = arr_elems
              regs[dst_r] = arr_id
            when 195 # StringConcat
              s1_val = regs[base_r]
              s2_val = regs[base_r + 1]
              raw1 = if s1_val >= 0 && s1_val < constants.size && constants[s1_val.to_i]?.try(&.type) == 6_u8
                       constants[s1_val.to_i].str_val
                     elsif strings[s1_val.to_i]?
                       strings[s1_val.to_i]
                     else
                       s1_val.to_s
                     end
              raw2 = if s2_val >= 0 && s2_val < constants.size && constants[s2_val.to_i]?.try(&.type) == 6_u8
                       constants[s2_val.to_i].str_val
                     elsif strings[s2_val.to_i]?
                       strings[s2_val.to_i]
                     else
                       s2_val.to_s
                     end
              joined = raw1 + raw2
              strings << joined unless strings.includes?(joined)
              c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == joined } ||
                      (constants << CVal.new(6_u8, 0_u32, joined); constants.size - 1)
              regs[dst_r] = c_idx.to_i64
              reg_types[dst_r] = 7_u8 # TYPE_STRING
            when 196 # ToString
              val = regs[base_r]
              hint = (base_r + 1 < regs.size) ? regs[base_r + 1] : 0_i64
              val_str = case hint
                        when 2 # Bool
                          val != 0_i64 ? "true" : "false"
                        when 3 # String
                          if val >= 0 && val < constants.size && constants[val.to_i]?.try(&.type) == 6_u8
                            constants[val.to_i].str_val
                          elsif strings[val.to_i]?
                            strings[val.to_i]
                          else
                            val.to_s
                          end
                        else # 0 (Int), 1 (Float), default
                          val.to_s
                        end
              strings << val_str unless strings.includes?(val_str)
              c_idx = constants.index { |c| c.type == 6_u8 && c.str_val == val_str } ||
                      (constants << CVal.new(6_u8, 0_u32, val_str); constants.size - 1)
              regs[dst_r] = c_idx.to_i64
              reg_types[dst_r] = 7_u8 # TYPE_STRING
            when 210 # VU0BatchTransform
              points_ptr = regs[base_r]
              regs[dst_r] = points_ptr
            when 211 # VU0BatchDot
              a_arr = arrays[regs[base_r]]? || [1_i64, 1_i64]
              arr_id = next_arr_id
              next_arr_id += 1
              arrays[arr_id] = Array(Int64).new(a_arr.size, 1_i64)
              regs[dst_r] = arr_id
            when 220 # AudioPlayCDDA
              track_num = regs[base_r]
              boot_messages << "[CITRINE AUDIO] Playing CD-DA Audio Track #{track_num} via SPU2"
              has_audio = true
              regs[dst_r] = 1_i64
            when 221 # AudioStopCDDA
              boot_messages << "[CITRINE AUDIO] Stopped CD-DA Audio Track"
              regs[dst_r] = 0_i64
            when 222 # AudioGetCDDAStatus
              regs[dst_r] = 1_i64
            when 223 # AudioSetVolume
              vol = regs[base_r]
              boot_messages << "[CITRINE AUDIO] CD-DA Volume set to #{vol}"
              regs[dst_r] = vol
            when 224 # AudioSeekStream
              time_sec = regs[base_r]
              boot_messages << "[CITRINE AUDIO] Stream seeking to #{time_sec}s"
              regs[dst_r] = 1_i64
            end
          end
        end

        if phases.empty?
          if current_commands.empty?
            current_commands = [
              DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32),
              DrawCommand.new(DrawCommand::Type::Text, 60, 60, 20, 0, color: 0xFFFFFFFF_u32, text: "Hello, world!")
            ]
          end
          phases << Phase.new(current_commands, 0_u32)
        elsif current_commands.size > phases.last.commands.size
          phases << Phase.new(current_commands.dup, 0_u32, current_loop_message)
        end

        loop_start = (phases.size > 1 && phases[0].message.nil? && !has_button_checks && !is_animated) ? 1 : 0

        bank_dur = 1195_u32
        frames_bank = 72_u32
        cas_candidate = Citrine::ISO::DiscManifest.current.assets.find { |a| a.target_name.ends_with?(".CAS") }
        cas_path = cas_candidate.try(&.source_path) || Dir.glob("*.cas").first? || Dir.glob("**/*.cas").first?
        if cas_path && File.exists?(cas_path) && File.size(cas_path) >= 14
          hdr = Bytes.new(14)
          File.open(cas_path) { |f| f.read_fully?(hdr) } rescue nil
          if hdr[0, 4] == Bytes[0x43, 0x41, 0x53, 0x01]
            pitch_reg = IO::ByteFormat::LittleEndian.decode(UInt16, hdr[12, 2])
            if pitch_reg > 0
              bank_dur = 2446677_u32 // pitch_reg.to_u32
              frames_bank = ((bank_dur * 60 + 500) // 1000).to_u32
              frames_bank = 1_u32 if frames_bank == 0_u32
            end
          end
        end

        return ProgramProfile.new(
          phases: phases,
          boot_messages: boot_messages,
          loop_start_phase: loop_start,
          is_animated: is_animated,
          has_button_checks: has_button_checks,
          is_inline_assembly: is_inline_assembly,
          inline_asm_words: inline_asm_words,
          has_audio: has_audio,
          bank_dur_ms: bank_dur,
          frames_per_bank: frames_bank
        )
      end
    rescue ex
      STDERR.puts "EXTRACT EXCEPTION: #{ex.message}\n#{ex.backtrace.join("\n")}"
    end
  end

  # Default Citrine PS2 fallback screen
        if phases.empty?
          phases = [
            Phase.new([
              DrawCommand.new(DrawCommand::Type::Clear, color: 0xFF000000_u32),
              DrawCommand.new(DrawCommand::Type::Text, 60, 60, 20, 0, color: 0xFFFFFFFF_u32, text: "Hello, world!")
            ], 0_u32)
          ]
        end

        ProgramProfile.new(
          phases: phases,
          boot_messages: boot_messages,
          loop_start_phase: loop_start_phase,
          is_animated: is_animated,
          has_button_checks: has_button_checks,
          is_inline_assembly: is_inline_assembly,
          inline_asm_words: inline_asm_words,
          has_audio: has_audio
        )
      end
    end
  end
end
