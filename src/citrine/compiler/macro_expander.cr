require "compiler/crystal/syntax"

module Citrine
  class MacroExpander
    getter macros : Hash(String, Crystal::Macro)

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
          else
            expanded_exprs << expand(child)
          end
        end
        Crystal::Expressions.new(expanded_exprs)

      when Crystal::Def
        if body = node.body
          node.body = expand(body)
        end
        node

      when Crystal::ClassDef
        if body = node.body
          node.body = expand(body)
        end
        node

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

    private def dump_macro_body(node : Crystal::ASTNode, arg_map : Hash(String, String), io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |child| dump_macro_body(child, arg_map, io) }
      when Crystal::MacroLiteral
        io << node.value
      when Crystal::MacroExpression
        if exp = node.exp
          if exp.is_a?(Crystal::Var) && arg_map.has_key?(exp.name)
            io << arg_map[exp.name]
          else
            io << exp.to_s
          end
        end
      when Crystal::Var
        if arg_map.has_key?(node.name)
          io << arg_map[node.name]
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
