require "compiler/crystal/syntax"
require "./types"

module Citrine
  class Inliner < Crystal::Transformer
    def initialize(
      @param_map : Hash(String, String),
      @self_var_name : String?,
      @yield_block : Crystal::Block,
      @target_class : ClassInfo? = nil
    )
    end

    def transform(node : Crystal::Var)
      if new_name = @param_map[node.name]?
        Crystal::Var.new(new_name)
      else
        node
      end
    end

    def transform(node : Crystal::Self)
      if sname = @self_var_name
        Crystal::Var.new(sname)
      else
        node
      end
    end

    def transform(node : Crystal::Yield)
      assigns = [] of Crystal::ASTNode
      node.exps.each_with_index do |exp, idx|
        if idx < @yield_block.args.size
          arg_name = @yield_block.args[idx].name
          assigns << Crystal::Assign.new(Crystal::Var.new(arg_name), exp.transform(self))
        end
      end

      if node.scope && node.exps.empty? && @yield_block.args.size > 0
        if sname = @self_var_name
          assigns << Crystal::Assign.new(Crystal::Var.new(@yield_block.args[0].name), Crystal::Var.new(sname))
        end
      end

      cloned_body = @yield_block.body.clone
      if assigns.empty?
        cloned_body
      else
        Crystal::Expressions.new(assigns + [cloned_body])
      end
    end
  end

  class BytecodeCompiler
    private def has_yield_node?(node : Crystal::ASTNode?) : Bool
      return false if node.nil?
      case node
      when Crystal::Yield
        true
      when Crystal::Expressions
        node.expressions.any? { |e| has_yield_node?(e) }
      when Crystal::If
        has_yield_node?(node.then) || has_yield_node?(node.else)
      when Crystal::While
        has_yield_node?(node.body)
      when Crystal::Assign
        has_yield_node?(node.value)
      when Crystal::Call
        has_yield_node?(node.obj) ||
        node.args.any? { |a| has_yield_node?(a) } ||
        (node.block ? has_yield_node?(node.block.not_nil!.body) : false)
      else
        false
      end
    end

    private def inline_block_call(
      call_node : Crystal::Call,
      def_node : Crystal::Def,
      block : Crystal::Block,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      @inline_counter += 1
      prefix = "__inl_#{@inline_counter}"

      self_var_name : String? = nil
      old_self_reg = @current_self_reg
      old_class = @current_class

      target_cls : ClassInfo? = nil
      if call_node.obj
        self_var_name = "#{prefix}_self"
        allocator.allocate_local(self_var_name)
        sreg = allocator.get_local(self_var_name).not_nil!
        obj_reg = compile_node(call_node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, sreg, obj_reg, 0_u8)
        allocator.free_temp(obj_reg)
        @current_self_reg = sreg

        cls_name = if call_node.obj.is_a?(Crystal::Var)
                     @var_types[call_node.obj.as(Crystal::Var).name]?
                   elsif call_node.obj.is_a?(Crystal::Self)
                     @current_class.try(&.name)
                   else
                     call_node.obj.to_s
                   end
        if cls_name && (target_cls = @classes[cls_name]?)
          @current_class = target_cls
        elsif @classes.has_key?(call_node.obj.to_s)
          target_cls = @classes[call_node.obj.to_s]
          @current_class = target_cls
        end
      end

      param_map = Hash(String, String).new
      real_args = def_node.args.reject { |a| a.name == "self" }
      real_args.each_with_index do |arg, idx|
        mangled = "#{prefix}_#{arg.name}"
        param_map[arg.name] = mangled
        allocator.allocate_local(mangled)
        param_reg = allocator.get_local(mangled).not_nil!
        if idx < call_node.args.size
          val_reg = compile_node(call_node.args[idx], allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, param_reg, val_reg, 0_u8)
          allocator.free_temp(val_reg)
        else
          instructions << Instruction.encode_load_nil(param_reg)
        end
      end

      inliner = Inliner.new(param_map, self_var_name, block, target_cls)
      transformed_body = def_node.body.clone.transform(inliner)

      ret_reg = compile_node(transformed_body, allocator, instructions, fn)

      @current_self_reg = old_self_reg
      @current_class = old_class
      ret_reg
    end

    private def collect_free_vars(node : Crystal::ASTNode?, outer_allocator : RegisterAllocator, bound_vars : Set(String), result : Array(String))
      return unless node
      case node
      when Crystal::Var
        name = node.name
        if outer_allocator.get_local(name) && !bound_vars.includes?(name) && !result.includes?(name)
          result << name
        end
      when Crystal::Expressions
        node.expressions.each { |e| collect_free_vars(e, outer_allocator, bound_vars, result) }
      when Crystal::Call
        if obj = node.obj
          collect_free_vars(obj, outer_allocator, bound_vars, result)
        elsif outer_allocator.get_local(node.name) && node.args.empty? && node.block.nil? && !bound_vars.includes?(node.name) && !result.includes?(node.name)
          result << node.name
        end
        node.args.each { |a| collect_free_vars(a, outer_allocator, bound_vars, result) }
        if b = node.block
          inner_bound = bound_vars.dup
          b.args.each { |ba| inner_bound.add(ba.name) }
          collect_free_vars(b.body, outer_allocator, inner_bound, result)
        end
      when Crystal::Assign
        if node.target.is_a?(Crystal::Var)
          t_name = node.target.as(Crystal::Var).name
          if outer_allocator.get_local(t_name) && !bound_vars.includes?(t_name) && !result.includes?(t_name)
            result << t_name
          end
        else
          collect_free_vars(node.target, outer_allocator, bound_vars, result)
        end
        collect_free_vars(node.value, outer_allocator, bound_vars, result)
      when Crystal::OpAssign
        collect_free_vars(node.target, outer_allocator, bound_vars, result)
        collect_free_vars(node.value, outer_allocator, bound_vars, result)
      when Crystal::If
        collect_free_vars(node.cond, outer_allocator, bound_vars, result)
        collect_free_vars(node.then, outer_allocator, bound_vars, result)
        collect_free_vars(node.else, outer_allocator, bound_vars, result)
      when Crystal::Unless
        collect_free_vars(node.cond, outer_allocator, bound_vars, result)
        collect_free_vars(node.then, outer_allocator, bound_vars, result)
        collect_free_vars(node.else, outer_allocator, bound_vars, result)
      when Crystal::While
        collect_free_vars(node.cond, outer_allocator, bound_vars, result)
        collect_free_vars(node.body, outer_allocator, bound_vars, result)
      when Crystal::Until
        collect_free_vars(node.cond, outer_allocator, bound_vars, result)
        collect_free_vars(node.body, outer_allocator, bound_vars, result)
      when Crystal::BinaryOp
        collect_free_vars(node.left, outer_allocator, bound_vars, result)
        collect_free_vars(node.right, outer_allocator, bound_vars, result)
      end
    end
  end
end
