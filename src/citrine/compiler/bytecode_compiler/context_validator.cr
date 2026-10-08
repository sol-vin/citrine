require "compiler/crystal/syntax"
require "../../parser/error"
require "../opcode"

module Citrine
  class BytecodeCompiler
    private def compile_error(message : String, node : Crystal::ASTNode? = nil) : NoReturn
      loc = node.try(&.location)
      raise CompileError.new(
        message,
        filename: @filename,
        line_number: loc.try(&.line_number),
        column_number: loc.try(&.column_number)
      )
    end

    private def extract_name(arg : Crystal::ASTNode?) : String?
      case arg
      when Crystal::SymbolLiteral then arg.value
      when Crystal::StringLiteral then arg.value
      when Crystal::Var           then arg.name
      when Crystal::Call          then arg.name
      else nil
      end
    end

    private def compute_subsys_mask(ctx_name : String) : UInt32
      mask = 1_u32 # SUBSYS_CORE
      if p = @program
        if ctx = p.vm_contexts[ctx_name]?
          ctx.requires.each do |req|
            case req
            when "citrine/draw2d" then mask |= (1_u32 << 1)
            when "citrine/draw3d", "citrine/draw" then mask |= (1_u32 << 2)
            when "citrine/gl" then mask |= (1_u32 << 3)
            when "citrine/audio" then mask |= (1_u32 << 4)
            when "citrine/video" then mask |= (1_u32 << 5)
            when "citrine/physics" then mask |= (1_u32 << 6)
            when "citrine/shader" then mask |= (1_u32 << 7)
            when "citrine/compute" then mask |= (1_u32 << 8)
            when "citrine/inputmap" then mask |= (1_u32 << 9)
            when "citrine/ui" then mask |= (1_u32 << 10)
            end
          end
        else
          mask |= (1_u32 << 1) if p.loaded_requires.includes?("citrine/draw2d")
          mask |= (1_u32 << 2) if p.loaded_requires.includes?("citrine/draw3d")
          mask |= (1_u32 << 3) if p.loaded_requires.includes?("citrine/gl")
          mask |= (1_u32 << 4) if p.loaded_requires.includes?("citrine/audio")
          mask |= (1_u32 << 5) if p.loaded_requires.includes?("citrine/video")
        end
      end
      mask
    end

    private def validate_context_subsystem_call(obj_str : String, method_name : String, active_ctx : String, node : Crystal::ASTNode)
      p = @program || return
      ctx = p.vm_contexts[active_ctx]?

      req_for_obj : String? = case obj_str
      when "Citrine::Draw2D", "Draw2D" then "citrine/draw2d"
      when "Citrine::Draw3D", "Draw3D" then "citrine/draw3d"
      when "Citrine::GL", "GL"         then "citrine/gl"
      when "Citrine::Audio", "Audio"   then "citrine/audio"
      when "Citrine::Video", "Video"   then "citrine/video"
      when "Citrine::Physics", "Physics", "Citrine::Physics2D" then "citrine/physics"
      when "Citrine::Shader", "Shader" then "citrine/shader"
      when "Citrine::Compute", "Compute" then "citrine/compute"
      when "Citrine::UI", "UI"         then "citrine/ui"
      when "Citrine::InputMap", "InputMap" then "citrine/inputmap"
      else nil
      end

      if req_for_obj
        other_contexts = p.vm_contexts.select { |k, v| v.requires.includes?(req_for_obj) }.keys
        if other_contexts.size > 0 && (ctx.nil? || !ctx.requires.includes?(req_for_obj))
          compile_error(
            "Subsystem violation: '#{obj_str}.#{method_name}' requires '#{req_for_obj}', which is not mounted in active main_loop context ':#{active_ctx}'.",
            node
          )
        end
      end

      if !obj_str.empty?
        p.vm_contexts.each do |cname, cdef|
          next if cname == active_ctx
          if cdef.structs.has_key?(obj_str) && (ctx.nil? || !ctx.structs.has_key?(obj_str))
            compile_error(
              "Context violation: Type '#{obj_str}' belongs to context(:#{cname}), which is not mounted in active main_loop context ':#{active_ctx}'.",
              node
            )
          end
        end
      end
    end

    private def check_port_literal(arg : Crystal::ASTNode, call_name : String, node : Crystal::ASTNode)
      if arg.is_a?(Crystal::NumberLiteral)
        val = arg.value.to_i?
        if val.nil? || (val != 0 && val != 1)
          compile_error("Invalid controller port #{arg.value}. PlayStation 2 hardware only supports Port 0 (Player 1) and Port 1 (Player 2).", node)
        end
      elsif arg.is_a?(Crystal::Path)
        if arg.names.first == "Port" || arg.names.first == "Citrine"
          pname = arg.names.last
          unless ["Port1", "Port2", "Player1", "Player2"].includes?(pname)
            compile_error("Unknown controller port 'Port::#{pname}'. PlayStation 2 only supports Port1 (Player1) and Port2 (Player2).", node)
          end
        end
      end
    end

    private def validate_native_call_arity(native_id : NativeId, name : String, argc : Int32, node : Crystal::ASTNode)
      case native_id
      when NativeId::InitWindow
        compile_error("Citrine.init_window requires 3 arguments: (width, height, title)", node) if argc != 3
      when NativeId::ClearBackground
        compile_error("Citrine.clear_background requires 1 argument: (color)", node) if argc != 1
      when NativeId::DrawRectangle
        compile_error("Citrine.draw_rectangle requires 5 arguments: (x, y, width, height, color)", node) if argc != 5
      when NativeId::DrawCircle
        compile_error("Citrine.draw_circle requires 4 arguments: (x, y, radius, color)", node) if argc != 4
      when NativeId::DrawLine
        compile_error("Citrine.draw_line requires 5 arguments: (x1, y1, x2, y2, color)", node) if argc != 5
      when NativeId::DrawTriangle
        compile_error("Citrine.draw_triangle requires 7 arguments: (x1, y1, x2, y2, x3, y3, color)", node) if argc != 7
      when NativeId::DrawQuad
        compile_error("Citrine.draw_quad requires 9 arguments: (x1, y1, x2, y2, x3, y3, x4, y4, color)", node) if argc != 9
      when NativeId::DrawRectangleRotated
        compile_error("Citrine.draw_rectangle_rotated requires 8 arguments: (x, y, w, h, angle, ox, oy, color)", node) if argc != 8
      when NativeId::DrawRoundedRectangle
        compile_error("Citrine.draw_rounded_rectangle requires 6 arguments: (x, y, w, h, radius, color)", node) if argc != 6
      when NativeId::DrawTextRotated
        compile_error("Citrine.draw_text_rotated requires 8 arguments: (text, x, y, size, angle, ox, oy, color)", node) if argc != 8
      when NativeId::DrawText
        compile_error("Citrine.draw_text requires 5 arguments: (text, x, y, size, color)", node) if argc != 5

      when NativeId::DrawCube, NativeId::DrawCubeWires
        compile_error("Citrine.#{name} requires 5 or 7 arguments: (pos, w, h, d, color) or (x, y, z, w, h, d, color)", node) if argc != 5 && argc != 7
      when NativeId::DrawGrid
        compile_error("Citrine.draw_grid requires 2 arguments: (slices, spacing)", node) if argc != 2
      when NativeId::LoadTexture
        compile_error("Citrine.load_texture requires 1 argument: (filename)", node) if argc != 1
      when NativeId::DrawTexture
        compile_error("Citrine.draw_texture requires 3 or 4 arguments: (texture_id, x, y[, tint])", node) if argc != 3 && argc != 4
      when NativeId::DrawTextureRec
        compile_error("Citrine.draw_texture_rec requires 7 or 8 arguments: (texture_id, sx, sy, sw, sh, dx, dy[, tint])", node) if argc != 7 && argc != 8
      when NativeId::DrawTexturePro
        compile_error("Citrine.draw_texture_pro requires 11 to 14 arguments: (tex, sx, sy, sw, sh, dx, dy, dw, dh, rot, ox, oy[, tint[, flip_flags]])", node) if argc < 11 || argc > 14
      when NativeId::LoadPalette
        compile_error("Citrine.load_palette requires 1 argument: (filename)", node) if argc != 1
      when NativeId::SetPalette
        compile_error("Citrine.set_palette requires 1 argument: (palette_id)", node) if argc != 1

      when NativeId::LoadSound
        compile_error("Citrine.load_sound requires 1 argument: (filename)", node) if argc != 1
      when NativeId::PlaySound
        compile_error("Citrine.play_sound requires 1 argument: (sound_id)", node) if argc != 1
      when NativeId::StopSound
        compile_error("Citrine.stop_sound requires 1 argument: (sound_id)", node) if argc != 1
      when NativeId::LoadVideo
        compile_error("Citrine.load_video requires 1 argument: (filename)", node) if argc != 1
      when NativeId::PlayVideo
        compile_error("Citrine.play_video requires 1 or 2 arguments: (video_id[, loop_enabled])", node) if argc != 1 && argc != 2
      when NativeId::DrawVideoFrame
        compile_error("Citrine.draw_video_frame requires 5 arguments: (video_id, x, y, w, h)", node) if argc != 5
      when NativeId::VideoFinished
        compile_error("Citrine.video_finished? requires 1 argument: (video_id)", node) if argc != 1
      when NativeId::ChannelSend
        compile_error("Citrine.channel_send requires 2 arguments: (channel, value)", node) if argc != 2
      when NativeId::ChannelReceive
        compile_error("Citrine.channel_receive requires 1 argument: (channel)", node) if argc != 1
      when NativeId::ChannelTryReceive
        compile_error("Citrine.channel_try_receive requires 1 argument: (channel)", node) if argc != 1
      when NativeId::ChannelCount
        compile_error("Citrine.channel_count requires 1 argument: (channel)", node) if argc != 1
      when NativeId::ChannelCapacity
        compile_error("Citrine.channel_capacity requires 1 argument: (channel)", node) if argc != 1
      when NativeId::GetAnalog
        compile_error("Citrine.get_analog requires 2 arguments: (port, axis)", node) if argc != 2
      when NativeId::SetRumble
        compile_error("Citrine.set_rumble requires 3 arguments: (port, small_motor, large_motor)", node) if argc != 3
      when NativeId::ActionPressed, NativeId::ActionDown, NativeId::ActionReleased
        compile_error("Action.#{name} requires 1 argument: (action)", node) if argc != 1
      when NativeId::Sleep
        compile_error("Citrine.sleep requires 1 argument: (seconds_or_ms)", node) if argc != 1
      when NativeId::Panic
        compile_error("Citrine.panic requires 1 argument: (message)", node) if argc != 1
      when NativeId::GLBegin
        compile_error("GL.begin requires 1 argument: (mode)", node) if argc != 1
      when NativeId::GLEnd
        compile_error("GL.end takes no arguments", node) if argc != 0
      when NativeId::GLTexCoord
        compile_error("GL.tex_coord requires 2 arguments: (u, v)", node) if argc != 2
      when NativeId::GLTranslate, NativeId::GLScale
        compile_error("GL.#{name} requires 3 arguments: (x, y, z)", node) if argc != 3
      when NativeId::GLRotate
        compile_error("GL.rotate requires 4 arguments: (angle, x, y, z)", node) if argc != 4
      when NativeId::VU0BatchTransform
        compile_error("VU0.batch_transform_points requires 2 arguments: (points, matrix)", node) if argc != 2
      when NativeId::VU0BatchDot
        compile_error("VU0.batch_dot_product requires 2 or 3 arguments: (vecs_a, vecs_b[, results])", node) if argc != 2 && argc != 3
      when NativeId::AudioPlayCDDA
        compile_error("Audio.play_cdda_track requires 1 argument: (track_number)", node) if argc != 1
      when NativeId::AudioStopCDDA
        compile_error("Audio.stop_cdda takes no arguments", node) if argc != 0
      when NativeId::AudioGetCDDAStatus
        compile_error("Audio.cdda_status takes no arguments", node) if argc != 0
      when NativeId::AudioSetVolume
        compile_error("Audio.set_volume requires 1 argument: (volume)", node) if argc != 1
      when NativeId::AudioSeekStream
        compile_error("Audio.seek_stream requires 1 argument: (time_sec)", node) if argc != 1
      else
        # no extra constraints
      end
    end
  end
end
