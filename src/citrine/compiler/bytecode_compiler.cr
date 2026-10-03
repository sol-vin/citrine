require "compiler/crystal/syntax"
require "./opcode"
require "./register_alloc"
require "./source_map"
require "./budget_checker"
require "./optimizer"
require "../ast/types"
require "../parser/dsl_parser"

module Citrine
  class CompiledFunction
    property name : String
    property argc : UInt8
    property num_registers : UInt8
    property code_offset : UInt32 = 0_u32
    property instruction_count : UInt32 = 0_u32
    property instructions : Array(Instruction)

    def initialize(@name : String, @argc : UInt8 = 0_u8)
      @num_registers = @argc
      @instructions = [] of Instruction
    end
  end

  enum ConstType : UInt8
    Nil     = 0
    Bool    = 1
    Int32   = 2
    Float32 = 3
    Vec2    = 4
    Color   = 5
    String  = 6
  end

  struct ConstValue
    getter type : ConstType
    getter int_val : Int32
    getter uint_val : UInt32
    getter float_val : Float32
    getter float_val2 : Float32
    getter str_val : String

    def initialize(
      @type : ConstType,
      @int_val : Int32 = 0,
      @uint_val : UInt32 = 0_u32,
      @float_val : Float32 = 0.0_f32,
      @float_val2 : Float32 = 0.0_f32,
      @str_val : String = ""
    )
    end
  end

  class ModuleInfo
    getter module_id : UInt32
    getter name : String
    getter methods : Hash(String, Crystal::Def)

    def initialize(@module_id : UInt32, @name : String)
      @methods = Hash(String, Crystal::Def).new
    end
  end

  class ClassInfo
    getter class_id : UInt32
    getter name : String
    property superclass_name : String? = nil
    property superclass_id : UInt32? = nil
    property included_module_ids : Array(UInt32) = [] of UInt32
    property is_abstract : Bool = false
    property is_struct : Bool = false
    property abstract_methods : Set(String) = Set(String).new
    getter fields : Hash(String, Int32)
    getter methods : Hash(String, Crystal::Def)
    getter class_fields : Hash(String, Int32)
    getter class_methods : Hash(String, Crystal::Def)

    def initialize(@class_id : UInt32, @name : String)
      @fields = Hash(String, Int32).new
      @methods = Hash(String, Crystal::Def).new
      @class_fields = Hash(String, Int32).new
      @class_methods = Hash(String, Crystal::Def).new
    end

    def field_index(name : String) : Int32
      clean = name.starts_with?("@") ? name[1..-1] : name
      if idx = @fields[clean]?
        idx
      else
        idx = @fields.size
        @fields[clean] = idx
        idx
      end
    end

    def ancestor_ids(all_classes : Hash(String, ClassInfo)) : Array(UInt32)
      res = [@class_id] + @included_module_ids
      if sc_name = @superclass_name
        if sc_info = all_classes[sc_name]?
          res += sc_info.ancestor_ids(all_classes)
        end
      end
      res.uniq
    end
  end

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
          assigns << Crystal::Assign.new(Crystal::Var.new(arg_name), exp)
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
    MAGIC = "CBC1"

    getter source_map : SourceMap
    getter constants : Array(ConstValue)
    getter strings : Array(String)
    getter functions : Array(CompiledFunction)
    getter filename : String?
    property release_mode : Bool = false
    property opt_level : Int32 = 1

    getter classes : Hash(String, ClassInfo) = Hash(String, ClassInfo).new
    getter modules : Hash(String, ModuleInfo) = Hash(String, ModuleInfo).new
    getter class_prop_offsets : Hash(String, Int32) = Hash(String, Int32).new
    CLASS_PROP_BASE = 0x00300000_u32
    property current_class : ClassInfo? = nil
    property current_self_reg : UInt8? = nil
    property program_defs : Hash(String, Crystal::Def) = Hash(String, Crystal::Def).new
    property var_types : Hash(String, String) = Hash(String, String).new
    getter enums : Hash(String, Hash(String, Int64)) = Hash(String, Hash(String, Int64)).new
    property inline_counter : Int32 = 0

    def initialize(@filename : String? = nil)
      @source_map = SourceMap.new
      @constants = [] of ConstValue
      @strings = [] of String
      @functions = [] of CompiledFunction
      @release_mode = false
      @opt_level = 1
    end

    def compile(program : ParsedProgram) : Bytes
      if @release_mode
        strip_debug_nodes(program)
      end

      @program_defs = program.defs.dup
      @classes.clear
      @modules.clear
      @enums.clear
      @class_prop_offsets.clear
      @var_types.clear

      # 0. Process enums
      program.enums.each do |ename, edef|
        member_map = Hash(String, Int64).new
        curr_val = 0_i64
        edef.members.each do |m|
          if m.is_a?(Crystal::Arg)
            if def_val = m.default_value
              if def_val.is_a?(Crystal::NumberLiteral)
                clean_str = def_val.value.gsub("_", "")
                curr_val = if clean_str.starts_with?("0x") || clean_str.starts_with?("0X")
                             clean_str[2..-1].to_i64?(16) || curr_val
                           else
                             clean_str.to_i64? || curr_val
                           end
              end
            end
            member_map[m.name] = curr_val
            curr_val += 1_i64
          end
        end
        @enums[ename] = member_map
      end

      # 1. Process modules first
      program.modules.each_with_index do |(mod_name, mod_node), idx|
        mod_info = ModuleInfo.new((idx + 500).to_u32, mod_name)
        extract_module_members(mod_node, mod_name, mod_info)
        @modules[mod_name] = mod_info
      end

      # 2. Process classes and structs
      program.structs.each_with_index do |(cls_name, cls_node), idx|
        cls_info = ClassInfo.new((idx + 1).to_u32, cls_name)
        extract_class_members(cls_node, cls_info)
        @classes[cls_name] = cls_info
      end

      # 3. Inherit superclass fields and methods
      @classes.each do |cls_name, cls_info|
        if sc_name = cls_info.superclass_name
          if sc_info = @classes[sc_name]?
            cls_info.superclass_id = sc_info.class_id
            sc_info.fields.each do |f_name, f_idx|
              cls_info.fields[f_name] ||= f_idx
            end
            sc_info.methods.each do |m_name, m_def|
              unless cls_info.methods.has_key?(m_name)
                cls_info.methods[m_name] = m_def
                fn_name = "#{cls_name}##{m_name}"
                @program_defs[fn_name] ||= m_def
              end
            end
          end
        end
      end

      # 4. Pre-register all function signatures in @functions so recursive and forward calls resolve
      @program_defs.each do |name, def_node|
        arg_names = def_node.args.map(&.name)
        @functions << CompiledFunction.new(name, arg_names.size.to_u8)
      end

      # 5. Compile helper functions / methods
      @program_defs.each do |name, def_node|
        compile_function(def_node, name)
      end

      # 6. Compile main function
      main_fn = CompiledFunction.new("__main__", 0_u8)
      allocator = RegisterAllocator.new
      fn_instructions = [] of Instruction

      # Compile top level nodes
      program.top_level_nodes.each do |node|
        compile_node(node, allocator, fn_instructions, main_fn)
      end

      # Return at end of main
      ret_reg = allocator.alloc_temp
      fn_instructions << Instruction.encode_abc(Opcode::LoadNil, ret_reg, 0_u8, 0_u8)
      fn_instructions << Instruction.encode_ab_imm(Opcode::Return, ret_reg, 0_u16)
      main_fn.num_registers = allocator.max_registers
      main_fn.instructions = fn_instructions
      @functions << main_fn

      # 7. Run Bytecode Optimizer Passes
      effective_opt_level = @release_mode ? 2 : @opt_level
      if effective_opt_level > 0
        optimizer = BytecodeOptimizer.new(@constants, effective_opt_level)
        @functions.each do |fn|
          fn.instructions = optimizer.optimize(fn.instructions)
        end
      end

      # 8. Assemble binary bytecode (.cbc)
      serialize_bytecode
    end

    private def extract_class_members(cls_node : Crystal::ClassDef, cls_info : ClassInfo)
      cls_info.is_abstract = cls_node.abstract?
      cls_info.is_struct = cls_node.struct?
      if sc = cls_node.superclass
        cls_info.superclass_name = sc.to_s
      end

      body = cls_node.body
      nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
      nodes.each do |raw_child|
        child = raw_child
        while child.is_a?(Crystal::VisibilityModifier)
          child = child.exp
        end

        case child
        when Crystal::Include
          mod_name = child.name.to_s
          if mod_info = @modules[mod_name]?
            cls_info.included_module_ids << mod_info.module_id
            mod_info.methods.each do |m_name, m_def|
              cls_info.methods[m_name] = m_def
              fn_name = "#{cls_info.name}##{m_name}"
              args = [Crystal::Arg.new("self")] + m_def.args.reject { |a| a.name == "self" }
              new_def = Crystal::Def.new(fn_name, args, m_def.body)
              @program_defs[fn_name] = new_def
            end
          end

        when Crystal::Extend
          mod_name = child.name.to_s
          if mod_info = @modules[mod_name]?
            mod_info.methods.each do |m_name, m_def|
              cls_info.class_methods[m_name] = m_def
              fn_name = "#{cls_info.name}.#{m_name}"
              new_def = Crystal::Def.new(fn_name, m_def.args, m_def.body)
              @program_defs[fn_name] = new_def
              @program_defs["#{cls_info.name}::#{m_name}"] = new_def
            end
          end

        when Crystal::Def
          if child.abstract?
            cls_info.abstract_methods << child.name
          elsif child.receiver
            cls_info.class_methods[child.name] = child
            fn_name = "#{cls_info.name}.#{child.name}"
            new_def = Crystal::Def.new(fn_name, child.args, child.body)
            @program_defs[fn_name] = new_def
            @program_defs["#{cls_info.name}::#{child.name}"] = new_def
          else
            cls_info.methods[child.name] = child
            init_assigns = [] of Crystal::ASTNode
            child.args.each do |arg|
              clean_name = arg.name.gsub(/^@/, "")
              ivar_name = "@#{clean_name}"
              if child.name == "initialize" || arg.name.starts_with?("@") || cls_info.fields.has_key?(ivar_name) || cls_info.fields.has_key?(clean_name)
                cls_info.field_index(ivar_name)
                init_assigns << Crystal::Assign.new(Crystal::InstanceVar.new(ivar_name), Crystal::Var.new(clean_name))
              end
            end
            fn_name = "#{cls_info.name}##{child.name}"
            converted_args = child.args.map do |arg|
              Crystal::Arg.new(arg.name.gsub(/^@/, ""))
            end
            args = [Crystal::Arg.new("self")] + converted_args
            full_body = if init_assigns.empty?
                          child.body
                        elsif child.body.nil? || child.body.is_a?(Crystal::Nop)
                          Crystal::Expressions.new(init_assigns)
                        else
                          existing_nodes = child.body.is_a?(Crystal::Expressions) ? child.body.as(Crystal::Expressions).expressions : [child.body]
                          Crystal::Expressions.new(init_assigns + existing_nodes)
                        end
            new_def = Crystal::Def.new(fn_name, args, full_body)
            @program_defs[fn_name] = new_def
          end

        when Crystal::Call
          if (child.name == "include" || child.name == "extend") && child.args.size > 0
            mod_name = child.args[0].to_s
            if mod_info = @modules[mod_name]?
              if child.name == "include"
                cls_info.included_module_ids << mod_info.module_id
                mod_info.methods.each do |m_name, m_def|
                  cls_info.methods[m_name] = m_def
                  fn_name = "#{cls_info.name}##{m_name}"
                  args = [Crystal::Arg.new("self")] + m_def.args.reject { |a| a.name == "self" }
                  new_def = Crystal::Def.new(fn_name, args, m_def.body)
                  @program_defs[fn_name] = new_def
                end
              else
                mod_info.methods.each do |m_name, m_def|
                  cls_info.class_methods[m_name] = m_def
                  fn_name = "#{cls_info.name}.#{m_name}"
                  new_def = Crystal::Def.new(fn_name, m_def.args, m_def.body)
                  @program_defs[fn_name] = new_def
                  @program_defs["#{cls_info.name}::#{m_name}"] = new_def
                end
              end
            end
          elsif ["property", "getter", "setter"].includes?(child.name) && child.args.size > 0
            prop_arg = child.args[0]
            prop_name = if prop_arg.is_a?(Crystal::TypeDeclaration)
                          prop_arg.var.to_s
                        else
                          prop_arg.to_s
                        end
            cls_info.field_index(prop_name)
            if child.name == "property" || child.name == "getter"
              getter_name = "#{cls_info.name}##{prop_name}"
              getter_def = Crystal::Def.new(getter_name, [Crystal::Arg.new("self")], Crystal::InstanceVar.new("@#{prop_name}"))
              @program_defs[getter_name] = getter_def
              cls_info.methods[prop_name] = getter_def
            end

            if child.name == "property" || child.name == "setter"
              setter_name = "#{cls_info.name}##{prop_name}="
              assign = Crystal::Assign.new(Crystal::InstanceVar.new("@#{prop_name}"), Crystal::Var.new("val"))
              setter_def = Crystal::Def.new(setter_name, [Crystal::Arg.new("self"), Crystal::Arg.new("val")], assign)
              @program_defs[setter_name] = setter_def
              cls_info.methods["#{prop_name}="] = setter_def
            end
          elsif ["class_property", "class_getter", "class_setter"].includes?(child.name) && child.args.size > 0
            prop_arg = child.args[0]
            prop_name = if prop_arg.is_a?(Crystal::TypeDeclaration)
                          prop_arg.var.to_s
                        else
                          prop_arg.to_s
                        end
            cls_info.class_fields[prop_name] = cls_info.class_fields.size
            prop_key = "#{cls_info.name}::#{prop_name}"
            @class_prop_offsets[prop_key] ||= @class_prop_offsets.size
          end

        when Crystal::Assign
          if child.target.is_a?(Crystal::InstanceVar)
            cls_info.field_index(child.target.to_s)
          end
        end
      end
    end

    private def extract_module_members(mod_node : Crystal::ModuleDef, mod_name : String, mod_info : ModuleInfo? = nil)
      body = mod_node.body
      nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
      nodes.each do |child|
        if child.is_a?(Crystal::Def)
          fn_name = "#{mod_name}.#{child.name}"
          @program_defs[fn_name] = child
          @program_defs["#{mod_name}::#{child.name}"] = child
          mod_info.try { |m| m.methods[child.name] = child }
        end
      end
    end

    private def compile_function(node : Crystal::Def, registered_name : String = node.name)
      fn = @functions.find { |f| f.name == registered_name }
      unless fn
        fn = CompiledFunction.new(registered_name, node.args.size.to_u8)
        @functions << fn
      end

      arg_names = node.args.map(&.name)
      allocator = RegisterAllocator.new(arg_names)
      instructions = [] of Instruction

      arg_names.each_with_index do |name, idx|
        @source_map.record_register(registered_name, idx, name)
      end

      old_class = @current_class
      old_self = @current_self_reg
      if registered_name.includes?("#")
        parts = registered_name.split("#")
        @current_class = @classes[parts[0]]?
        @current_self_reg = 0_u8
      end

      # Compile function body
      ret_reg = compile_node(node.body, allocator, instructions, fn)
      unless instructions.last?.try(&.opcode) == Opcode::Return
        instructions << Instruction.encode_ab_imm(Opcode::Return, ret_reg, 0_u16)
      end

      @current_class = old_class
      @current_self_reg = old_self

      fn.num_registers = allocator.max_registers
      fn.instructions = instructions
    end


    private def compile_main_loop(
      body : Crystal::ASTNode,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      loop_start_offset = instructions.size

      # Check window_open?
      cond_reg = allocator.alloc_temp
      native_id = NativeId::WindowOpen.value
      instructions << Instruction.encode_ab_imm(Opcode::CallNative, cond_reg, native_id)

      # Branch if false to exit
      jump_exit_idx = instructions.size
      instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

      # Body
      body_reg = compile_node(body, allocator, instructions, fn)
      allocator.free_temp(body_reg)

      # Loop back
      loop_end_offset = instructions.size
      back_offset = (loop_start_offset - loop_end_offset - 1).to_i16
      instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

      # Patch exit jump
      exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
      instructions[jump_exit_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)
      allocator.free_temp(cond_reg)

      ret_reg = allocator.alloc_temp
      instructions << Instruction.encode_abc(Opcode::LoadNil, ret_reg, 0_u8, 0_u8)
      ret_reg
    end

    private def compile_node(
      node : Crystal::ASTNode,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      record_location(node, instructions.size, fn.name)

      case node
      when Crystal::Expressions
        last_reg = 0_u8
        node.expressions.each_with_index do |child, idx|
          reg = compile_node(child, allocator, instructions, fn)
          if idx == node.expressions.size - 1
            last_reg = reg
          else
            allocator.free_temp(reg)
          end
        end
        last_reg

      when Crystal::Assign
        if node.target.is_a?(Crystal::InstanceVar) && (cls = @current_class) && (self_reg = @current_self_reg)
          val_reg = compile_node(node.value, allocator, instructions, fn)
          f_idx = cls.field_index(node.target.to_s)
          f_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, f_reg, f_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, self_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, f_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          ret_dest = allocator.alloc_temp
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (ret_dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::ObjectSetField.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(f_reg)
          allocator.free_temp(val_reg)
          3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
          return ret_dest
        end

        if node.target.is_a?(Crystal::ClassVar)
          val_reg = compile_node(node.value, allocator, instructions, fn)
          cvar_name = node.target.to_s
          scope = @current_class.try(&.name) || fn.name.split("#").first.split(".").first
          prop_key = "#{scope}::#{cvar_name}"
          prop_offset = @class_prop_offsets[prop_key] ||= @class_prop_offsets.size
          addr_val = CLASS_PROP_BASE + (prop_offset.to_u32 * 4)
          addr_reg = allocator.alloc_temp
          idx_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (val_reg.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::PointerSet.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
          return val_reg
        end

        target_name = node.target.to_s
        val_type : String? = nil
        if node.value.is_a?(Crystal::Call)
          call_node = node.value.as(Crystal::Call)
          if (call_node.name == "new" || call_node.name == "malloc") && (recv = call_node.obj)
            val_type = recv.to_s
          elsif call_node.name == "to_s"
            val_type = "String"
          end
        elsif node.value.is_a?(Crystal::Var)
          val_type = @var_types[node.value.as(Crystal::Var).name]?
        elsif node.value.is_a?(Crystal::Path)
          path_node = node.value.as(Crystal::Path)
          if path_node.names.size >= 2
            val_type = path_node.names[0...-1].join("::")
          end
        elsif node.value.is_a?(Crystal::StringLiteral) || node.value.is_a?(Crystal::StringInterpolation)
          val_type = "String"
        elsif node.value.is_a?(Crystal::BoolLiteral)
          val_type = "Bool"
        elsif node.value.is_a?(Crystal::NumberLiteral)
          val_type = "Int"
        end
        if val_type
          @var_types[target_name] = val_type
        end

        val_reg = compile_node(node.value, allocator, instructions, fn)
        local_reg = allocator.allocate_local(target_name)

        if val_type && @classes[val_type]?.try(&.is_struct) && node.value.is_a?(Crystal::Var)
          seq_base = allocator.alloc_contiguous(1)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, val_reg, 0_u8)
          copy_dest = allocator.alloc_temp
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (copy_dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::StructCopy.value.to_u32
          instructions << Instruction.new(instr_val)
          instructions << Instruction.encode_abc(Opcode::Move, local_reg, copy_dest, 0_u8)
          allocator.free_temp(seq_base)
          allocator.free_temp(copy_dest)
        else
          instructions << Instruction.encode_abc(Opcode::Move, local_reg, val_reg, 0_u8)
        end
        @source_map.record_register(fn.name, local_reg.to_i32, target_name)
        allocator.free_temp(val_reg)
        local_reg

      when Crystal::OpAssign
        call = Crystal::Call.new(node.target, node.op, node.value)
        assign = Crystal::Assign.new(node.target, call)
        compile_node(assign, allocator, instructions, fn)


      when Crystal::Var
        name = node.name
        if reg = allocator.get_local(name)
          reg
        else
          # Unknown local, allocate
          reg = allocator.allocate_local(name)
          instructions << Instruction.encode_abc(Opcode::LoadNil, reg, 0_u8, 0_u8)
          reg
        end

      when Crystal::NumberLiteral
        dest = allocator.alloc_temp
        if node.kind == :i32 || node.kind == :i64 || node.kind == :u32 || node.kind == :u64 || node.value.includes?(".") == false
          clean_str = node.value.gsub("_", "")
          v64 = if clean_str.starts_with?("0x") || clean_str.starts_with?("0X")
                  clean_str[2..-1].to_u64?(16).try(&.to_i64!) || 0_i64
                else
                  clean_str.to_i64? || clean_str.to_u64?.try(&.to_i64!) || 0_i64
                end
          if v64 >= -32768 && v64 <= 32767
            instructions << Instruction.encode_ab_imm(Opcode::LoadInt, dest, v64.to_u16!)
          else
            const_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: v64.to_i32!, uint_val: v64.to_u32!))
            instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
          end
        else
          fval = node.value.to_f32
          const_idx = add_constant(ConstValue.new(ConstType::Float32, float_val: fval))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        end
        dest

      when Crystal::StringLiteral
        dest = allocator.alloc_temp
        str_idx = add_string(node.value)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: node.value))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        dest

      when Crystal::StringInterpolation
        compile_string_interpolation(node, allocator, instructions, fn)

      when Crystal::BoolLiteral
        dest = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadBool, dest, node.value ? 1_u16 : 0_u16)
        dest

      when Crystal::NilLiteral
        dest = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        dest

      when Crystal::And
        dest = allocator.alloc_temp
        left_reg = compile_node(node.left, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, left_reg, 0_u8)
        jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, dest, 0_i16)
        right_reg = compile_node(node.right, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, right_reg, 0_u8)
        offset = (instructions.size - jump_idx - 1).to_i16
        instructions[jump_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, dest, offset)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        dest

      when Crystal::Or
        dest = allocator.alloc_temp
        left_reg = compile_node(node.left, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, left_reg, 0_u8)
        jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfTrue, dest, 0_i16)
        right_reg = compile_node(node.right, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, right_reg, 0_u8)
        offset = (instructions.size - jump_idx - 1).to_i16
        instructions[jump_idx] = Instruction.encode_branch(Opcode::JumpIfTrue, dest, offset)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        dest

      when Crystal::Not
        dest = allocator.alloc_temp
        inner_reg = compile_node(node.exp, allocator, instructions, fn)
        # Not: if true -> false, if false -> true
        # Compare with false/nil
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadBool, false_reg, 0_u16)
        instructions << Instruction.encode_abc(Opcode::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        dest

      when Crystal::If
        dest = allocator.alloc_temp
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_else_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        # Then branch
        then_reg = compile_node(node.then, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, then_reg, 0_u8)
        allocator.free_temp(then_reg)
        jump_end_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

        # Patch else
        else_target_offset = (instructions.size - jump_else_idx - 1).to_i16
        instructions[jump_else_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, else_target_offset)

        # Else branch
        if node.else && !node.else.is_a?(Crystal::Nop)
          else_reg = compile_node(node.else, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, else_reg, 0_u8)
          allocator.free_temp(else_reg)
        end

        # Patch end
        end_offset = (instructions.size - jump_end_idx - 1).to_i16
        instructions[jump_end_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, end_offset)

        allocator.free_temp(cond_reg)
        dest

      when Crystal::While
        dest = allocator.alloc_temp
        loop_start = instructions.size
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_exit_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        compile_node(node.body, allocator, instructions, fn)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
        instructions[jump_exit_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)

        allocator.free_temp(cond_reg)
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        dest

      when Crystal::Call
        compile_call(node, allocator, instructions, fn)

      when Crystal::Path
        # Constant reference e.g. Button::Cross, Color::Red, Direction::North
        dest = allocator.alloc_temp
        val = resolve_constant_path(node)
        if val.type == ConstType::Int32 && val.int_val >= -32768 && val.int_val <= 32767
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, dest, val.int_val.to_u16!)
        else
          const_idx = add_constant(val)
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, const_idx.to_u16)
        end
        dest

      when Crystal::Return
        ret_val = node.exp
        ret_reg = if ret_val
                    compile_node(ret_val, allocator, instructions, fn)
                  else
                    r = allocator.alloc_temp
                    instructions << Instruction.encode_abc(Opcode::LoadNil, r, 0_u8, 0_u8)
                    r
                  end
        instructions << Instruction.encode_ab_imm(Opcode::Return, ret_reg, 0_u16)
        ret_reg

      when Crystal::InstanceVar
        dest = allocator.alloc_temp
        if (cls = @current_class) && (self_reg = @current_self_reg)
          f_idx = cls.field_index(node.name)
          f_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, f_reg, f_idx.to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, self_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, f_reg, 0_u8)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::ObjectGetField.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(f_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
        else
          instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        end
        dest

      when Crystal::ClassVar
        dest = allocator.alloc_temp
        cvar_name = node.name
        scope = @current_class.try(&.name) || fn.name.split("#").first.split(".").first
        prop_key = "#{scope}::#{cvar_name}"
        prop_offset = @class_prop_offsets[prop_key] ||= @class_prop_offsets.size
        addr_val = CLASS_PROP_BASE + (prop_offset.to_u32 * 4)
        addr_reg = allocator.alloc_temp
        idx_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, idx_reg, 0_u16)
        c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::PointerGet.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(addr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        dest

      when Crystal::Self
        dest = allocator.alloc_temp
        if self_reg = @current_self_reg
          instructions << Instruction.encode_abc(Opcode::Move, dest, self_reg, 0_u8)
        else
          instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        end
        dest

      when Crystal::ArrayLiteral
        dest = allocator.alloc_temp
        cap = node.elements.size > 0 ? node.elements.size : 4
        cap_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, cap_reg, cap.to_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (cap_reg.to_u32 << 8) |
                    NativeId::ArrayNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(cap_reg)

        node.elements.each do |elem|
          elem_reg = compile_node(elem, allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, dest, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, elem_reg, 0_u8)
          push_val = (Opcode::CallNative.value.to_u32 << 24) |
                     (dest.to_u32 << 16) |
                     (seq_base.to_u32 << 8) |
                     NativeId::ArrayPush.value.to_u32
          instructions << Instruction.new(push_val)
          allocator.free_temp(elem_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
        end
        dest

      when Crystal::IsA
        dest = allocator.alloc_temp
        obj_reg = compile_node(node.obj, allocator, instructions, fn)

        target_types = [] of String
        case const_node = node.const
        when Crystal::Union
          const_node.types.each { |t| target_types << t.to_s }
        else
          target_types << const_node.to_s
        end

        target_ids = [] of UInt32
        target_types.each do |tname|
          if tid = resolve_type_id(tname)
            matching = @classes.values.select { |c| c.ancestor_ids(@classes).includes?(tid) }.map(&.class_id)
            if matching.empty?
              target_ids << tid
            else
              target_ids.concat(matching)
            end
          end
        end
        target_ids.uniq!

        if target_ids.empty?
          instructions << Instruction.encode_ab_imm(Opcode::LoadBool, dest, 0_u16)
        elsif target_ids.size == 1
          tid_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, tid_reg, target_ids[0].to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::TypeIsA.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(tid_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
        else
          match_dest = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadBool, match_dest, 0_u16)
          jump_end_indices = [] of Int32

          target_ids.each do |tid|
            tid_reg = allocator.alloc_temp
            instructions << Instruction.encode_ab_imm(Opcode::LoadInt, tid_reg, tid.to_u16)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
            cur_check = allocator.alloc_temp
            instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                        (cur_check.to_u32 << 16) |
                        (seq_base.to_u32 << 8) |
                        NativeId::TypeIsA.value.to_u32
            instructions << Instruction.new(instr_val)
            allocator.free_temp(tid_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)

            j_next = instructions.size
            instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cur_check, 0_i16)
            instructions << Instruction.encode_ab_imm(Opcode::LoadBool, match_dest, 1_u16)
            j_end = instructions.size
            instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
            jump_end_indices << j_end
            instructions[j_next] = Instruction.encode_branch(Opcode::JumpIfFalse, cur_check, (instructions.size - j_next - 1).to_i16)
            allocator.free_temp(cur_check)
          end

          end_pos = instructions.size
          jump_end_indices.each do |j_end|
            instructions[j_end] = Instruction.encode_branch(Opcode::Jump, 0_u8, (end_pos - j_end - 1).to_i16)
          end
          instructions << Instruction.encode_abc(Opcode::Move, dest, match_dest, 0_u8)
          allocator.free_temp(match_dest)
        end
        allocator.free_temp(obj_reg)
        dest

      when Crystal::Cast
        dest = allocator.alloc_temp
        obj_reg = compile_node(node.obj, allocator, instructions, fn)
        target_name = node.to.to_s
        target_id = resolve_type_id(target_name) || 0_u32
        tid_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, tid_reg, target_id.to_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::TypeAsCast.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(obj_reg)
        allocator.free_temp(tid_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        dest

      when Crystal::RegexLiteral
        dest = allocator.alloc_temp
        pat_str = node.value.is_a?(Crystal::StringLiteral) ? node.value.as(Crystal::StringLiteral).value : node.value.to_s
        str_idx = add_string(pat_str)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: pat_str))
        pat_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, pat_reg, const_idx.to_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (pat_reg.to_u32 << 8) |
                    NativeId::RegexNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(pat_reg)
        dest

      when Crystal::Case
        compile_case(node, allocator, instructions, fn)

      else
        dest = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        dest
      end
    end

    private def compile_case(
      node : Crystal::Case,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      exit_jumps = [] of Int32

      if cond = node.cond
        cond_reg = compile_node(cond, allocator, instructions, fn)

        node.whens.each do |w|
          body_jump_patches = [] of Int32
          next_when_jump_patches = [] of Int32

          w.conds.each_with_index do |c, c_idx|
            is_last_cond = (c_idx == w.conds.size - 1)

            case c
            when Crystal::RangeLiteral
              from_reg = compile_node(c.from, allocator, instructions, fn)
              to_reg = compile_node(c.to, allocator, instructions, fn)

              ge_reg = allocator.alloc_temp
              instructions << Instruction.encode_abc(Opcode::Ge, ge_reg, cond_reg, from_reg)

              le_reg = allocator.alloc_temp
              if c.exclusive?
                instructions << Instruction.encode_abc(Opcode::Lt, le_reg, cond_reg, to_reg)
              else
                instructions << Instruction.encode_abc(Opcode::Le, le_reg, cond_reg, to_reg)
              end

              range_match = allocator.alloc_temp
              instructions << Instruction.encode_abc(Opcode::BitAnd, range_match, ge_reg, le_reg)
              allocator.free_temp(from_reg)
              allocator.free_temp(to_reg)
              allocator.free_temp(ge_reg)
              allocator.free_temp(le_reg)

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_branch(Opcode::JumpIfFalse, range_match, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_branch(Opcode::JumpIfTrue, range_match, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(range_match)

            when Crystal::Path, Crystal::Generic, Crystal::Union
              target_types = [] of String
              if c.is_a?(Crystal::Union)
                c.types.each { |t| target_types << t.to_s }
              else
                target_types << c.to_s
              end
              target_ids = [] of UInt32
              target_types.each do |tname|
                if tid = resolve_type_id(tname)
                  matching = @classes.values.select { |cl| cl.ancestor_ids(@classes).includes?(tid) }.map(&.class_id)
                  if matching.empty?
                    target_ids << tid
                  else
                    target_ids.concat(matching)
                  end
                end
              end
              target_ids.uniq!

              type_match = allocator.alloc_temp
              if target_ids.empty?
                instructions << Instruction.encode_ab_imm(Opcode::LoadBool, type_match, 0_u16)
              elsif target_ids.size == 1
                tid_reg = allocator.alloc_temp
                instructions << Instruction.encode_ab_imm(Opcode::LoadInt, tid_reg, target_ids[0].to_u16)
                seq_base = allocator.alloc_contiguous(2)
                instructions << Instruction.encode_abc(Opcode::Move, seq_base, cond_reg, 0_u8)
                instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
                instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                            (type_match.to_u32 << 16) |
                            (seq_base.to_u32 << 8) |
                            NativeId::TypeIsA.value.to_u32
                instructions << Instruction.new(instr_val)
                allocator.free_temp(tid_reg)
                allocator.free_temp(seq_base)
                allocator.free_temp((seq_base + 1).to_u8)
              else
                instructions << Instruction.encode_ab_imm(Opcode::LoadBool, type_match, 0_u16)
                tid_jump_ends = [] of Int32
                target_ids.each do |tid|
                  tid_reg = allocator.alloc_temp
                  instructions << Instruction.encode_ab_imm(Opcode::LoadInt, tid_reg, tid.to_u16)
                  seq_base = allocator.alloc_contiguous(2)
                  instructions << Instruction.encode_abc(Opcode::Move, seq_base, cond_reg, 0_u8)
                  instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
                  cur_check = allocator.alloc_temp
                  instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                              (cur_check.to_u32 << 16) |
                              (seq_base.to_u32 << 8) |
                              NativeId::TypeIsA.value.to_u32
                  instructions << Instruction.new(instr_val)
                  allocator.free_temp(tid_reg)
                  allocator.free_temp(seq_base)
                  allocator.free_temp((seq_base + 1).to_u8)

                  j_next = instructions.size
                  instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cur_check, 0_i16)
                  instructions << Instruction.encode_ab_imm(Opcode::LoadBool, type_match, 1_u16)
                  j_done = instructions.size
                  instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
                  tid_jump_ends << j_done
                  instructions[j_next] = Instruction.encode_branch(Opcode::JumpIfFalse, cur_check, (instructions.size - j_next - 1).to_i16)
                  allocator.free_temp(cur_check)
                end
                tid_end_pos = instructions.size
                tid_jump_ends.each do |tje|
                  instructions[tje] = Instruction.encode_branch(Opcode::Jump, 0_u8, (tid_end_pos - tje - 1).to_i16)
                end
              end

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_branch(Opcode::JumpIfFalse, type_match, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_branch(Opcode::JumpIfTrue, type_match, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(type_match)

            else
              val_reg = compile_node(c, allocator, instructions, fn)
              eq_reg = allocator.alloc_temp
              instructions << Instruction.encode_abc(Opcode::Eq, eq_reg, cond_reg, val_reg)
              allocator.free_temp(val_reg)

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_branch(Opcode::JumpIfFalse, eq_reg, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_branch(Opcode::JumpIfTrue, eq_reg, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(eq_reg)
            end
          end

          cur_pos = instructions.size
          body_jump_patches.each do |bp|
            instructions[bp] = Instruction.encode_branch(Opcode::JumpIfTrue, instructions[bp].dst, (cur_pos - bp - 1).to_i16)
          end

          body_reg = compile_node(w.body, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, body_reg, 0_u8)
          allocator.free_temp(body_reg)

          j_exit = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
          exit_jumps << j_exit

          after_pos = instructions.size
          next_when_jump_patches.each do |np|
            instructions[np] = Instruction.encode_branch(Opcode::JumpIfFalse, instructions[np].dst, (after_pos - np - 1).to_i16)
          end
        end

        allocator.free_temp(cond_reg)
      else
        # Condition-less case
        node.whens.each do |w|
          body_jump_patches = [] of Int32
          next_when_jump_patches = [] of Int32

          w.conds.each_with_index do |c, c_idx|
            is_last = (c_idx == w.conds.size - 1)
            cond_res = compile_node(c, allocator, instructions, fn)
            if is_last
              j = instructions.size
              instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_res, 0_i16)
              next_when_jump_patches << j
            else
              j = instructions.size
              instructions << Instruction.encode_branch(Opcode::JumpIfTrue, cond_res, 0_i16)
              body_jump_patches << j
            end
            allocator.free_temp(cond_res)
          end

          cur_pos = instructions.size
          body_jump_patches.each do |bp|
            instructions[bp] = Instruction.encode_branch(Opcode::JumpIfTrue, instructions[bp].dst, (cur_pos - bp - 1).to_i16)
          end

          body_reg = compile_node(w.body, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, body_reg, 0_u8)
          allocator.free_temp(body_reg)

          j_exit = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
          exit_jumps << j_exit

          after_pos = instructions.size
          next_when_jump_patches.each do |np|
            instructions[np] = Instruction.encode_branch(Opcode::JumpIfFalse, instructions[np].dst, (after_pos - np - 1).to_i16)
          end
        end
      end

      if el = node.else
        if !el.is_a?(Crystal::Nop)
          el_reg = compile_node(el, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, el_reg, 0_u8)
          allocator.free_temp(el_reg)
        else
          instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        end
      else
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
      end

      end_pos = instructions.size
      exit_jumps.each do |ej|
        instructions[ej] = Instruction.encode_branch(Opcode::Jump, 0_u8, (end_pos - ej - 1).to_i16)
      end

      dest
    end

    private def compile_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      obj_str = node.obj ? node.obj.to_s : ""
      # Binary and Unary Operators
      is_collection_push = obj_str.downcase.includes?("arr") || obj_str.downcase.includes?("list") ||
                           obj_str.downcase.includes?("io") || obj_str.downcase.includes?("buf") ||
                           node.obj.is_a?(Crystal::ArrayLiteral) || node.args.first?.is_a?(Crystal::StringLiteral)

      if ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "&*", "&+", "&-"].includes?(node.name) && node.obj && node.args.size == 1 && !(node.name == "<<" && is_collection_push)
        is_string_add = (node.name == "+") && (
          node.obj.is_a?(Crystal::StringLiteral) || node.obj.is_a?(Crystal::StringInterpolation) ||
          node.args[0].is_a?(Crystal::StringLiteral) || node.args[0].is_a?(Crystal::StringInterpolation) ||
          (node.obj.is_a?(Crystal::Var) && @var_types[node.obj.as(Crystal::Var).name]? == "String") ||
          (node.args[0].is_a?(Crystal::Var) && @var_types[node.args[0].as(Crystal::Var).name]? == "String") ||
          (node.obj.is_a?(Crystal::Call) && node.obj.as(Crystal::Call).name == "to_s") ||
          (node.args[0].is_a?(Crystal::Call) && node.args[0].as(Crystal::Call).name == "to_s")
        )
        if is_string_add
          left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          right_reg = compile_node(node.args[0], allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, left_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, right_reg, 0_u8)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::StringConcat.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(left_reg)
          allocator.free_temp(right_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
          return dest
        end

        left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        right_reg = compile_node(node.args[0], allocator, instructions, fn)
        op = case node.name
             when "+" then Opcode::Add
             when "&+" then Opcode::Add
             when "-" then Opcode::Sub
             when "&-" then Opcode::Sub
             when "*" then Opcode::Mul
             when "&*" then Opcode::Mul
             when "/" then Opcode::Div
             when "%" then Opcode::Mod
             when "&" then Opcode::BitAnd
             when "|" then Opcode::BitOr
             when "^" then Opcode::BitXor
             when "<<" then Opcode::ShiftLeft
             when ">>" then Opcode::ShiftRight
             when "==" then Opcode::Eq
             when "!=" then Opcode::Ne
             when "<" then Opcode::Lt
             when "<=" then Opcode::Le
             when ">" then Opcode::Gt
             when ">=" then Opcode::Ge
             else Opcode::Add
             end
        instructions << Instruction.encode_abc(op, dest, left_reg, right_reg)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        return dest
      elsif node.name == "!" && node.obj
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadBool, false_reg, 0_u16)
        instructions << Instruction.encode_abc(Opcode::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        return dest
      elsif node.name == "-" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Neg, dest, inner_reg, 0_u8)
        allocator.free_temp(inner_reg)
        return dest
      elsif node.name == "~" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::BitNot, dest, inner_reg, 0_u8)
        allocator.free_temp(inner_reg)
        return dest
      end

      # Number conversions: .to_i, .to_i32, .to_i64, .to_u8, .to_u16, .to_u32, .to_u64, .to_f, .to_f32, .to_f64
      if ["to_i", "to_i32", "to_i64", "to_u8", "to_u16", "to_u32", "to_u64", "to_f", "to_f32", "to_f64"].includes?(node.name) && node.obj && node.args.empty?
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
        allocator.free_temp(obj_reg)
        return dest
      end

      # Main loop
      if node.name == "main_loop" && (obj_str.empty? || obj_str == "Citrine") && node.block
        loop_ret = compile_main_loop(node.block.not_nil!.body, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, loop_ret, 0_u8)
        allocator.free_temp(loop_ret)
        return dest
      end

      # Concurrency: spawn
      if (node.name == "spawn" || ((obj_str == "Citrine" || obj_str == "Fiber") && node.name == "spawn")) && node.block
        return compile_spawn(node, allocator, instructions, fn)
      end

      # Concurrency: yield
      if node.name == "yield" && (obj_str.empty? || obj_str == "Citrine" || obj_str == "Fiber")
        instructions << Instruction.encode_abc(Opcode::Yield, 0_u8, 0_u8, 0_u8)
        return dest
      end

      # Concurrency: Channel.new(cap)
      if (obj_str.includes?("Channel") || node.name == "channel_new") && (node.name == "new" || node.name == "channel_new")
        cap_reg = if node.args.size > 0
                    compile_node(node.args[0], allocator, instructions, fn)
                  else
                    r = allocator.alloc_temp
                    instructions << Instruction.encode_ab_imm(Opcode::LoadInt, r, 32_u16)
                    r
                  end
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (cap_reg.to_u32 << 8) |
                    NativeId::ChannelNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(cap_reg)
        return dest
      end

      # Concurrency: ch.send(val)
      if node.name == "send" && node.obj && node.args.size == 1
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        arg0 = allocator.alloc_temp
        arg1 = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, arg0, ch_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, arg1, val_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (arg0.to_u32 << 8) |
                    NativeId::ChannelSend.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        allocator.free_temp(val_reg)
        allocator.free_temp(arg0)
        allocator.free_temp(arg1)
        return dest
      end

      # Concurrency: ch.receive
      if node.name == "receive" && node.obj
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ch_reg.to_u32 << 8) |
                    NativeId::ChannelReceive.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.try_receive
      if node.name == "try_receive" && node.obj
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ch_reg.to_u32 << 8) |
                    NativeId::ChannelTryReceive.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.size / ch.count
      is_chan = obj_str.downcase.includes?("chan") || node.name == "count"
      if is_chan && node.obj && (node.name == "size" || node.name == "count") && node.args.empty?
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ch_reg.to_u32 << 8) |
                    NativeId::ChannelCount.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.capacity
      if node.name == "capacity" && node.obj && node.args.empty?
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ch_reg.to_u32 << 8) |
                    NativeId::ChannelCapacity.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Native API Calls (Citrine.draw_rectangle, GL.begin, etc.)
      is_gl_obj = obj_str == "Citrine::GL" || obj_str == "GL"
      if obj_str == "Citrine" || obj_str.empty? || is_gl_obj
        if native_id = map_native_call(node.name, is_gl_obj)
          if @release_mode && (native_id == NativeId::Log || native_id == NativeId::DebugLog || native_id == NativeId::SetDebugOverlay)
            instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
            return dest
          end

          # Compile args into sequential registers
          arg_regs = node.args.map { |a| compile_node(a, allocator, instructions, fn) }
          base_reg = if arg_regs.empty?
                       0_u8
                     elsif arg_regs.size == 1
                       arg_regs[0]
                     elsif (0...arg_regs.size - 1).all? { |i| arg_regs[i + 1] == arg_regs[i] + 1 }
                       arg_regs[0]
                     else
                       seq_base = allocator.alloc_contiguous(arg_regs.size)
                       arg_regs.each_with_index do |src, i|
                         dst = (seq_base + i).to_u8
                         instructions << Instruction.encode_abc(Opcode::Move, dst, src, 0_u8)
                       end
                       seq_base
                     end

          # Instruction: OP_CALL_NATIVE dest, base_reg, argc | imm16: native_id
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (base_reg.to_u32 << 8) |
                      native_id.value.to_u32
          instructions << Instruction.new(instr_val)
          arg_regs.each { |r| allocator.free_temp(r) }
          if !arg_regs.empty? && base_reg != arg_regs[0]
            arg_regs.size.times do |i|
              allocator.free_temp((base_reg + i).to_u8)
            end
          end
          return dest
        end
      end

      # Vector2 constructors & properties
      if obj_str == "Vector2" && node.name == "new"
        x_reg = compile_node(node.args[0], allocator, instructions, fn)
        y_reg = compile_node(node.args[1], allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Vec2New, dest, x_reg, y_reg)
        allocator.free_temp(x_reg)
        allocator.free_temp(y_reg)
        return dest
      end

      has_class_method = @functions.any? { |f| f.name.ends_with?("##{node.name}") }
      if !has_class_method
        if node.name == "x" && node.obj
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Vec2GetX, dest, obj_reg, 0_u8)
          return dest
        elsif node.name == "y" && node.obj
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Vec2GetY, dest, obj_reg, 0_u8)
          return dest
        elsif node.name == "x=" && node.obj && node.args.size > 0
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Vec2SetX, obj_reg, val_reg, 0_u8)
          return obj_reg
        elsif node.name == "y=" && node.obj && node.args.size > 0
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Vec2SetY, obj_reg, val_reg, 0_u8)
          return obj_reg
        end
      end


      # times loop: e.g. 10.times do |i| ... end
      if node.name == "times" && node.obj && (block = node.block)
        count_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, iter_reg, 0_u16)

        if block_arg = block.args.first?
          allocator.allocate_local(block_arg.name)
          local_iter = allocator.get_local(block_arg.name).not_nil!
        else
          local_iter = iter_reg
        end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Lt, cond_reg, iter_reg, count_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        # Assign block arg
        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        # iter += 1
        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)
        return dest
      end

      # Array index read: arr[idx]
      if node.name == "[]" && node.obj && node.args.size == 1
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        idx_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::ArrayGet.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array index write: arr[idx] = val
      if node.name == "[]=" && node.obj && node.args.size == 2
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        idx_reg = compile_node(node.args[0], allocator, instructions, fn)
        val_reg = compile_node(node.args[1], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::ArraySet.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(val_reg)
        3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
        return dest
      end

      # Array push: arr << val or arr.push(val)
      if (node.name == "push" || node.name == "<<") && node.obj && node.args.size == 1
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, val_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::ArrayPush.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(val_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array pop: arr.pop
      if node.name == "pop" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (arr_reg.to_u32 << 8) |
                    NativeId::ArrayPop.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array size: arr.size / arr.length
      if (node.name == "size" || node.name == "length") && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (arr_reg.to_u32 << 8) |
                    NativeId::ArraySize.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array clear: arr.clear
      if node.name == "clear" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (arr_reg.to_u32 << 8) |
                    NativeId::ArrayClear.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Range each: (min..max).each do |i| ... end
      range_target = if node.obj.is_a?(Crystal::RangeLiteral)
                       node.obj.as(Crystal::RangeLiteral)
                     elsif node.obj.is_a?(Crystal::Expressions) && node.obj.as(Crystal::Expressions).expressions.size == 1 && node.obj.as(Crystal::Expressions).expressions.first.is_a?(Crystal::RangeLiteral)
                       node.obj.as(Crystal::Expressions).expressions.first.as(Crystal::RangeLiteral)
                     else
                       nil
                     end

      if node.name == "each" && range_target && (block = node.block)
        range = range_target
        from_reg = compile_node(range.from, allocator, instructions, fn)
        to_reg = compile_node(range.to, allocator, instructions, fn)
        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, iter_reg, from_reg, 0_u8)

        local_iter = if block_arg = block.args.first?
                       allocator.allocate_local(block_arg.name)
                       allocator.get_local(block_arg.name).not_nil!
                     else
                       iter_reg
                     end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        if range.exclusive?
          instructions << Instruction.encode_abc(Opcode::Lt, cond_reg, iter_reg, to_reg)
        else
          instructions << Instruction.encode_abc(Opcode::Le, cond_reg, iter_reg, to_reg)
        end
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, exit_offset)
        allocator.free_temp(from_reg)
        allocator.free_temp(to_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)
        return dest
      end

      # Array each: arr.each do |item| ... end
      if node.name == "each" && node.obj && (block = node.block)
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        size_reg = allocator.alloc_temp
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (size_reg.to_u32 << 16) |
                    (arr_reg.to_u32 << 8) |
                    NativeId::ArraySize.value.to_u32
        instructions << Instruction.new(instr_val)

        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, iter_reg, 0_u16)

        block_item_reg = if block_arg = block.args.first?
                           allocator.allocate_local(block_arg.name)
                         else
                           allocator.alloc_temp
                         end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Lt, cond_reg, iter_reg, size_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, 0_i16)

        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, iter_reg, 0_u8)
        get_val = (Opcode::CallNative.value.to_u32 << 24) |
                  (block_item_reg.to_u32 << 16) |
                  (seq_base.to_u32 << 8) |
                  NativeId::ArrayGet.value.to_u32
        instructions << Instruction.new(get_val)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)

        compile_node(block.body, allocator, instructions, fn)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)
        instructions[exit_jump_idx] = Instruction.encode_branch(Opcode::JumpIfFalse, cond_reg, (instructions.size - exit_jump_idx - 1).to_i16)
        allocator.free_temp(arr_reg)
        allocator.free_temp(size_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)
        return dest
      end

      # StaticArray.new / StaticArray(...)
      if obj_str.starts_with?("StaticArray") && node.name == "new"
        sz = 4
        if obj_str =~ /\((\w+),\s*(\d+)\)/
          sz = $2.to_i
        end
        sz_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, sz_reg, sz.to_u16)
        def_val_reg = if node.args.size > 0
                        compile_node(node.args[0], allocator, instructions, fn)
                      else
                        r = allocator.alloc_temp
                        instructions << Instruction.encode_abc(Opcode::LoadNil, r, 0_u8, 0_u8)
                        r
                      end
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, sz_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, def_val_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::StaticArrayNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(sz_reg)
        allocator.free_temp(def_val_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # IO::Memory.new
      if (obj_str == "IO::Memory" || obj_str.includes?("Memory")) && node.name == "new"
        arg0 = if node.args.size > 0
                 compile_node(node.args[0], allocator, instructions, fn)
               else
                 r = allocator.alloc_temp
                 instructions << Instruction.encode_ab_imm(Opcode::LoadInt, r, 64_u16)
                 r
               end
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (arg0.to_u32 << 8) |
                    NativeId::MemoryIONew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arg0)
        return dest
      end

      # IO::Memory methods
      is_io = (io_obj = node.obj) && (
        (io_obj.is_a?(Crystal::Var) && @var_types[io_obj.name]?.try { |t| t.includes?("Memory") || t.includes?("IO") }) ||
        (io_obj.is_a?(Crystal::Call) && io_obj.name == "new" && io_obj.obj.to_s.includes?("Memory"))
      )
      if node.obj && ((is_io && node.name == "to_s") || ["write_byte", "write", "print", "puts", "rewind", "pos", "clear"].includes?(node.name))
        native_op = case node.name
                    when "write_byte" then NativeId::MemoryIOWriteByte
                    when "write", "print" then NativeId::MemoryIOWrite
                    when "puts" then NativeId::MemoryIOPuts
                    when "to_s" then NativeId::MemoryIOToS
                    when "rewind" then NativeId::MemoryIORewind
                    when "pos" then NativeId::MemoryIOPos
                    when "clear" then NativeId::MemoryIOClear
                    else nil
                    end
        if native_op && (node.name == "to_s" || node.name == "rewind" || node.name == "pos" || node.name == "clear" || !node.args.empty?)
          io_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          if node.args.empty?
            instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                        (dest.to_u32 << 16) |
                        (io_reg.to_u32 << 8) |
                        native_op.value.to_u32
            instructions << Instruction.new(instr_val)
          else
            val_reg = compile_node(node.args[0], allocator, instructions, fn)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, io_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, val_reg, 0_u8)
            instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                        (dest.to_u32 << 16) |
                        (seq_base.to_u32 << 8) |
                        native_op.value.to_u32
            instructions << Instruction.new(instr_val)
            allocator.free_temp(val_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)
          end
          allocator.free_temp(io_reg)
          return dest
        end
      end

      # Pointer value dereference or Enum value getter: ptr.value / enum.value
      if node.name == "value" && node.obj && node.args.empty?
        obj = node.obj.not_nil!
        is_pointer = (obj.is_a?(Crystal::Var) && @var_types[obj.name]?.try(&.starts_with?("Pointer"))) ||
                     (obj.is_a?(Crystal::Call) && obj.name == "malloc")
        if !is_pointer
          obj_reg = compile_node(obj, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          return dest
        end

        ptr_reg = compile_node(obj, allocator, instructions, fn)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, zero_reg, 0_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::PointerGet.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(zero_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Pointer value assignment: ptr.value = val
      if node.name == "value=" && node.obj && node.args.size == 1
        ptr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, zero_reg, 0_u16)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::PointerSet.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(zero_reg)
        allocator.free_temp(val_reg)
        3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
        return dest
      end

      # Pointer address: ptr.address
      if node.name == "address" && node.obj && node.args.empty?
        ptr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ptr_reg.to_u32 << 8) |
                    NativeId::PointerAddress.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        return dest
      end

      # Pointer(T).malloc(size)
      if obj_str.starts_with?("Pointer") && node.name == "malloc"
        size_reg = if node.args.size > 0
                     compile_node(node.args[0], allocator, instructions, fn)
                   else
                     r = allocator.alloc_temp
                     instructions << Instruction.encode_ab_imm(Opcode::LoadInt, r, 1_u16)
                     r
                   end
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (size_reg.to_u32 << 8) |
                    NativeId::PointerMalloc.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(size_reg)
        return dest
      end

      # Pointer(T).new(addr)
      if obj_str.starts_with?("Pointer") && node.name == "new" && node.args.size > 0
        addr_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (addr_reg.to_u32 << 8) |
                    NativeId::PointerNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(addr_reg)
        return dest
      end

      # Box(T).box(val)
      if obj_str.starts_with?("Box") && node.name == "box" && node.args.size > 0
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (val_reg.to_u32 << 8) |
                    NativeId::BoxNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(val_reg)
        return dest
      end

      # Box(T).unbox(ptr)
      if obj_str.starts_with?("Box") && node.name == "unbox" && node.args.size > 0
        ptr_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ptr_reg.to_u32 << 8) |
                    NativeId::BoxUnbox.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        return dest
      end

      # Context with block auto-cleanup: vm_context(:name) do ... end
      if node.name == "vm_context" && (obj_str.empty? || obj_str == "Citrine") && (block = node.block)
        arg_node = node.args.first?
        ctx_val = case arg_node
                  when Crystal::SymbolLiteral then arg_node.value
                  when Crystal::StringLiteral then arg_node.value
                  else arg_node.to_s
                  end
        s_idx = add_string(ctx_val)
        ctx_reg = allocator.alloc_temp
        c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: ctx_val))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, ctx_reg, c_idx.to_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ctx_reg.to_u32 << 8) |
                    NativeId::ContextSet.value.to_u32
        instructions << Instruction.new(instr_val)

        # Compile body of block inside context
        compile_node(block.body, allocator, instructions, fn)

        # Auto-rewind/clear context arena on block exit
        clear_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ctx_reg.to_u32 << 8) |
                    NativeId::ContextClear.value.to_u32
        instructions << Instruction.new(clear_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Context Clear: clear_vm_context(:name) / reset_vm_context(:name)
      if (node.name == "clear_vm_context" || node.name == "reset_vm_context") && (obj_str.empty? || obj_str == "Citrine")
        arg_node = node.args.first?
        ctx_val = case arg_node
                  when Crystal::SymbolLiteral then arg_node.value
                  when Crystal::StringLiteral then arg_node.value
                  else arg_node.to_s
                  end
        s_idx = add_string(ctx_val)
        ctx_reg = allocator.alloc_temp
        c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: ctx_val))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, ctx_reg, c_idx.to_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ctx_reg.to_u32 << 8) |
                    NativeId::ContextClear.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Memory Stats: Citrine::Memory.stats / Citrine::Memory.heap_bytes / memory_stats
      if ((node.name == "stats" || node.name == "heap_bytes") && obj_str.ends_with?("Memory")) || node.name == "memory_stats"
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, zero_reg, 0_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (zero_reg.to_u32 << 8) |
                    NativeId::MemoryStats.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(zero_reg)
        return dest
      end

      # Context Switch: set_vm_context(:name) / vm_context(:name)
      if (node.name == "set_vm_context" || node.name == "vm_context") && (obj_str.empty? || obj_str == "Citrine")
        arg_node = node.args.first?
        ctx_val = case arg_node
                  when Crystal::SymbolLiteral then arg_node.value
                  when Crystal::StringLiteral then arg_node.value
                  else arg_node.to_s
                  end
        s_idx = add_string(ctx_val)
        ctx_reg = allocator.alloc_temp
        c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: ctx_val))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, ctx_reg, c_idx.to_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (ctx_reg.to_u32 << 8) |
                    NativeId::ContextSet.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Pointer.free(ptr) or ptr.free
      if (node.name == "free") && ((obj_str.starts_with?("Pointer") && node.args.size > 0) || node.obj)
        ptr_target = (obj_str.starts_with?("Pointer") && node.args.size > 0) ? node.args[0] : node.obj.not_nil!
        ptr_reg = compile_node(ptr_target, allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::PointerFree.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # GC.collect
      if (obj_str == "GC" || obj_str.ends_with?("::GC")) && node.name == "collect"
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, zero_reg, 0_u16)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (zero_reg.to_u32 << 8) |
                    NativeId::GCCycle.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(zero_reg)
        return dest
      end

      # Enum.new(val) constructor
      if node.name == "new" && @enums.has_key?(obj_str) && node.args.size > 0
        arg_reg = compile_node(node.args.first, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, arg_reg, 0_u8)
        allocator.free_temp(arg_reg)
        return dest
      end

      # .to_s on any value/expression
      if node.name == "to_s" && node.args.empty? && node.obj
        obj = node.obj.not_nil!
        if obj.is_a?(Crystal::StringLiteral)
          obj_reg = compile_node(obj, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          return dest
        elsif obj.is_a?(Crystal::Var) && @var_types[obj.name]? == "String"
          obj_reg = compile_node(obj, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          return dest
        else
          hint = 0_u16
          if obj.is_a?(Crystal::BoolLiteral) || (obj.is_a?(Crystal::Var) && @var_types[obj.name]? == "Bool")
            hint = 2_u16
          end
          val_reg = compile_node(obj, allocator, instructions, fn)
          res_reg = emit_to_string(val_reg, hint, allocator, instructions)
          instructions << Instruction.encode_abc(Opcode::Move, dest, res_reg, 0_u8)
          allocator.free_temp(res_reg)
          return dest
        end
      end

      # Regex.new(pattern)
      if (obj_str == "Regex" || obj_str.ends_with?("::Regex")) && node.name == "new" && node.args.size > 0
        pat_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, pat_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::RegexNew.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(pat_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # Regex match / =~ operator: regex =~ str or str =~ regex
      if node.name == "=~" && node.obj && node.args.size == 1
        left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        right_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, left_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, right_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::RegexMatch.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Regex#matches? or Regex#match
      if (node.name == "matches?" || node.name == "match") && node.obj && node.args.size == 1
        obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        str_reg = compile_node(node.args[0], allocator, instructions, fn)
        match_pos = allocator.alloc_temp
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, str_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, obj_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (match_pos.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::RegexMatch.value.to_u32
        instructions << Instruction.new(instr_val)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, zero_reg, 0_u16)
        instructions << Instruction.encode_abc(Opcode::Ge, dest, match_pos, zero_reg)
        allocator.free_temp(obj_reg)
        allocator.free_temp(str_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        allocator.free_temp(match_pos)
        allocator.free_temp(zero_reg)
        return dest
      end

      # String helper methods: strip, downcase, upcase
      if ["strip", "downcase", "upcase"].includes?(node.name) && node.obj && node.args.empty?
        s_op = case node.name
               when "strip" then NativeId::StringStrip
               when "downcase" then NativeId::StringDowncase
               when "upcase" then NativeId::StringUpcase
               else NativeId::StringStrip
               end
        str_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(1)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, str_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    s_op.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(str_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # String helper methods: starts_with?, ends_with?, includes?, split
      if ["starts_with?", "ends_with?", "includes?", "split"].includes?(node.name) && node.obj
        s_op = case node.name
               when "starts_with?" then NativeId::StringStartsWith
               when "ends_with?" then NativeId::StringEndsWith
               when "includes?" then NativeId::StringIncludes
               when "split" then NativeId::StringSplit
               else NativeId::StringIncludes
               end
        str_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        arg_reg = if node.args.size > 0
                    compile_node(node.args[0], allocator, instructions, fn)
                  else
                    sp_reg = allocator.alloc_temp
                    sp_idx = add_string(" ")
                    c_idx = add_constant(ConstValue.new(ConstType::String, int_val: sp_idx, str_val: " "))
                    instructions << Instruction.encode_ab_imm(Opcode::LoadConst, sp_reg, c_idx.to_u16)
                    sp_reg
                  end
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, str_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, arg_reg, 0_u8)
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (dest.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    s_op.value.to_u32
        instructions << Instruction.new(instr_val)
        allocator.free_temp(str_reg)
        allocator.free_temp(arg_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Class instantiation: Foo.new(...)
      if @classes.has_key?(obj_str) && node.name == "new"
        cls_info = @classes[obj_str]
        if cls_info.is_abstract
          panic_str = "Cannot instantiate abstract class #{obj_str}"
          s_idx = add_string(panic_str)
          c_idx = add_constant(ConstValue.new(ConstType::String, int_val: s_idx, str_val: panic_str))
          p_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, p_reg, c_idx.to_u16)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (p_reg.to_u32 << 8) |
                      NativeId::Panic.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(p_reg)
          return dest
        end
        cid_reg = allocator.alloc_temp
        cnt_reg = allocator.alloc_temp
        is_struct_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, cid_reg, cls_info.class_id.to_u16)
        f_count = cls_info.fields.size > 0 ? cls_info.fields.size : 1
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, cnt_reg, f_count.to_u16)
        instructions << Instruction.encode_ab_imm(Opcode::LoadInt, is_struct_reg, cls_info.is_struct ? 1_u16 : 0_u16)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, cid_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, cnt_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, is_struct_reg, 0_u8)
        obj_val = (Opcode::CallNative.value.to_u32 << 24) |
                  (dest.to_u32 << 16) |
                  (seq_base.to_u32 << 8) |
                  NativeId::ObjectNew.value.to_u32
        instructions << Instruction.new(obj_val)
        allocator.free_temp(cid_reg)
        allocator.free_temp(cnt_reg)
        allocator.free_temp(is_struct_reg)
        3.times { |i| allocator.free_temp((seq_base + i).to_u8) }

        # Call initialize if present
        init_name = "#{obj_str}#initialize"
        if init_idx = @functions.index { |f| f.name == init_name }
          call_base = allocator.alloc_call_frame(node.args.size + 2)
          instructions << Instruction.encode_abc(Opcode::Move, (call_base + 1).to_u8, dest, 0_u8)
          node.args.each_with_index do |arg, i|
            arg_reg = compile_node(arg, allocator, instructions, fn)
            target_reg = (call_base + 2_u8 + i.to_u8).to_u8
            instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
            allocator.free_temp(arg_reg)
          end
          dummy_dest = call_base
          instructions << Instruction.encode_ab_imm(Opcode::Call, dummy_dest, init_idx.to_u16)
          (node.args.size + 1).times { |i| allocator.free_temp((call_base + 1_u8 + i.to_u8).to_u8) }
          allocator.free_temp(dummy_dest)
        end
        return dest
      end

      # Yield / with self yield block inlining
      block_target_name : String? = nil
      if !obj_str.empty?
        @classes.each do |cname, _|
          cand = "#{cname}##{node.name}"
          if @program_defs.has_key?(cand)
            block_target_name = cand
            break
          end
        end
      end
      block_target_name ||= node.name if @program_defs.has_key?(node.name)

      if block_target_name && (def_node = @program_defs[block_target_name]?) && (block = node.block)
        if has_yield_node?(def_node.body)
          return inline_block_call(node, def_node, block, allocator, instructions, fn)
        end
      end

      # Instance method call: obj.method(args...)
      if node.obj
        matched_method : String? = nil
        @classes.each do |cname, _|
          cand = "#{cname}##{node.name}"
          if @functions.any? { |f| f.name == cand }
            matched_method = cand
            break
          end
        end

        if matched_method && (f_idx = @functions.index { |f| f.name == matched_method })
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          call_base = allocator.alloc_call_frame(node.args.size + 2)
          dest_call = call_base
          instructions << Instruction.encode_abc(Opcode::Move, (dest_call + 1).to_u8, obj_reg, 0_u8)
          allocator.free_temp(obj_reg)
          node.args.each_with_index do |arg, i|
            arg_reg = compile_node(arg, allocator, instructions, fn)
            target_reg = (dest_call + 2_u8 + i.to_u8).to_u8
            instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
            allocator.free_temp(arg_reg)
          end
          instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, f_idx.to_u16)
          (node.args.size + 1).times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
          instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
          allocator.free_temp(dest_call)
          return dest
        end
      end

      # Class property getter / setter access
      clean_prop_name = node.name.ends_with?("=") ? node.name[0...-1] : node.name
      prop_cls = obj_str
      prop_offset : Int32? = nil
      while !prop_cls.empty?
        if off = @class_prop_offsets["#{prop_cls}::#{clean_prop_name}"]?
          prop_offset = off
          break
        end
        prop_cls = @classes[prop_cls]?.try(&.superclass_name) || ""
      end

      if prop_offset
        addr_val = CLASS_PROP_BASE + (prop_offset.to_u32 * 4)
        if node.name.ends_with?("=") && node.args.size == 1
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          addr_reg = allocator.alloc_temp
          idx_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::PointerSet.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          allocator.free_temp(val_reg)
          3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
          return dest
        elsif node.args.empty?
          addr_reg = allocator.alloc_temp
          idx_reg = allocator.alloc_temp
          instructions << Instruction.encode_ab_imm(Opcode::LoadInt, idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                      (dest.to_u32 << 16) |
                      (seq_base.to_u32 << 8) |
                      NativeId::PointerGet.value.to_u32
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
          return dest
        end
      end

      # User function or module function call: func(args...) / Mod.func(args...)
      target_func_name = if !obj_str.empty?
                           "#{obj_str}.#{node.name}"
                         else
                           node.name
                         end

      func_idx = @functions.index { |f| f.name == target_func_name } ||
                 @functions.index { |f| f.name == node.name }

      if func_idx
        call_base = allocator.alloc_call_frame(node.args.size + 1)
        dest_call = call_base
        node.args.each_with_index do |arg, i|
          arg_reg = compile_node(arg, allocator, instructions, fn)
          target_reg = (dest_call + 1_u8 + i.to_u8).to_u8
          instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
          allocator.free_temp(arg_reg)
        end
        instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, func_idx.to_u16)
        node.args.size.times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
        instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
        allocator.free_temp(dest_call)
        return dest
      end

      instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
      dest
    end

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

        call_obj_str = call_node.obj.to_s
        if @classes.has_key?(call_obj_str)
          target_cls = @classes[call_obj_str]
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
          instructions << Instruction.encode_abc(Opcode::LoadNil, param_reg, 0_u8, 0_u8)
        end
      end

      inliner = Inliner.new(param_map, self_var_name, block, target_cls)
      transformed_body = def_node.body.clone.transform(inliner)

      ret_reg = compile_node(transformed_body, allocator, instructions, fn)

      @current_self_reg = old_self_reg
      @current_class = old_class
      ret_reg
    end

    private def compile_spawn(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      block = node.block
      unless block
        instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
        return dest
      end

      arg_names = block.args.map(&.name)
      fiber_fn_name = "__fiber_#{@functions.size}"
      fiber_fn = CompiledFunction.new(fiber_fn_name, arg_names.size.to_u8)
      fiber_allocator = RegisterAllocator.new(arg_names)
      fiber_instructions = [] of Instruction

      arg_names.each_with_index do |name, idx|
        @source_map.record_register(fiber_fn_name, idx, name)
      end

      # Compile fiber body
      ret_reg = compile_node(block.body, fiber_allocator, fiber_instructions, fiber_fn)
      fiber_instructions << Instruction.encode_abc(Opcode::Return, ret_reg, 0_u8, 0_u8)
      fiber_fn.num_registers = fiber_allocator.max_registers
      fiber_fn.instructions = fiber_instructions

      func_idx = @functions.size
      @functions << fiber_fn

      # Evaluate arguments to pass into the fiber (sequential registers after dest)
      node.args.each_with_index do |arg, i|
        reg = compile_node(arg, allocator, instructions, fn)
        target_reg = dest + 1_u8 + i.to_u8
        instructions << Instruction.encode_abc(Opcode::Move, target_reg, reg, 0_u8)
        allocator.free_temp(reg)
      end

      instructions << Instruction.encode_ab_imm(Opcode::SpawnFiber, dest, func_idx.to_u16)
      dest
    end

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
        instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                    (res_reg.to_u32 << 16) |
                    (seq_base.to_u32 << 8) |
                    NativeId::StringConcat.value.to_u32
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
      when Crystal::Var
        if @var_types[piece.name]? == "String"
          if reg = allocator.get_local(piece.name)
            dest = allocator.alloc_temp
            instructions << Instruction.encode_abc(Opcode::Move, dest, reg, 0_u8)
            dest
          else
            dest = allocator.alloc_temp
            instructions << Instruction.encode_abc(Opcode::LoadNil, dest, 0_u8, 0_u8)
            dest
          end
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          hint = @var_types[piece.name]? == "Bool" ? 2_u16 : 0_u16
          emit_to_string(val_reg, hint, allocator, instructions)
        end
      when Crystal::Call
        if piece.name == "to_s"
          compile_node(piece, allocator, instructions, fn)
        else
          val_reg = compile_node(piece, allocator, instructions, fn)
          emit_to_string(val_reg, 0_u16, allocator, instructions)
        end
      when Crystal::StringInterpolation
        compile_node(piece, allocator, instructions, fn)
      else
        val_reg = compile_node(piece, allocator, instructions, fn)
        emit_to_string(val_reg, 0_u16, allocator, instructions)
      end
    end

    private def emit_to_string(val_reg : UInt8, hint : UInt16, allocator : RegisterAllocator, instructions : Array(Instruction)) : UInt8
      dest = allocator.alloc_temp
      seq_base = allocator.alloc_contiguous(2)
      instructions << Instruction.encode_abc(Opcode::Move, seq_base, val_reg, 0_u8)
      instructions << Instruction.encode_ab_imm(Opcode::LoadInt, (seq_base + 1).to_u8, hint)
      instr_val = (Opcode::CallNative.value.to_u32 << 24) |
                  (dest.to_u32 << 16) |
                  (seq_base.to_u32 << 8) |
                  NativeId::ToString.value.to_u32
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
      when "draw_texture" then NativeId::DrawTexture
      when "draw_texture_rec" then NativeId::DrawTextureRec
      when "begin_mode_3d" then NativeId::BeginMode3D
      when "end_mode_3d" then NativeId::EndMode3D
      when "draw_cube" then NativeId::DrawCube
      when "draw_cube_wires" then NativeId::DrawCubeWires
      when "draw_grid" then NativeId::DrawGrid
      when "draw_mesh" then NativeId::DrawMesh
      when "button_down?" then NativeId::ButtonDown
      when "button_pressed?" then NativeId::ButtonPressed
      when "button_released?" then NativeId::ButtonReleased
      when "get_analog" then NativeId::GetAnalog
      when "set_rumble" then NativeId::SetRumble
      when "load_sound" then NativeId::LoadSound
      when "play_sound" then NativeId::PlaySound
      when "stop_sound" then NativeId::StopSound
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
      else nil
      end
    end

    private def resolve_type_id(type_name : String) : UInt32?
      clean = type_name.split("(").first.strip
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
          nil
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
          end
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
      case str
      when "GL::POINTS", "GLMode::Points", "Citrine::GL::POINTS", "Citrine::GL::Mode::Points" then ConstValue.new(ConstType::Int32, int_val: 0)
      when "GL::LINES", "GLMode::Lines", "Citrine::GL::LINES", "Citrine::GL::Mode::Lines" then ConstValue.new(ConstType::Int32, int_val: 1)
      when "GL::LINE_STRIP", "GLMode::LineStrip", "Citrine::GL::LINE_STRIP", "Citrine::GL::Mode::LineStrip" then ConstValue.new(ConstType::Int32, int_val: 2)
      when "GL::LINE_LOOP", "GLMode::LineLoop", "Citrine::GL::LINE_LOOP", "Citrine::GL::Mode::LineLoop" then ConstValue.new(ConstType::Int32, int_val: 3)
      when "GL::TRIANGLES", "GLMode::Triangles", "Citrine::GL::TRIANGLES", "Citrine::GL::Mode::Triangles" then ConstValue.new(ConstType::Int32, int_val: 4)
      when "GL::TRIANGLE_STRIP", "GLMode::TriangleStrip", "Citrine::GL::TRIANGLE_STRIP", "Citrine::GL::Mode::TriangleStrip" then ConstValue.new(ConstType::Int32, int_val: 5)
      when "GL::TRIANGLE_FAN", "GLMode::TriangleFan", "Citrine::GL::TRIANGLE_FAN", "Citrine::GL::Mode::TriangleFan" then ConstValue.new(ConstType::Int32, int_val: 6)
      when "GL::QUADS", "GLMode::Quads", "Citrine::GL::QUADS", "Citrine::GL::Mode::Quads" then ConstValue.new(ConstType::Int32, int_val: 7)
      when "Button::Cross" then ConstValue.new(ConstType::Int32, int_val: Button::Cross.value.to_i32)
      when "Button::Circle" then ConstValue.new(ConstType::Int32, int_val: Button::Circle.value.to_i32)
      when "Button::Square" then ConstValue.new(ConstType::Int32, int_val: Button::Square.value.to_i32)
      when "Button::Triangle" then ConstValue.new(ConstType::Int32, int_val: Button::Triangle.value.to_i32)
      when "Button::Up" then ConstValue.new(ConstType::Int32, int_val: Button::Up.value.to_i32)
      when "Button::Down" then ConstValue.new(ConstType::Int32, int_val: Button::Down.value.to_i32)
      when "Button::Left" then ConstValue.new(ConstType::Int32, int_val: Button::Left.value.to_i32)
      when "Button::Right" then ConstValue.new(ConstType::Int32, int_val: Button::Right.value.to_i32)
      when "Button::L1" then ConstValue.new(ConstType::Int32, int_val: Button::L1.value.to_i32)
      when "Button::R1" then ConstValue.new(ConstType::Int32, int_val: Button::R1.value.to_i32)
      when "Button::L2" then ConstValue.new(ConstType::Int32, int_val: Button::L2.value.to_i32)
      when "Button::R2" then ConstValue.new(ConstType::Int32, int_val: Button::R2.value.to_i32)
      when "Button::Start" then ConstValue.new(ConstType::Int32, int_val: Button::Start.value.to_i32)
      when "Button::Select" then ConstValue.new(ConstType::Int32, int_val: Button::Select.value.to_i32)
      when "Color::White" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 255_u8, 255_u8, 255_u8).to_u32)
      when "Color::Black" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 0_u8, 0_u8, 255_u8).to_u32)
      when "Color::Red" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 0_u8, 0_u8, 255_u8).to_u32)
      when "Color::Green" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 255_u8, 0_u8, 255_u8).to_u32)
      when "Color::Blue" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 0_u8, 255_u8, 255_u8).to_u32)
      when "Color::Yellow" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 255_u8, 0_u8, 255_u8).to_u32)
      when "Color::Cyan" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(0_u8, 255_u8, 255_u8, 255_u8).to_u32)
      when "Color::Magenta" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 0_u8, 255_u8, 255_u8).to_u32)
      when "Color::Gray" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(128_u8, 128_u8, 128_u8, 255_u8).to_u32)
      when "Color::Orange" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(255_u8, 165_u8, 0_u8, 255_u8).to_u32)
      when "Color::Purple" then ConstValue.new(ConstType::Color, uint_val: ColorVal.new(128_u8, 0_u8, 128_u8, 255_u8).to_u32)
      else ConstValue.new(ConstType::Int32, int_val: 0)
      end
    end

    private def add_constant(val : ConstValue) : Int32
      idx = @constants.index(val)
      return idx if idx
      @constants << val
      @constants.size - 1
    end

    private def add_string(str : String) : Int32
      idx = @strings.index(str)
      return idx if idx
      @strings << str
      @strings.size - 1
    end

    private def record_location(node : Crystal::ASTNode, offset : Int32, fn_name : String)
      if loc = node.location
        @source_map.add(offset, @filename || "main.cr", loc.line_number, loc.column_number, fn_name)
      end
    end

    private def is_debug_node?(node : Crystal::ASTNode) : Bool
      if node.is_a?(Crystal::Call)
        obj_name = node.obj.try(&.to_s) || ""
        if obj_name == "Citrine" || obj_name.empty?
          return true if node.name == "log" || node.name == "debug_overlay="
        end
        return true if node.name == "citrine_log"
      end
      false
    end

    private def strip_debug_nodes(program : ParsedProgram)
      program.top_level_nodes.reject! { |node| is_debug_node?(node) }
      program.top_level_nodes.map! do |node|
        if node.is_a?(Crystal::Call) && node.name == "main_loop" && (block = node.block)
          block.body = strip_debug_from_node(block.body)
          node
        else
          node
        end
      end

      if loop_body = program.main_loop_body
        program.main_loop_body = strip_debug_from_node(loop_body)
      end

      program.defs.each do |name, def_node|
        if body = def_node.body
          def_node.body = strip_debug_from_node(body)
        end
      end
    end

    private def strip_debug_from_node(node : Crystal::ASTNode) : Crystal::ASTNode
      case node
      when Crystal::Expressions
        cleaned = node.expressions.reject { |child| is_debug_node?(child) }
        Crystal::Expressions.new(cleaned.map { |child| strip_debug_from_node(child) })
      when Crystal::If
        node.then = strip_debug_from_node(node.then)
        if node_else = node.else
          node.else = strip_debug_from_node(node_else)
        end
        node
      when Crystal::While
        node.body = strip_debug_from_node(node.body)
        node
      else
        is_debug_node?(node) ? Crystal::Nop.new : node
      end
    end

    private def serialize_bytecode : Bytes
      # Ensure all function names are registered in strings table before serialization
      @functions.each do |fn|
        add_string(fn.name)
      end

      io = IO::Memory.new

      # Header
      io.write(MAGIC.to_slice)
      io.write_bytes(1_u16, IO::ByteFormat::LittleEndian) # Version 1
      io.write_bytes(@functions.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(@constants.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(@strings.size.to_u32, IO::ByteFormat::LittleEndian)

      # Strings
      @strings.each do |s|
        bytes = s.to_slice
        io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
        io.write(bytes)
      end

      # Constants
      @constants.each do |c|
        io.write_byte(c.type.value)
        case c.type
        when ConstType::Int32, ConstType::String
          io.write_bytes(c.int_val, IO::ByteFormat::LittleEndian)
        when ConstType::Color
          io.write_bytes(c.uint_val, IO::ByteFormat::LittleEndian)
        when ConstType::Float32
          io.write_bytes(c.float_val, IO::ByteFormat::LittleEndian)
        when ConstType::Vec2
          io.write_bytes(c.float_val, IO::ByteFormat::LittleEndian)
          io.write_bytes(c.float_val2, IO::ByteFormat::LittleEndian)
        when ConstType::Bool
          io.write_byte(c.int_val > 0 ? 1_u8 : 0_u8)
        else
          io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        end
      end

      # Function Table & Code
      current_code_offset = 0_u32
      @functions.each do |fn|
        name_idx = add_string(fn.name)
        io.write_bytes(name_idx.to_u32, IO::ByteFormat::LittleEndian)
        io.write_byte(fn.argc)
        io.write_byte(fn.num_registers)
        io.write_bytes(current_code_offset, IO::ByteFormat::LittleEndian)
        io.write_bytes(fn.instructions.size.to_u32, IO::ByteFormat::LittleEndian)
        current_code_offset += fn.instructions.size.to_u32
      end

      # Instructions
      @functions.each do |fn|
        fn.instructions.each do |instr|
          io.write_bytes(instr.raw, IO::ByteFormat::LittleEndian)
        end
      end

      io.to_slice
    end
  end
end
