require "compiler/crystal/syntax"
require "json"
require "../importers/fluorite_media"
require "../iso/disc_manifest"

module Citrine
  class VarInfo
    getter name : String
    getter type_name : String

    def initialize(@name : String, @type_name : String)
    end
  end

  class MethodInfo
    getter name : String
    getter args : Array(String)

    def initialize(@name : String, @args : Array(String) = [] of String)
    end
  end

  class TypeInfo
    getter name : String
    getter instance_vars : Array(VarInfo)
    getter methods : Array(MethodInfo)

    def initialize(@name : String)
      @instance_vars = [] of VarInfo
      @methods = [] of MethodInfo
    end
  end

  class MacroExpander
    getter macros : Hash(String, Crystal::Macro)
    getter constant_arrays : Hash(String, Crystal::ArrayLiteral)
    property current_type : TypeInfo? = nil
    property filename : String? = nil

    def initialize(@filename : String? = nil)
      @macros = {} of String => Crystal::Macro
      @constant_arrays = {} of String => Crystal::ArrayLiteral
    end

    def expand(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::Expressions
        expanded_exprs = [] of Crystal::ASTNode
        node.expressions.each do |child|
          if child.is_a?(Crystal::Macro)
            @macros[child.name] = child
            # Strip macro definition node from runtime AST
            expanded_exprs << Crystal::Nop.new
          elsif child.is_a?(Crystal::Call) && is_macro_call?(child)
            expanded = expand_call(child)
            if expanded.is_a?(Crystal::Expressions)
              expanded.expressions.each { |e| expanded_exprs << expand(e) }
            else
              expanded_exprs << expand(expanded)
            end
          elsif child.is_a?(Crystal::MacroFor)
            expanded = expand_macro_for(child)
            if expanded.is_a?(Crystal::Expressions)
              expanded.expressions.each { |e| expanded_exprs << expand(e) }
            else
              expanded_exprs << expand(expanded)
            end
          else
            expanded_exprs << expand(child)
          end
        end
        Crystal::Expressions.new(expanded_exprs)

      when Crystal::ClassDef
        cls_name = node.name.to_s
        type_info = TypeInfo.new(cls_name)
        prescan_class_body(node.body, type_info)

        old_type = @current_type
        @current_type = type_info

        if body = node.body
          node.body = expand(body)
        end

        @current_type = old_type
        node

      when Crystal::Def
        if body = node.body
          node.body = expand(body)
        end
        node

      when Crystal::MacroFor
        expand_macro_for(node)

      when Crystal::Assign
        node.target = expand(node.target)
        node.value = expand(node.value)
        if node.value.is_a?(Crystal::ArrayLiteral)
          t_str = node.target.to_s
          if t_str =~ /^[A-Z]/
            @constant_arrays[t_str] = node.value.as(Crystal::ArrayLiteral)
          end
        end
        node

      when Crystal::BinaryOp
        node.left = expand(node.left)
        node.right = expand(node.right)
        node

      when Crystal::If
        node.cond = expand(node.cond)
        node.then = expand(node.then)
        if node_else = node.else
          node.else = expand(node_else)
        end
        node

      when Crystal::While
        node.cond = expand(node.cond)
        node.body = expand(node.body)
        node

      when Crystal::Call
        if is_macro_call?(node)
          expanded = expand_call(node)
          expand(expanded)
        else
          # Expand block, receiver, and arguments
          if block = node.block
            if body = block.body
              block.body = expand(body)
            end
          end
          if obj = node.obj
            node.obj = expand(obj)
          end
          node.args = node.args.map { |a| expand(a) }

          # Constant folding for .size / .length on ArrayLiteral
          if (node.name == "size" || node.name == "length") && node.args.empty?
            if (obj = node.obj)
              if obj.is_a?(Crystal::ArrayLiteral)
                return Crystal::NumberLiteral.new(obj.as(Crystal::ArrayLiteral).elements.size)
              elsif obj.is_a?(Crystal::Path)
                target_name = obj.names.last
                if target_name =~ /^[A-Z]/ && (arr_lit = @constant_arrays[target_name]?)
                  return Crystal::NumberLiteral.new(arr_lit.elements.size)
                end
              end
            end
          end

          node
        end

      else
        node
      end
    end

    private def prescan_class_body(node : Crystal::ASTNode?, type_info : TypeInfo)
      return unless node
      nodes = node.is_a?(Crystal::Expressions) ? node.expressions : [node]

      nodes.each do |child|
        case child
        when Crystal::TypeDeclaration
          if child.var.is_a?(Crystal::InstanceVar)
            vname = child.var.to_s.gsub(/^@/, "")
            tname = child.declared_type.to_s
            type_info.instance_vars << VarInfo.new(vname, tname) unless type_info.instance_vars.any? { |v| v.name == vname }
          end
        when Crystal::Assign
          if child.target.is_a?(Crystal::InstanceVar)
            vname = child.target.to_s.gsub(/^@/, "")
            type_info.instance_vars << VarInfo.new(vname, "Object") unless type_info.instance_vars.any? { |v| v.name == vname }
          end
        when Crystal::Call
          if ["property", "getter", "setter"].includes?(child.name) && child.args.size > 0
            arg0 = child.args[0]
            if arg0.is_a?(Crystal::TypeDeclaration)
              vname = arg0.var.to_s.gsub(/^@/, "")
              tname = arg0.declared_type.to_s
              type_info.instance_vars << VarInfo.new(vname, tname) unless type_info.instance_vars.any? { |v| v.name == vname }
            else
              vname = arg0.to_s.gsub(/^@/, "")
              type_info.instance_vars << VarInfo.new(vname, "Object") unless type_info.instance_vars.any? { |v| v.name == vname }
            end
          end
        when Crystal::Def
          type_info.methods << MethodInfo.new(child.name, child.args.map(&.name))
          child.args.each do |a|
            if a.name.starts_with?("@")
              vname = a.name.gsub(/^@/, "")
              tname = a.restriction.try(&.to_s) || "Object"
              type_info.instance_vars << VarInfo.new(vname, tname) unless type_info.instance_vars.any? { |v| v.name == vname }
            end
          end
        end
      end
    end

    private def is_macro_call?(call : Crystal::Call) : Bool
      is_citrine_bake_macro = (call.obj.nil? || call.obj.to_s == "Citrine") && [
        "bake",
        "bake_asset",
        "bake_texture",
        "bake_cd_track",
        "bake_cd_album",
        "bake_stream",
        "bake_stream_album",
        "bake_dvd_video",
        "bake_spu2_sound",
        "album_track_count",
        "disc_files"
      ].includes?(call.name)

      is_citrine_media_macro = (call.obj.nil? || call.obj.to_s == "Citrine") && [
        "load_track_titles",
        "load_track_durations",
        "album_track_titles",
        "album_track_durations",
        "album_title",
        "album_name",
        "album_artist"
      ].includes?(call.name)

      is_citrine_bake_macro ||
        is_citrine_media_macro ||
        call.name.ends_with?("!") ||
        call.name == "fsm" ||
        call.name == "citrine_ecs" ||
        @macros.has_key?(call.name)
    end

    private def expand_call(call : Crystal::Call) : Crystal::ASTNode
      case call.name
      when "citrine_ecs!", "citrine_ecs"
        expand_ecs(call)
      when "fsm!", "fsm"
        expand_fsm(call)
      when "bake", "bake_asset"
        expand_bake(call)
      when "bake_texture"
        expand_bake_texture(call)
      when "bake_cd_track"
        expand_bake_cd_track(call)
      when "bake_cd_album"
        expand_bake_cd_album(call)
      when "bake_stream"
        expand_bake_stream(call)
      when "bake_stream_album"
        expand_bake_stream_album(call)
      when "bake_dvd_video"
        expand_bake_dvd_video(call)
      when "bake_spu2_sound"
        expand_bake_spu2_sound(call)
      when "album_track_count"
        expand_album_track_count(call)
      when "disc_files"
        expand_disc_files(call)
      when "load_track_titles", "album_track_titles"
        expand_track_titles(call)
      when "load_track_durations", "album_track_durations"
        expand_track_durations(call)
      when "album_title", "album_name"
        expand_album_title(call)
      when "album_artist"
        expand_album_artist(call)
      else
        if mac = @macros[call.name]?
          expand_user_macro(mac, call)
        else
          call
        end
      end
    end

    # Expands user macro by substituting arguments and re-parsing
    private def expand_user_macro(mac : Crystal::Macro, call : Crystal::Call) : Crystal::ASTNode
      arg_map = {} of String => String
      if t = @current_type
        arg_map["@type.name"] = t.name
      end
      mac.args.each_with_index do |param, idx|
        if actual = call.args[idx]?
          arg_map[param.name] = actual.to_s
        end
      end

      code_str = String.build do |io|
        dump_macro_body(mac.body, arg_map, io)
      end

      begin
        Crystal::Parser.new(code_str).parse
      rescue
        # Fallback to empty expressions if parsing fails
        Crystal::Nop.new
      end
    end

    private def expand_macro_for(node : Crystal::MacroFor) : Crystal::ASTNode
      var_name = node.vars.first?.try(&.name) || "item"
      exp_str = node.exp.to_s

      expanded_exprs = [] of Crystal::ASTNode

      if (exp_str.includes?("@type.instance_vars") || exp_str.includes?("instance_vars")) && (t = @current_type)
        t.instance_vars.each do |iv|
          env = {
            var_name => iv.name,
            "#{var_name}.name" => iv.name,
            "#{var_name}.type" => iv.type_name,
            "@type.name" => t.name
          }
          code_str = String.build do |io|
            dump_macro_body(node.body, env, io)
          end
          begin
            parsed = Crystal::Parser.new(code_str).parse
            if parsed.is_a?(Crystal::Expressions)
              parsed.expressions.each { |e| expanded_exprs << e }
            else
              expanded_exprs << parsed
            end
          rescue
          end
        end
      elsif (exp_str.includes?("@type.methods") || exp_str.includes?("methods")) && (t = @current_type)
        t.methods.each do |m|
          env = {
            var_name => m.name,
            "#{var_name}.name" => m.name,
            "@type.name" => t.name
          }
          code_str = String.build do |io|
            dump_macro_body(node.body, env, io)
          end
          begin
            parsed = Crystal::Parser.new(code_str).parse
            if parsed.is_a?(Crystal::Expressions)
              parsed.expressions.each { |e| expanded_exprs << e }
            else
              expanded_exprs << parsed
            end
          rescue
          end
        end
      end

      Crystal::Expressions.new(expanded_exprs)
    end

    private def dump_macro_body(node : Crystal::ASTNode, env : Hash(String, String), io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |child| dump_macro_body(child, env, io) }
      when Crystal::MacroLiteral
        io << node.value
      when Crystal::MacroExpression
        if exp = node.exp
          key = exp.to_s
          if env.has_key?(key)
            io << env[key]
          elsif exp.is_a?(Crystal::Call) && exp.obj.is_a?(Crystal::Var) && exp.name == "name"
            v = exp.obj.as(Crystal::Var).name
            io << env["#{v}.name"]? || env[v]? || ""
          elsif exp.is_a?(Crystal::Call) && exp.obj.is_a?(Crystal::Var) && exp.name == "type"
            v = exp.obj.as(Crystal::Var).name
            io << env["#{v}.type"]? || ""
          elsif exp.is_a?(Crystal::Call) && exp.obj.to_s == "@type" && exp.name == "name"
            io << env["@type.name"]? || @current_type.try(&.name) || ""
          elsif exp.is_a?(Crystal::Var) && env.has_key?(exp.name)
            io << env[exp.name]
          else
            io << exp.to_s
          end
        end
      when Crystal::MacroIf
        cond_str = node.cond.to_s
        is_true = true
        env.each do |k, v|
          cond_str = cond_str.gsub(k, %("#{v}"))
        end
        if cond_str.includes?("==")
          parts = cond_str.split("==").map(&.strip)
          is_true = (parts[0] == parts[1]) if parts.size == 2
        elsif cond_str.includes?("!=")
          parts = cond_str.split("!=").map(&.strip)
          is_true = (parts[0] != parts[1]) if parts.size == 2
        end
        if is_true
          dump_macro_body(node.then, env, io)
        elsif node_else = node.else
          dump_macro_body(node_else, env, io)
        end
      when Crystal::MacroFor
        expanded = expand_macro_for(node)
        io << expanded.to_s
      when Crystal::Var
        if env.has_key?(node.name)
          io << env[node.name]
        else
          io << node.to_s
        end
      else
        io << node.to_s
      end
    end

    # Expands citrine_ecs! into contiguous component memory declarations
    private def expand_ecs(call : Crystal::Call) : Crystal::ASTNode
      block = call.block
      return call unless block

      exprs = [] of Crystal::ASTNode
      component_names = [] of String

      if body = block.body
        body_nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        body_nodes.each do |child|
          if child.is_a?(Crystal::Call) && (child.name == "component" || child.name == "entity")
            if first_arg = child.args.first?
              cname = first_arg.to_s
              component_names << cname
              # Assign component ID constant: COMPONENT_<NAME> = id
              cid_const = Crystal::Assign.new(
                Crystal::Var.new("COMPONENT_#{cname.upcase}"),
                Crystal::NumberLiteral.new(component_names.size)
              )
              exprs << cid_const
            end
          end
        end
      end

      # Emit total component count
      exprs << Crystal::Assign.new(
        Crystal::Var.new("TOTAL_COMPONENTS"),
        Crystal::NumberLiteral.new(component_names.size)
      )

      Crystal::Expressions.new(exprs)
    end

    # Expands fsm! BossAI, initial: :idle do ... end
    private def expand_fsm(call : Crystal::Call) : Crystal::ASTNode
      block = call.block
      return call unless block

      fsm_name = call.args.first?.try(&.to_s) || "FSM"
      var_name = "#{fsm_name.underscore}_state"

      exprs = [] of Crystal::ASTNode
      state_names = [] of String

      if body = block.body
        body_nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        body_nodes.each do |child|
          if child.is_a?(Crystal::Call) && child.name == "state"
            if s_arg = child.args.first?
              s_name = s_arg.to_s.gsub(/^:/, "")
              state_names << s_name
              # STATE_<NAME> = idx
              exprs << Crystal::Assign.new(
                Crystal::Var.new("STATE_#{s_name.upcase}"),
                Crystal::NumberLiteral.new(state_names.size - 1)
              )
            end
          end
        end
      end

      # Initial state assignment
      exprs << Crystal::Assign.new(
        Crystal::Var.new(var_name),
        Crystal::NumberLiteral.new(0)
      )

      Crystal::Expressions.new(exprs)
    end

    private def resolve_asset_path(rel_path : String) : String
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      File.expand_path(rel_path, base_dir)
    end

    private def expand_bake(call : Crystal::Call) : Crystal::ASTNode
      return Crystal::StringLiteral.new("") if call.args.empty?
      arg0 = call.args[0]
      src_rel = arg0.is_a?(Crystal::StringLiteral) ? arg0.value : arg0.to_s
      target_rel = (call.args.size > 1 && call.args[1].is_a?(Crystal::StringLiteral)) ? call.args[1].as(Crystal::StringLiteral).value : nil

      full_src = resolve_asset_path(src_rel)
      asset = Citrine::ISO::DiscManifest.current.add_file(full_src, target_rel)
      Crystal::StringLiteral.new(asset.target_name)
    end

    private def expand_bake_texture(call : Crystal::Call) : Crystal::ASTNode
      return Crystal::StringLiteral.new("") if call.args.empty?
      arg0 = call.args[0]
      src_rel = arg0.is_a?(Crystal::StringLiteral) ? arg0.value : arg0.to_s
      target_rel = (call.args.size > 1 && call.args[1].is_a?(Crystal::StringLiteral)) ? call.args[1].as(Crystal::StringLiteral).value : nil
      width = (call.args.size > 2 && call.args[2].is_a?(Crystal::NumberLiteral)) ? call.args[2].as(Crystal::NumberLiteral).value.to_i : 128
      height = (call.args.size > 3 && call.args[3].is_a?(Crystal::NumberLiteral)) ? call.args[3].as(Crystal::NumberLiteral).value.to_i : 128
      clut = (call.args.size > 4 && call.args[4].is_a?(Crystal::NumberLiteral)) ? call.args[4].as(Crystal::NumberLiteral).value.to_i : 8

      full_src = resolve_asset_path(src_rel)
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      out_target = target_rel || File.basename(src_rel).sub(/\.(png|jpg|jpeg|bmp)$/i, ".cbt")
      out_full = File.join(base_dir, out_target)

      # Convert if source is an image and target is .cbt and target is missing or stale
      if File.exists?(full_src)
        ext = File.extname(full_src).downcase
        if [".png", ".jpg", ".jpeg", ".bmp"].includes?(ext) && out_full.ends_with?(".cbt")
          is_stale = !File.exists?(out_full) || (File.info(full_src).modification_time > File.info(out_full).modification_time)
          if is_stale
            begin
              Importers::FluoriteMedia.convert_texture(
                full_src,
                out_full,
                Importers::FluoriteMedia::TextureConfig.new(width: width, height: height, clut_bits: clut)
              )
            rescue
            end
          end
        end
      end

      asset = Citrine::ISO::DiscManifest.current.add_texture(
        File.exists?(out_full) ? out_full : full_src,
        out_target,
        width: width,
        height: height,
        clut: clut
      )
      Crystal::StringLiteral.new(asset.target_name)
    end

    private def expand_bake_cd_track(call : Crystal::Call) : Crystal::ASTNode
      return Crystal::NumberLiteral.new(0) if call.args.empty?
      arg0 = call.args[0]
      src_rel = arg0.is_a?(Crystal::StringLiteral) ? arg0.value : arg0.to_s
      track_num = (call.args.size > 1 && call.args[1].is_a?(Crystal::NumberLiteral)) ? call.args[1].as(Crystal::NumberLiteral).value.to_i : nil

      full_src = resolve_asset_path(src_rel)
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      ext = File.extname(full_src).downcase
      final_track_path = full_src
      if [".wav", ".mp3", ".ogg", ".flac"].includes?(ext)
        out_raw_name = sprintf("track%02d.raw", track_num || Citrine::ISO::DiscManifest.current.next_cd_track_number)
        out_raw_path = File.join(base_dir, out_raw_name)
        if !File.exists?(out_raw_path) || (File.info(full_src).modification_time > File.info(out_raw_path).modification_time)
          begin
            Citrine::Importers::FluoriteMedia.convert_cdda(full_src, out_raw_path)
          rescue
          end
        end
        final_track_path = out_raw_path if File.exists?(out_raw_path)
      end

      asset = Citrine::ISO::DiscManifest.current.add_cd_track(final_track_path, track_num)
      Crystal::NumberLiteral.new(asset.track_number || 2)
    end

    private def expand_bake_cd_album(call : Crystal::Call) : Crystal::ASTNode
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      meta = load_album_metadata(call)

      # Register all generated track*.raw into DiscManifest
      if Dir.exists?(base_dir)
        raw_tracks = Dir.children(base_dir).select { |f| f =~ /^track\d+\.raw$/i }.sort_by do |f|
          md = f.match(/track(\d+)/i)
          md ? md[1].to_i : 999
        end

        raw_tracks.each do |raw_f|
          raw_path = File.join(base_dir, raw_f)
          md = raw_f.match(/track(\d+)/i)
          t_num = md ? md[1].to_i : nil
          Citrine::ISO::DiscManifest.current.add_cd_track(raw_path, t_num)
        end

        # Register cover.cbt if present
        cbt_path = File.join(base_dir, "cover.cbt")
        if File.exists?(cbt_path)
          Citrine::ISO::DiscManifest.current.add_file(cbt_path, "COVER.CBT")
        end

        # Register album_metadata.json if present
        json_path = File.join(base_dir, "album_metadata.json")
        if File.exists?(json_path)
          Citrine::ISO::DiscManifest.current.add_file(json_path, "ALBUM.JSON")
        end
      end

      count = meta ? meta.size : Citrine::ISO::DiscManifest.current.cd_audio_tracks.size
      Crystal::NumberLiteral.new(count)
    end

    private def expand_bake_stream(call : Crystal::Call) : Crystal::ASTNode
      return Crystal::StringLiteral.new("") if call.args.empty?
      arg0 = call.args[0]
      src_rel = arg0.is_a?(Crystal::StringLiteral) ? arg0.value : arg0.to_s
      target_rel = (call.args.size > 1 && call.args[1].is_a?(Crystal::StringLiteral)) ? call.args[1].as(Crystal::StringLiteral).value : nil

      bitrate = 96_000
      call.named_args.try(&.each do |narg|
        if narg.name == "bitrate"
          if narg.value.is_a?(Crystal::NumberLiteral)
            bitrate = narg.value.as(Crystal::NumberLiteral).value.to_i
          elsif narg.value.is_a?(Crystal::Call) && narg.value.as(Crystal::Call).name == "kbps"
            obj = narg.value.as(Crystal::Call).obj
            if obj.is_a?(Crystal::NumberLiteral)
              bitrate = obj.as(Crystal::NumberLiteral).value.to_i * 1000
            end
          end
        elsif narg.name == "quality"
          val = narg.value.to_s.sub(/^:/, "")
          case val
          when "hi", "high", "studio" then bitrate = 192_000
          when "mid", "medium", "standard" then bitrate = 96_000
          when "low", "compact" then bitrate = 64_000
          when "voice", "speech" then bitrate = 32_000
          end
        end
      end)

      full_src = resolve_asset_path(src_rel)
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      out_target = target_rel || File.basename(src_rel).sub(/\.(wav|ogg|mp3|flac|m4a|aac)$/i, ".cas")
      out_full = File.join(base_dir, out_target)

      if File.exists?(full_src) && (!File.exists?(out_full) || File.info(full_src).modification_time > File.info(out_full).modification_time)
        ext = File.extname(full_src).downcase
        if [".wav", ".ogg", ".mp3", ".flac", ".m4a", ".aac"].includes?(ext)
          begin
            Citrine::Importers::FluoriteMedia.convert_to_cas(full_src, out_full, bitrate: bitrate)
          rescue
          end
        end
      end

      asset = Citrine::ISO::DiscManifest.current.add_file(File.exists?(out_full) ? out_full : full_src, out_target)
      Crystal::StringLiteral.new(asset.target_name)
    end

    private def expand_bake_stream_album(call : Crystal::Call) : Crystal::ASTNode
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      album_dir = File.join(base_dir, "album")
      if call.args.size > 0 && call.args.first.is_a?(Crystal::StringLiteral)
        arg_val = call.args.first.as(Crystal::StringLiteral).value
        expanded = File.expand_path(arg_val, base_dir)
        album_dir = expanded if Dir.exists?(expanded)
      end

      bitrate = 96_000
      call.named_args.try(&.each do |narg|
        if narg.name == "bitrate"
          if narg.value.is_a?(Crystal::NumberLiteral)
            bitrate = narg.value.as(Crystal::NumberLiteral).value.to_i
          elsif narg.value.is_a?(Crystal::Call) && narg.value.as(Crystal::Call).name == "kbps"
            obj = narg.value.as(Crystal::Call).obj
            if obj.is_a?(Crystal::NumberLiteral)
              bitrate = obj.as(Crystal::NumberLiteral).value.to_i * 1000
            end
          end
        elsif narg.name == "quality"
          val = narg.value.to_s.sub(/^:/, "")
          case val
          when "hi", "high", "studio" then bitrate = 192_000
          when "mid", "medium", "standard" then bitrate = 96_000
          when "low", "compact" then bitrate = 64_000
          when "voice", "speech" then bitrate = 32_000
          end
        end
      end)

      if Dir.exists?(album_dir)
        json_path = File.join(base_dir, "album_metadata.json")
        existing_cas = Dir.children(base_dir).any? { |f| f =~ /^track\d+\.cas$/i }
        needs_regen = false
        if !existing_cas || !File.exists?(json_path)
          needs_regen = true
        else
          meta_mtime = File.info(json_path).modification_time
          audio_exts = [".ogg", ".mp3", ".wav", ".flac", ".m4a"]
          album_files = Dir.children(album_dir).select do |f|
            audio_exts.includes?(File.extname(f).downcase)
          end
          if album_files.any? { |f| File.info(File.join(album_dir, f)).modification_time > meta_mtime }
            needs_regen = true
          end
        end

        if needs_regen
          Citrine::Importers::FluoriteMedia.import_stream_album(album_dir, base_dir, bitrate: bitrate) rescue nil
        end
      end

      count = 0
      if Dir.exists?(base_dir)
        cas_tracks = Dir.children(base_dir).select { |f| f =~ /^track\d+\.cas$/i }.sort_by do |f|
          md = f.match(/track(\d+)/i)
          md ? md[1].to_i : 999
        end

        cas_tracks.each do |cas_f|
          cas_path = File.join(base_dir, cas_f)
          Citrine::ISO::DiscManifest.current.add_file(cas_path, cas_f.upcase)
          count += 1
        end

        cbt_path = File.join(base_dir, "cover.cbt")
        if File.exists?(cbt_path)
          Citrine::ISO::DiscManifest.current.add_file(cbt_path, "COVER.CBT")
        end

        json_path = File.join(base_dir, "album_metadata.json")
        if File.exists?(json_path)
          Citrine::ISO::DiscManifest.current.add_file(json_path, "ALBUM.JSON")
        end
      end

      Crystal::NumberLiteral.new(count)
    end

    private def expand_bake_dvd_video(call : Crystal::Call) : Crystal::ASTNode
      return Crystal::StringLiteral.new("") if call.args.empty?
      arg0 = call.args[0]
      src_rel = arg0.is_a?(Crystal::StringLiteral) ? arg0.value : arg0.to_s
      target_rel = (call.args.size > 1 && call.args[1].is_a?(Crystal::StringLiteral)) ? call.args[1].as(Crystal::StringLiteral).value : nil

      full_src = resolve_asset_path(src_rel)
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      out_target = target_rel || File.basename(src_rel).sub(/\.(mp4|avi|mov|mkv)$/i, ".pss")
      out_full = File.join(base_dir, out_target)

      if File.exists?(full_src) && (!File.exists?(out_full) || File.info(full_src).modification_time > File.info(out_full).modification_time)
        ext = File.extname(full_src).downcase
        if [".mp4", ".avi", ".mov", ".mkv", ".webm"].includes?(ext)
          begin
            Citrine::Importers::FluoriteMedia.convert_video(full_src, out_full, Citrine::Importers::FluoriteMedia::VideoConfig.new(fps: 15))
          rescue
          end
        end
      end

      asset = Citrine::ISO::DiscManifest.current.add_dvd_video(File.exists?(out_full) ? out_full : full_src, out_target)
      Crystal::StringLiteral.new(asset.target_name)
    end

    private def expand_bake_spu2_sound(call : Crystal::Call) : Crystal::ASTNode
      return Crystal::StringLiteral.new("") if call.args.empty?
      arg0 = call.args[0]
      src_rel = arg0.is_a?(Crystal::StringLiteral) ? arg0.value : arg0.to_s
      target_rel = (call.args.size > 1 && call.args[1].is_a?(Crystal::StringLiteral)) ? call.args[1].as(Crystal::StringLiteral).value : nil

      full_src = resolve_asset_path(src_rel)
      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      out_target = target_rel || File.basename(src_rel).sub(/\.(wav|ogg|mp3|flac)$/i, ".vag")
      out_full = File.join(base_dir, out_target)

      if File.exists?(full_src) && (!File.exists?(out_full) || File.info(full_src).modification_time > File.info(out_full).modification_time)
        ext = File.extname(full_src).downcase
        if [".wav", ".ogg", ".mp3", ".flac"].includes?(ext)
          begin
            Citrine::Importers::FluoriteMedia.convert_audio(full_src, out_full, Citrine::Importers::FluoriteMedia::AudioConfig.new(sample_rate: 22050))
          rescue
          end
        end
      end

      asset = Citrine::ISO::DiscManifest.current.add_spu2_sound(File.exists?(out_full) ? out_full : full_src, out_target)
      Crystal::StringLiteral.new(asset.target_name)
    end

    private def expand_album_track_count(call : Crystal::Call) : Crystal::ASTNode
      meta = load_album_metadata(call)
      count = meta ? meta.size : 0
      Crystal::NumberLiteral.new(count)
    end

    private def expand_disc_files(call : Crystal::Call) : Crystal::ASTNode
      elems = [] of Crystal::ASTNode
      Citrine::ISO::DiscManifest.current.data_files.each do |a|
        elems << Crystal::StringLiteral.new(a.target_name)
      end
      Crystal::ArrayLiteral.new(elems)
    end

    private def load_album_metadata(call : Crystal::Call) : Array(JSON::Any)?
      arg_path = if call.args.size > 0 && call.args.first.is_a?(Crystal::StringLiteral)
                   call.args.first.as(Crystal::StringLiteral).value
                 else
                   nil
                 end

      base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
      album_dir = File.join(base_dir, "album")
      full_path = File.join(base_dir, "album_metadata.json")

      if arg_path
        expanded = File.expand_path(arg_path, base_dir)
        if Dir.exists?(expanded) || arg_path.ends_with?("/") || arg_path.ends_with?("\\")
          album_dir = expanded
        elsif arg_path.ends_with?(".json")
          full_path = expanded
        end
      end

      # If metadata JSON does not exist or is stale, check if an album directory exists to auto-generate it
      if Dir.exists?(album_dir)
        needs_regen = false
        if !File.exists?(full_path)
          needs_regen = true
        else
          meta_mtime = File.info(full_path).modification_time
          audio_exts = [".ogg", ".mp3", ".wav", ".flac", ".m4a"]
          album_files = Dir.children(album_dir).select do |f|
            audio_exts.includes?(File.extname(f).downcase)
          end
          if album_files.any? { |f| File.info(File.join(album_dir, f)).modification_time > meta_mtime }
            needs_regen = true
          else
            begin
              parsed_check = JSON.parse(File.read(full_path)).as_a
              needs_regen = (parsed_check.size != album_files.size)
            rescue
              needs_regen = true
            end
          end
        end

        if needs_regen
          Importers::FluoriteMedia.import_album(album_dir, base_dir) rescue nil
        end
      end

      if File.exists?(full_path)
        begin
          JSON.parse(File.read(full_path)).as_a
        rescue
          nil
        end
      else
        nil
      end
    end

    private def expand_track_titles(call : Crystal::Call) : Crystal::ASTNode
      meta = load_album_metadata(call)
      elements = [] of Crystal::ASTNode
      if meta
        meta.each do |item|
          t_num = item["track_number"]?.try(&.as_i?) || 1
          t_title = item["title"]?.try(&.as_s?) || "Track"
          if md = t_title.match(/^\d+\s*[\.\-]?\s*(.+)$/)
            t_title = md[1].strip
          end
          prefix = t_num < 10 ? "0#{t_num}" : "#{t_num}"
          elements << Crystal::StringLiteral.new("#{prefix} #{t_title}")
        end
      end
      Crystal::ArrayLiteral.new(elements)
    end

    private def expand_track_durations(call : Crystal::Call) : Crystal::ASTNode
      meta = load_album_metadata(call)
      elements = [] of Crystal::ASTNode
      if meta
        meta.each do |item|
          dur_any = item["duration_seconds"]?
          dur = if dur_any
                  dur_any.as_f? || dur_any.as_i?.try(&.to_f) || 0.0
                else
                  0.0
                end
          elements << Crystal::NumberLiteral.new(sprintf("%.1f", dur), :f32)
        end
      end
      Crystal::ArrayLiteral.new(elements)
    end

    private def expand_album_title(call : Crystal::Call) : Crystal::ASTNode
      meta = load_album_metadata(call)
      first = meta ? meta.first? : nil
      album_name = first ? (first["album"]?.try(&.as_s?) || "Unknown Album") : "Unknown Album"
      Crystal::StringLiteral.new(album_name)
    end

    private def expand_album_artist(call : Crystal::Call) : Crystal::ASTNode
      meta = load_album_metadata(call)
      first = meta ? meta.first? : nil
      artist_name = first ? (first["artist"]?.try(&.as_s?) || "Unknown Artist") : "Unknown Artist"
      Crystal::StringLiteral.new(artist_name)
    end
  end
end
