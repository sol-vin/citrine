require "compiler/crystal/syntax"
require "./types"
require "../opcode"
require "../register_alloc"

module Citrine
  class BytecodeCompiler
    private def compile_string_interpolation(node : Crystal::StringInterpolation, allocator : RegisterAllocator, instructions : Array(Instruction), fn : CompiledFunction) : UInt8
      if node.expressions.empty?
        dest = allocator.alloc_temp
        str_idx = add_string("")
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: ""))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        return dest
      end

      cur_reg = compile_interpolated_piece(node.expressions[0], allocator, instructions, fn)

      node.expressions[1..-1].each do |piece|
        next_reg = compile_interpolated_piece(piece, allocator, instructions, fn)
        res_reg = allocator.alloc_temp
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, cur_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, next_reg, 0_u8)
        instr_val = Instruction.call_native_raw(res_reg, seq_base, NativeId::StringConcat)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(cur_reg)
        allocator.free_temp(next_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        cur_reg = res_reg
      end

      cur_reg
    end

    private def compile_interpolated_piece(piece : Crystal::ASTNode, allocator : RegisterAllocator, instructions : Array(Instruction), fn : CompiledFunction) : UInt8
      case piece
      when Crystal::StringLiteral
        dest = allocator.alloc_temp
        str_idx = add_string(piece.value)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: piece.value))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        dest
      when Crystal::NumberLiteral
        dest = allocator.alloc_temp
        str_idx = add_string(piece.value)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: piece.value))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        dest
      when Crystal::BoolLiteral
        val_s = piece.value ? "true" : "false"
        dest = allocator.alloc_temp
        str_idx = add_string(val_s)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: val_s))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        dest
      when Crystal::InstanceVar
        clean = piece.name.gsub(/^@/, "")
        is_str = false
        if cls = @current_class
          is_str = (cls.field_types[clean]? == "String")
        end
        is_str ||= clean.ends_with?("_str") || clean.ends_with?("duration_s") || clean == "dur_s" || clean.includes?("title") || clean.includes?("header") || clean.includes?("artist") || clean.includes?("album")
        if is_str
          compile_node(piece, allocator, instructions, fn)
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          hint = @current_class.try(&.field_types[clean]?) == "Bool" ? 2_u16 : 0_u16
          emit_to_string(val_reg, hint, allocator, instructions)
        end
      when Crystal::Var
        is_str = (@var_types[piece.name]? == "String") ||
                 piece.name.ends_with?("_str") || piece.name.ends_with?("duration_s") || piece.name == "dur_s" ||
                 piece.name.includes?("title") || piece.name.includes?("header")
        if is_str
          if reg = allocator.get_local(piece.name)
            dest = allocator.alloc_temp
            instructions << Instruction.encode_abc(Opcode::Move, dest, reg, 0_u8)
            dest
          else
            dest = allocator.alloc_temp
            instructions << Instruction.encode_load_nil(dest)
            dest
          end
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          hint = @var_types[piece.name]? == "Bool" ? 2_u16 : 0_u16
          emit_to_string(val_reg, hint, allocator, instructions)
        end
      when Crystal::Path
        p_name = piece.names.last
        if @var_types[p_name]? == "String"
          if reg = allocator.get_local(p_name)
            dest = allocator.alloc_temp
            instructions << Instruction.encode_abc(Opcode::Move, dest, reg, 0_u8)
            dest
          else
            dest = allocator.alloc_temp
            instructions << Instruction.encode_load_nil(dest)
            dest
          end
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          hint = @var_types[p_name]? == "Bool" ? 2_u16 : 0_u16
          emit_to_string(val_reg, hint, allocator, instructions)
        end
      when Crystal::Call
        is_str_call = piece.name == "to_s" || ["strip", "downcase", "upcase"].includes?(piece.name)
        if !is_str_call && (recv = piece.obj)
          recv_name = recv.is_a?(Crystal::Var) ? recv.name : (recv.is_a?(Crystal::Path) ? recv.names.last : nil)
          if recv_name && (rtype = @var_types[recv_name]?)
            cls_target = @classes[rtype]? || @classes[rtype.split("::").last]?
            if cls_target
              is_str_call = (cls_target.method_return_types[piece.name]? == "String" || cls_target.field_types[piece.name]? == "String")
            end
          end
        end
        is_str_call ||= piece.name == "to_s" || piece.name.ends_with?("_str") || piece.name.ends_with?("duration_s") || piece.name == "dur_s" || piece.name.includes?("title") || piece.name.includes?("header")

        if is_str_call
          compile_node(piece, allocator, instructions, fn)
        elsif piece.name == "[]" && (r = piece.obj) &&
              (r_name = r.is_a?(Crystal::Var) ? r.name : (r.is_a?(Crystal::Path) ? r.names.last : nil)) &&
              @var_types[r_name]? == "Array(String)"
          compile_node(piece, allocator, instructions, fn)
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          emit_to_string(val_reg, 0_u16, allocator, instructions)
        end
      when Crystal::StringInterpolation
        compile_node(piece, allocator, instructions, fn)
      when Crystal::If
        then_is_str = piece.then.is_a?(Crystal::StringLiteral) || piece.then.is_a?(Crystal::StringInterpolation)
        else_is_str = piece.else.is_a?(Crystal::StringLiteral) || piece.else.is_a?(Crystal::StringInterpolation)
        if then_is_str || else_is_str
          compile_node(piece, allocator, instructions, fn)
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          emit_to_string(val_reg, 0_u16, allocator, instructions)
        end
      when Crystal::Case
        has_str_when = piece.whens.any? { |w| w.body.is_a?(Crystal::StringLiteral) || w.body.is_a?(Crystal::StringInterpolation) }
        else_is_str = piece.else.is_a?(Crystal::StringLiteral) || piece.else.is_a?(Crystal::StringInterpolation)
        if has_str_when || else_is_str
          compile_node(piece, allocator, instructions, fn)
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          emit_to_string(val_reg, 0_u16, allocator, instructions)
        end
      else
        val_reg = compile_node(piece, allocator, instructions, fn)
        emit_to_string(val_reg, 0_u16, allocator, instructions)
      end
    end

    private def emit_to_string(val_reg : UInt8, hint : UInt16, allocator : RegisterAllocator, instructions : Array(Instruction)) : UInt8
      dest = allocator.alloc_temp
      seq_base = allocator.alloc_contiguous(2)
      instructions << Instruction.encode_abc(Opcode::Move, seq_base, val_reg, 0_u8)
      instructions << Instruction.encode_load_int((seq_base + 1).to_u8, hint)
      instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ToString)
      instructions << Instruction.new(instr_val)
      allocator.free_temp(val_reg)
      allocator.free_temp(seq_base)
      allocator.free_temp((seq_base + 1).to_u8)
      dest
    end

    private def map_native_call(name : String, is_gl : Bool = false) : NativeId?
      if is_gl
        case name
        when "begin" then return NativeId::GLBegin
        when "end" then return NativeId::GLEnd
        when "vertex" then return NativeId::GLVertex
        when "color" then return NativeId::GLColor
        when "tex_coord" then return NativeId::GLTexCoord
        when "push_matrix" then return NativeId::GLPushMatrix
        when "pop_matrix" then return NativeId::GLPopMatrix
        when "translate" then return NativeId::GLTranslate
        when "rotate" then return NativeId::GLRotate
        when "scale" then return NativeId::GLScale
        when "load_identity" then return NativeId::GLLoadIdentity
        end
      end

      case name

      when "init_window" then NativeId::InitWindow
      when "close_window" then NativeId::CloseWindow
      when "window_open?" then NativeId::WindowOpen
      when "set_target_fps" then NativeId::SetTargetFPS
      when "get_fps" then NativeId::GetFPS
      when "get_delta_time" then NativeId::GetDeltaTime
      when "begin_drawing" then NativeId::BeginDrawing
      when "end_drawing" then NativeId::EndDrawing
      when "clear_background" then NativeId::ClearBackground
      when "draw_rectangle" then NativeId::DrawRectangle
      when "draw_circle" then NativeId::DrawCircle
      when "draw_line" then NativeId::DrawLine
      when "draw_triangle" then NativeId::DrawTriangle
      when "draw_quad" then NativeId::DrawQuad
      when "draw_rectangle_rotated" then NativeId::DrawRectangleRotated
      when "draw_rounded_rectangle" then NativeId::DrawRoundedRectangle
      when "draw_text_rotated" then NativeId::DrawTextRotated
      when "gl_begin" then NativeId::GLBegin
      when "gl_end" then NativeId::GLEnd
      when "gl_vertex" then NativeId::GLVertex
      when "gl_color" then NativeId::GLColor
      when "gl_tex_coord" then NativeId::GLTexCoord
      when "gl_push_matrix" then NativeId::GLPushMatrix
      when "gl_pop_matrix" then NativeId::GLPopMatrix
      when "gl_translate" then NativeId::GLTranslate
      when "gl_rotate" then NativeId::GLRotate
      when "gl_scale" then NativeId::GLScale
      when "gl_load_identity" then NativeId::GLLoadIdentity
      when "draw_text" then NativeId::DrawText
      when "load_texture" then NativeId::LoadTexture
      when "draw_texture", "texture" then NativeId::DrawTexture
      when "draw_texture_rec" then NativeId::DrawTextureRec
      when "draw_texture_pro" then NativeId::DrawTexturePro
      when "load_palette" then NativeId::LoadPalette
      when "set_palette" then NativeId::SetPalette


      when "begin_mode_3d" then NativeId::BeginMode3D
      when "end_mode_3d" then NativeId::EndMode3D
      when "draw_cube" then NativeId::DrawCube
      when "draw_cube_wires" then NativeId::DrawCubeWires
      when "draw_grid" then NativeId::DrawGrid
      when "draw_mesh" then NativeId::DrawMesh
      when "load_model", "load_model_handle" then NativeId::LoadModel
      when "draw_model", "draw_model_native" then NativeId::DrawModel
      when "draw_model_ex", "draw_model_ex_native" then NativeId::DrawModelEx
      when "unload_model" then NativeId::UnloadModel
      when "draw_triangle_3d", "draw_triangle_3d_native" then NativeId::DrawTriangle3D
      when "draw_billboard", "draw_billboard_native" then NativeId::DrawBillboard
      when "button_down?" then NativeId::ButtonDown
      when "button_pressed?" then NativeId::ButtonPressed
      when "button_released?" then NativeId::ButtonReleased
      when "get_analog" then NativeId::GetAnalog
      when "set_rumble" then NativeId::SetRumble
      when "action_pressed?", "is_pressed?", "is_action_just_pressed" then NativeId::ActionPressed
      when "action_down?", "is_down?", "is_action_pressed" then NativeId::ActionDown
      when "action_released?", "is_released?", "is_action_just_released" then NativeId::ActionReleased
      when "add_action" then NativeId::ActionRegister
      when "load_sound" then NativeId::LoadSound
      when "play_sound" then NativeId::PlaySound
      when "stop_sound" then NativeId::StopSound
      when "unload_sound" then NativeId::AudioUnloadSound
      when "free_memory", "get_free_memory" then NativeId::AudioGetFreeMemory
      when "compute_dispatch", "dispatch" then NativeId::ComputeDispatch
      when "compute_sync", "sync" then NativeId::ComputeSync
      when "debug_overlay=" then NativeId::SetDebugOverlay
      when "log", "puts", "print", "println", "printf" then NativeId::Log
      when "debug_puts", "debug_log" then NativeId::DebugLog
      when "sleep" then NativeId::Sleep
      when "fiber_id" then NativeId::FiberId
      when "fiber_alive?" then NativeId::FiberAlive
      when "channel_new" then NativeId::ChannelNew
      when "channel_send" then NativeId::ChannelSend
      when "channel_receive" then NativeId::ChannelReceive
      when "channel_try_receive" then NativeId::ChannelTryReceive
      when "channel_count" then NativeId::ChannelCount
      when "channel_capacity" then NativeId::ChannelCapacity
      when "load_video" then NativeId::LoadVideo
      when "play_video" then NativeId::PlayVideo
      when "draw_video_frame" then NativeId::DrawVideoFrame
      when "video_finished?" then NativeId::VideoFinished
      when "pause_video" then NativeId::PauseVideo
      when "stop_video" then NativeId::StopVideo
      when "panic" then NativeId::Panic
      when "batch_transform_points", "vu0_batch_transform" then NativeId::VU0BatchTransform
      when "batch_dot_product", "vu0_batch_dot" then NativeId::VU0BatchDot
      when "play_cdda_track", "play_cdda", "play_stream", "play_music" then NativeId::AudioPlayCDDA
      when "stop_cdda", "stop_stream", "stop_music" then NativeId::AudioStopCDDA
      when "pause_stream", "pause_music" then NativeId::AudioPauseStream
      when "resume_stream", "resume_music" then NativeId::AudioResumeStream
      when "cdda_status", "get_cdda_status", "stream_status", "music_status", "music_playing?" then NativeId::AudioGetCDDAStatus
      when "set_volume", "set_audio_volume", "set_cdda_volume", "set_stream_volume", "set_music_volume", "master_volume=" then NativeId::AudioSetVolume
      when "seek_stream", "stream_seek", "seek_music" then NativeId::AudioSeekStream
      when "cpu_cycles", "cycles", "get_cycles", "cpu_cycle_count" then NativeId::CpuCycleCount
      when "cdvd_seek_entropy", "seek_entropy" then NativeId::CdvdSeekEntropy
      else nil
      end
    end


    private def resolve_type_id(type_name : String) : UInt32?
      clean = type_name.split("(").first.strip
      clean = clean[2..-1] if clean.starts_with?("::")
      case clean
      when "Nil" then TypeKind::Nil.value
      when "Bool" then TypeKind::Bool.value
      when "Int", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Number" then TypeKind::Int32.value
      when "Float", "Float32", "Float64" then TypeKind::Float32.value
      when "String" then TypeKind::String.value
      when "Array" then TypeKind::Array.value
      when "StaticArray" then TypeKind::StaticArray.value
      when "Pointer" then TypeKind::Pointer.value
      when "Box" then TypeKind::Box.value
      else
        if cls = @classes[clean]?
          cls.class_id
        elsif mod = @modules[clean]?
          mod.module_id
        else
          short = clean.split("::").last
          if cls = @classes[short]?
            cls.class_id
          elsif mod = @modules[short]?
            mod.module_id
          else
            nil
          end
        end
      end
    end

    private def resolve_constant_path(node : Crystal::Path) : ConstValue
      if node.names.size >= 2
        ename = node.names[0...-1].join("::")
        mname = node.names.last
        if emap = @enums[ename]?
          if val = emap[mname]?
            return ConstValue.new(ConstType::Int32, int_val: val.to_i32)
          elsif ename == "Actions" || ename == "Citrine::Actions"
            new_val = (emap.values.max? || 0_i64) + 1_i64
            emap[mname] = new_val
            return ConstValue.new(ConstType::Int32, int_val: new_val.to_i32)
          else
            compile_error("Enum '#{ename}' has no member '#{mname}'.", node)
          end
        elsif ename == "Actions" || ename == "Citrine::Actions"
          emap = @enums[ename] = Hash(String, Int64).new
          emap["None"] = 0_i64
          new_val = 1_i64
          emap[mname] = new_val
          return ConstValue.new(ConstType::Int32, int_val: new_val.to_i32)
        end
      elsif node.names.size == 1
        mname = node.names.first
        @enums.each do |_, emap|
          if val = emap[mname]?
            return ConstValue.new(ConstType::Int32, int_val: val.to_i32)
          end
        end
      end

      str = node.names.join("::")

      # Prioritize user-defined program constants (including namespace-scoped)
      lookup_candidates = [str]
      if node.names.size == 1
        if ns = @current_namespace
          lookup_candidates.unshift("#{ns}::#{str}")
        end
        lookup_candidates << node.names.last
      end

      lookup_candidates.each do |cand|
        if ast_node = @program_constants[cand]?
          if ast_node.is_a?(Crystal::NumberLiteral)
            clean_str = ast_node.value.gsub("_", "")
            if clean_str.includes?(".")
              return ConstValue.new(ConstType::Float32, float_val: clean_str.to_f32)
            elsif clean_str.starts_with?("0x") || clean_str.starts_with?("0X")
              val_u64 = clean_str[2..-1].to_u64?(16) || 0_u64
              return ConstValue.new(ConstType::Int32, int_val: val_u64.to_i32!, uint_val: val_u64.to_u32!)
            elsif clean_str.starts_with?("-")
              val_i64 = clean_str.to_i64? || 0_i64
              return ConstValue.new(ConstType::Int32, int_val: val_i64.to_i32!, uint_val: val_i64.to_u32!)
            else
              val_u64 = clean_str.to_u64? || 0_u64
              return ConstValue.new(ConstType::Int32, int_val: val_u64.to_i32!, uint_val: val_u64.to_u32!)
            end
          elsif ast_node.is_a?(Crystal::StringLiteral)
            return ConstValue.new(ConstType::String, str_val: ast_node.value)
          elsif ast_node.is_a?(Crystal::BoolLiteral)
            return ConstValue.new(ConstType::Bool, int_val: ast_node.value ? 1 : 0)
          elsif ast_node.is_a?(Crystal::Path)
            return resolve_constant_path(ast_node)
          end
        end
      end
      case str
      when "GL::POINTS", "GLMode::Points", "Citrine::GL::POINTS", "Citrine::GL::Mode::Points" then ConstValue.new(ConstType::Int32, int_val: 0)
      when "GL::LINES", "GLMode::Lines", "Citrine::GL::LINES", "Citrine::GL::Mode::Lines" then ConstValue.new(ConstType::Int32, int_val: 1)
      when "GL::LINE_STRIP", "GLMode::LineStrip", "Citrine::GL::LINE_STRIP", "Citrine::GL::Mode::LineStrip" then ConstValue.new(ConstType::Int32, int_val: 2)
      when "GL::LINE_LOOP", "GLMode::LineLoop", "Citrine::GL::LINE_LOOP", "Citrine::GL::Mode::LineLoop" then ConstValue.new(ConstType::Int32, int_val: 3)
      when "GL::TRIANGLES", "GLMode::Triangles", "Citrine::GL::TRIANGLES", "Citrine::GL::Mode::Triangles" then ConstValue.new(ConstType::Int32, int_val: 4)
      when "GL::TRIANGLE_STRIP", "GLMode::TriangleStrip", "Citrine::GL::TRIANGLE_STRIP", "Citrine::GL::Mode::TriangleStrip" then ConstValue.new(ConstType::Int32, int_val: 5)
      when "GL::TRIANGLE_FAN", "GLMode::TriangleFan", "Citrine::GL::TRIANGLE_FAN", "Citrine::GL::Mode::TriangleFan" then ConstValue.new(ConstType::Int32, int_val: 6)
      when "GL::QUADS", "GLMode::Quads", "Citrine::GL::QUADS", "Citrine::GL::Mode::Quads" then ConstValue.new(ConstType::Int32, int_val: 7)
      when "Button::Cross", "Citrine::Button::Cross" then ConstValue.new(ConstType::Int32, int_val: Button::Cross.value.to_i32)
      when "Button::Circle", "Citrine::Button::Circle" then ConstValue.new(ConstType::Int32, int_val: Button::Circle.value.to_i32)
      when "Button::Square", "Citrine::Button::Square" then ConstValue.new(ConstType::Int32, int_val: Button::Square.value.to_i32)
      when "Button::Triangle", "Citrine::Button::Triangle" then ConstValue.new(ConstType::Int32, int_val: Button::Triangle.value.to_i32)
      when "Button::Up", "Citrine::Button::Up" then ConstValue.new(ConstType::Int32, int_val: Button::Up.value.to_i32)
      when "Button::Down", "Citrine::Button::Down" then ConstValue.new(ConstType::Int32, int_val: Button::Down.value.to_i32)
      when "Button::Left", "Citrine::Button::Left" then ConstValue.new(ConstType::Int32, int_val: Button::Left.value.to_i32)
      when "Button::Right", "Citrine::Button::Right" then ConstValue.new(ConstType::Int32, int_val: Button::Right.value.to_i32)
      when "Button::L1", "Citrine::Button::L1" then ConstValue.new(ConstType::Int32, int_val: Button::L1.value.to_i32)
      when "Button::R1", "Citrine::Button::R1" then ConstValue.new(ConstType::Int32, int_val: Button::R1.value.to_i32)
      when "Button::L2", "Citrine::Button::L2" then ConstValue.new(ConstType::Int32, int_val: Button::L2.value.to_i32)
      when "Button::R2", "Citrine::Button::R2" then ConstValue.new(ConstType::Int32, int_val: Button::R2.value.to_i32)
      when "Button::L3", "Citrine::Button::L3" then ConstValue.new(ConstType::Int32, int_val: Button::L3.value.to_i32)
      when "Button::R3", "Citrine::Button::R3" then ConstValue.new(ConstType::Int32, int_val: Button::R3.value.to_i32)
      when "Button::Start", "Citrine::Button::Start" then ConstValue.new(ConstType::Int32, int_val: Button::Start.value.to_i32)
      when "Button::Select", "Citrine::Button::Select" then ConstValue.new(ConstType::Int32, int_val: Button::Select.value.to_i32)
      when "Port::Port1", "Port::Player1", "Citrine::Port::Port1", "Citrine::Port::Player1" then ConstValue.new(ConstType::Int32, int_val: 0)
      when "Port::Port2", "Port::Player2", "Citrine::Port::Port2", "Citrine::Port::Player2" then ConstValue.new(ConstType::Int32, int_val: 1)
      when "PI", "Math::PI", "Citrine::Math::PI" then ConstValue.new(ConstType::Float32, float_val: 3.14159265_f32)
      when "TAU", "Math::TAU", "Citrine::Math::TAU" then ConstValue.new(ConstType::Float32, float_val: 6.28318531_f32)
      when "E", "Math::E", "Citrine::Math::E" then ConstValue.new(ConstType::Float32, float_val: 2.71828183_f32)
      when "Color::White", "Citrine::Color::White" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 255_u8, 255_u8, 255_u8).to_u32)
      when "Color::Black", "Citrine::Color::Black" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 0_u8, 0_u8, 255_u8).to_u32)
      when "Color::Red", "Citrine::Color::Red" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 0_u8, 0_u8, 255_u8).to_u32)
      when "Color::Green", "Citrine::Color::Green" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 255_u8, 0_u8, 255_u8).to_u32)
      when "Color::Blue", "Citrine::Color::Blue" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 0_u8, 255_u8, 255_u8).to_u32)
      when "Color::Yellow", "Citrine::Color::Yellow" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 255_u8, 0_u8, 255_u8).to_u32)
      when "Color::Cyan", "Citrine::Color::Cyan" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 255_u8, 255_u8, 255_u8).to_u32)
      when "Color::Magenta", "Citrine::Color::Magenta" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 0_u8, 255_u8, 255_u8).to_u32)
      when "Color::Gray", "Citrine::Color::Gray" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(128_u8, 128_u8, 128_u8, 255_u8).to_u32)
      when "Color::DarkGray", "Citrine::Color::DarkGray" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(80_u8, 80_u8, 80_u8, 255_u8).to_u32)
      when "Color::LightGray", "Citrine::Color::LightGray" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(200_u8, 200_u8, 200_u8, 255_u8).to_u32)
      when "Color::Orange", "Citrine::Color::Orange" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 165_u8, 0_u8, 255_u8).to_u32)
      when "Color::Purple", "Citrine::Color::Purple" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(128_u8, 0_u8, 128_u8, 255_u8).to_u32)
      else
        if t_id = resolve_type_id(str)
          return ConstValue.new(ConstType::Int32, int_val: t_id.to_i32)
        end

        if ast_node = @program_constants[str]? || @program_constants[node.names.last]?
          if ast_node.is_a?(Crystal::NumberLiteral)
            clean_str = ast_node.value.gsub("_", "")
            if clean_str.includes?(".")
              return ConstValue.new(ConstType::Float32, float_val: clean_str.to_f32)
            elsif clean_str.starts_with?("0x") || clean_str.starts_with?("0X")
              val_u64 = clean_str[2..-1].to_u64?(16) || 0_u64
              return ConstValue.new(ConstType::Int32, int_val: val_u64.to_i32!, uint_val: val_u64.to_u32!)
            elsif clean_str.starts_with?("-")
              val_i64 = clean_str.to_i64? || 0_i64
              return ConstValue.new(ConstType::Int32, int_val: val_i64.to_i32!, uint_val: val_i64.to_u32!)
            else
              val_u64 = clean_str.to_u64? || 0_u64
              return ConstValue.new(ConstType::Int32, int_val: val_u64.to_i32!, uint_val: val_u64.to_u32!)
            end
          elsif ast_node.is_a?(Crystal::StringLiteral)
            return ConstValue.new(ConstType::String, str_val: ast_node.value)
          elsif ast_node.is_a?(Crystal::BoolLiteral)
            return ConstValue.new(ConstType::Bool, int_val: ast_node.value ? 1 : 0)
          elsif ast_node.is_a?(Crystal::Path)
            return resolve_constant_path(ast_node)
          elsif ast_node.is_a?(Crystal::Call) && ast_node.name == "new" && (ast_node.obj.to_s.ends_with?("Color"))
            parse_u8 = ->(n : Crystal::ASTNode?) : UInt8 {
              if n.is_a?(Crystal::NumberLiteral)
                clean = n.value.gsub(/[^0-9]/, "")
                clean.to_u8? || 0_u8
              else
                0_u8
              end
            }
            r = parse_u8.call(ast_node.args[0]?)
            g = parse_u8.call(ast_node.args[1]?)
            b = parse_u8.call(ast_node.args[2]?)
            a = ast_node.args.size >= 4 ? parse_u8.call(ast_node.args[3]?) : 255_u8
            return ConstValue.new(ConstType::Color, uint_val: ColorVal.new(r, g, b, a).to_u32)
          else
            return ConstValue.new(ConstType::Int32, int_val: 0)
          end
        end

        if str.starts_with?("Button::") || str.starts_with?("Citrine::Button::")
          compile_error("Unknown button constant '#{str}'. Valid buttons are: Cross, Circle, Square, Triangle, Up, Down, Left, Right, L1, R1, L2, R2, L3, R3, Start, Select.", node)
        elsif str.starts_with?("Port::") || str.starts_with?("Citrine::Port::")
          compile_error("Unknown controller port '#{str}'. Valid ports are: Port1, Port2 (or Player1, Player2).", node)
        elsif str.starts_with?("Color::") || str.starts_with?("Citrine::Color::")
          compile_error("Unknown color constant '#{str}'.", node)
        elsif str.starts_with?("GL::") || str.starts_with?("Citrine::GL::") || str.starts_with?("GLMode::")
          compile_error("Unknown GL constant '#{str}'.", node)
        elsif str.starts_with?("Actions::")
          emap = @enums["Actions"] ||= Hash(String, Int64).new
          mname = str.split("::").last
          val = emap[mname]? || ((emap.values.max? || 0_i64) + 1_i64)
          emap[mname] = val
          return ConstValue.new(ConstType::Int32, int_val: val.to_i32)
        else
          compile_error("Undefined constant '#{str}'.", node)
        end
      end
    end
  end
end
