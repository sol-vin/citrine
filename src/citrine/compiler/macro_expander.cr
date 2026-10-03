require "compiler/crystal/syntax"

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
    property current_type : TypeInfo? = nil

    def initialize
      @macros = {} of String => Crystal::Macro
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
          # Expand block and arguments
          if block = node.block
            if body = block.body
              block.body = expand(body)
            end
          end
          node.args = node.args.map { |a| expand(a) }
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
  end
end
