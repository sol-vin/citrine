require "compiler/crystal/syntax"
require "./opcode"
require "./register_alloc"
require "./source_map"
require "./budget_checker"
require "./optimizer"
require "../ast/types"
require "../parser/dsl_parser"
require "../parser/error"
require "../mips/assembler"
require "./bytecode_compiler/types"
require "./bytecode_compiler/inliner"
require "./bytecode_compiler/member_extractor"
require "./bytecode_compiler/context_validator"
require "./bytecode_compiler/control_flow"
require "./bytecode_compiler/concurrency_call_compiler"
require "./bytecode_compiler/controller_call_compiler"
require "./bytecode_compiler/call_compiler"
require "./bytecode_compiler/strings_and_types"
require "./bytecode_compiler/serializer"

module Citrine
  class BytecodeCompiler
    MAGIC = "CBC2"

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
    property current_method_name : String? = nil
    property current_namespace : String? = nil
    property program_defs : Hash(String, Crystal::Def) = Hash(String, Crystal::Def).new
    property program_constants : Hash(String, Crystal::ASTNode) = Hash(String, Crystal::ASTNode).new
    property var_types : Hash(String, String) = Hash(String, String).new
    getter enums : Hash(String, Hash(String, Int64)) = Hash(String, Hash(String, Int64)).new
    property inline_counter : Int32 = 0
    property loop_break_jumps : Array(Array(Int32)) = [] of Array(Int32)
    property loop_next_jumps : Array(Array(Int32)) = [] of Array(Int32)
    property active_loop_context : String? = nil
    property in_main_loop : Bool = false
    property program : ParsedProgram? = nil

    def initialize(@filename : String? = nil)
      @source_map = SourceMap.new
      @constants = [] of ConstValue
      @strings = [] of String
      @functions = [] of CompiledFunction
      @release_mode = false
      @opt_level = 1
    end

    def compile(program : ParsedProgram) : Bytes
      @program = program
      if @release_mode
        strip_debug_nodes(program)
      end

      @program_defs = program.defs.dup
      @program_constants = program.constants.dup
      @classes.clear
      @modules.clear
      @enums.clear
      @class_prop_offsets.clear
      @var_types.clear

      program.constants.each do |cname, cnode|
        if cnode.is_a?(Crystal::ArrayLiteral)
          arr_lit = cnode.as(Crystal::ArrayLiteral)
          if arr_lit.elements.size > 0 && arr_lit.elements.all? { |e| e.is_a?(Crystal::StringLiteral) || e.is_a?(Crystal::StringInterpolation) }
            @var_types[cname] = "Array(String)"
          else
            @var_types[cname] = "Array"
          end
        elsif cnode.is_a?(Crystal::StringLiteral) || cnode.is_a?(Crystal::StringInterpolation)
          @var_types[cname] = "String"
        end
      end

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

      # 1b. Transitive module resolution pass
      program.modules.each do |(mod_name, mod_node)|
        if mod_info = @modules[mod_name]?
          body = mod_node.body
          nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
          nodes.each do |raw_child|
            child = raw_child
            while child.is_a?(Crystal::VisibilityModifier)
              child = child.exp
            end
            inc_name = if child.is_a?(Crystal::Include) || child.is_a?(Crystal::Extend)
                         child.name.to_s
                       elsif child.is_a?(Crystal::Call) && (child.name == "include" || child.name == "extend") && child.args.size > 0
                         child.args[0].to_s
                       else
                         nil
                       end
            if inc_name && (inc_mod = @modules[inc_name]?)
              mod_info.included_module_ids << inc_mod.module_id
              mod_info.included_module_ids.concat(inc_mod.included_module_ids)
              mod_info.included_module_ids.uniq!
              inc_mod.methods.each do |m_name, m_def|
                mod_info.methods[m_name] ||= m_def
              end
            end
          end
        end
      end

      # 2. Process classes and structs in topological order
      program.structs.each_key do |cls_name|
        ensure_class_extracted(cls_name, program)
      end

      # 3. Inherit superclass methods
      @classes.each do |cls_name, cls_info|
        if sc_name = cls_info.superclass_name
          if sc_info = @classes[sc_name]?
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
        raw_args = def_node.args.map(&.name)
        argc = if name.includes?("#") && (raw_args.empty? || raw_args.first != "self")
                 (raw_args.size + 1).to_u8
               else
                 raw_args.size.to_u8
               end
        @functions << CompiledFunction.new(name, argc)
      end

      # 5. Compile helper functions / methods
      @program_defs.each do |name, def_node|
        compile_function(def_node, name)
      end

      # 6. Compile main function
      main_fn = CompiledFunction.new("__main__", 0_u8)
      allocator = RegisterAllocator.new
      fn_instructions = [] of Instruction

      # Initialize class variables (@@cvar) across defined classes
      program.structs.each do |cls_name, cls_node|
        body = cls_node.body
        nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        old_class = @current_class
        @current_class = @classes[cls_name]?
        nodes.each do |raw_child|
          child = raw_child
          while child.is_a?(Crystal::VisibilityModifier)
            child = child.exp
          end
          if child.is_a?(Crystal::Assign) && child.target.is_a?(Crystal::ClassVar)
            compile_node(child, allocator, fn_instructions, main_fn)
          elsif child.is_a?(Crystal::TypeDeclaration) && child.var.is_a?(Crystal::ClassVar) && child.value
            assign = Crystal::Assign.new(child.var, child.value.not_nil!)
            compile_node(assign, allocator, fn_instructions, main_fn)
          end
        end
        @current_class = old_class
      end

      # Compile top level nodes
      program.top_level_nodes.each do |node|
        compile_node(node, allocator, fn_instructions, main_fn)
      end

      # Return at end of main
      ret_reg = allocator.alloc_temp
      fn_instructions << Instruction.encode_load_nil(ret_reg)
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

    private def compile_function(node : Crystal::Def, registered_name : String = node.name)
      is_instance_method = registered_name.includes?("#")
      raw_args = node.args.map(&.name)
      arg_names = if is_instance_method && (raw_args.empty? || raw_args.first != "self")
                    ["self"] + raw_args
                  else
                    raw_args
                  end

      fn = @functions.find { |f| f.name == registered_name }
      unless fn
        fn = CompiledFunction.new(registered_name, arg_names.size.to_u8)
        @functions << fn
      end

      allocator = RegisterAllocator.new(arg_names)
      instructions = [] of Instruction

      arg_names.each_with_index do |name, idx|
        @source_map.record_register(registered_name, idx, name)
      end

      old_class = @current_class
      old_self = @current_self_reg
      old_method = @current_method_name
      old_namespace = @current_namespace
      if registered_name.includes?("#")
        parts = registered_name.split("#")
        @current_class = @classes[parts[0]]?
        @current_self_reg = 0_u8
        @current_method_name = parts[1]
        @current_namespace = parts[0]
      elsif registered_name.includes?(".")
        parts = registered_name.split(".")
        @current_class = @classes[parts[0]]?
        @current_method_name = parts[1]
        @current_namespace = parts[0]
      else
        @current_method_name = registered_name
        @current_namespace = nil
      end

      # Compile function body
      ret_reg = compile_node(node.body, allocator, instructions, fn)
      unless instructions.last?.try(&.opcode) == Opcode::Return
        instructions << Instruction.encode_ab_imm(Opcode::Return, ret_reg, 0_u16)
      end

      @current_class = old_class
      @current_self_reg = old_self
      @current_method_name = old_method
      @current_namespace = old_namespace

      fn.num_registers = allocator.max_registers
      fn.instructions = instructions
    end

    private def compile_node(
      node : Crystal::ASTNode,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      record_location(node, instructions.size, fn.name)

      case node
      when Crystal::Asm
        dest = allocator.alloc_temp
        assembled_words = [] of UInt32
        begin
          words = Citrine::MIPS::Assembler.assemble(node.text)
          assembled_words.concat(words)
        rescue ex
          compile_error("Inline assembly syntax error: #{ex.message}", node)
        end

        if assembled_words.empty?
          instructions << Instruction.encode_load_int(dest, 0_u16)
        else
          assembled_words.each_with_index do |word, idx|
            const_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: word.to_i32!, uint_val: word))
            is_last = (idx == assembled_words.size - 1)
            target_dest = is_last ? dest : 0_u8
            instructions << Instruction.encode_ab_imm(Opcode::InlineAsm, target_dest, const_idx.to_u16)
          end
        end
        dest

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
          instructions << Instruction.encode_load_int(f_reg, f_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, self_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, f_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          ret_dest = allocator.alloc_temp
          instr_val = Instruction.call_native_raw(ret_dest, seq_base, NativeId::ObjectSetField)
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
          instructions << Instruction.encode_load_int(idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          instr_val = Instruction.call_native_raw(val_reg, seq_base, NativeId::PointerSet)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
          return val_reg
        end

        if node.target.is_a?(Crystal::Call)
          target_call = node.target.as(Crystal::Call)
          if target_call.name == "[]"
            set_call = Crystal::Call.new(target_call.obj, "[]=", target_call.args + [node.value])
            return compile_node(set_call, allocator, instructions, fn)
          else
            set_call = Crystal::Call.new(target_call.obj, "#{target_call.name}=", [node.value])
            return compile_node(set_call, allocator, instructions, fn)
          end
        end

        target_name = node.target.to_s
        val_type : String? = nil
        if node.value.is_a?(Crystal::Call)
          call_node = node.value.as(Crystal::Call)
          if (call_node.name == "new" || call_node.name == "malloc") && (recv = call_node.obj)
            val_type = recv.to_s
          elsif call_node.name == "to_s" || ["strip", "downcase", "upcase"].includes?(call_node.name)
            val_type = "String"
          elsif call_node.name == "size" || call_node.name == "length"
            val_type = "Int"
          elsif call_node.name == "[]" && (recv = call_node.obj)
            recv_name = recv.is_a?(Crystal::Var) ? recv.name : (recv.is_a?(Crystal::Path) ? recv.names.last : nil)
            if recv_name
              rtype = @var_types[recv_name]?
              if rtype == "Array(String)"
                val_type = "String"
              elsif rtype == "Array(Track)" || rtype == "Array(Citrine::Audio::Track)" || rtype == "Citrine::Audio::Album" || rtype == "Album" || rtype == "Audio::Album"
                val_type = "Citrine::Audio::Track"
              end
            end
          elsif call_node.name == "tracks" && (recv = call_node.obj)
            recv_name = recv.is_a?(Crystal::Var) ? recv.name : (recv.is_a?(Crystal::Path) ? recv.names.last : nil)
            if recv_name && (@var_types[recv_name]? == "Citrine::Audio::Album" || @var_types[recv_name]? == "Album" || @var_types[recv_name]? == "Audio::Album")
              val_type = "Array(Track)"
            end
          elsif (recv = call_node.obj)
            recv_name = recv.is_a?(Crystal::Var) ? recv.name : (recv.is_a?(Crystal::Path) ? recv.names.last : nil)
            if recv_name && (rtype = @var_types[recv_name]?)
              cls_target = @classes[rtype]? || @classes[rtype.split("::").last]?
              if cls_target
                val_type = cls_target.method_return_types[call_node.name]? || cls_target.field_types[call_node.name]?
              end
            end
            if val_type.nil? && (call_node.name.ends_with?("_s") || call_node.name.ends_with?("_str") || call_node.name.includes?("title") || call_node.name.includes?("header") || call_node.name.includes?("artist") || call_node.name.includes?("album"))
              val_type = "String"
            end
          end
        elsif node.value.is_a?(Crystal::InstanceVar)
          clean = node.value.as(Crystal::InstanceVar).name.gsub(/^@/, "")
          if cls = @current_class
            val_type = cls.field_types[clean]?
          end
          if val_type.nil? && (clean.ends_with?("_str") || clean.ends_with?("duration_s") || clean == "dur_s" || clean.includes?("title") || clean.includes?("header") || clean.includes?("artist") || clean.includes?("album"))
            val_type = "String"
          end
        elsif node.value.is_a?(Crystal::Var)
          val_type = @var_types[node.value.as(Crystal::Var).name]?
        elsif node.value.is_a?(Crystal::Path)
          path_node = node.value.as(Crystal::Path)
          if path_node.names.size >= 2
            val_type = path_node.names[0...-1].join("::")
          elsif path_node.names.size == 1
            val_type = @var_types[path_node.names.first]?
          end
        elsif node.value.is_a?(Crystal::StringLiteral) || node.value.is_a?(Crystal::StringInterpolation)
          val_type = "String"
        elsif node.value.is_a?(Crystal::BoolLiteral)
          val_type = "Bool"
        elsif node.value.is_a?(Crystal::NumberLiteral)
          val_type = "Int"
        elsif node.value.is_a?(Crystal::ArrayLiteral)
          arr_lit = node.value.as(Crystal::ArrayLiteral)
          if arr_lit.elements.size > 0 && arr_lit.elements.all? { |el| el.is_a?(Crystal::StringLiteral) || el.is_a?(Crystal::StringInterpolation) }
            val_type = "Array(String)"
          else
            val_type = "Array"
          end
        elsif node.value.is_a?(Crystal::If)
          if_node = node.value.as(Crystal::If)
          t_exp = if_node.then
          e_exp = if_node.else
          if (t_exp.is_a?(Crystal::StringLiteral) || t_exp.is_a?(Crystal::StringInterpolation)) ||
             (e_exp.is_a?(Crystal::StringLiteral) || e_exp.is_a?(Crystal::StringInterpolation))
            val_type = "String"
          end
        elsif node.value.is_a?(Crystal::Case)
          case_node = node.value.as(Crystal::Case)
          if case_node.whens.any? { |w| w.body.is_a?(Crystal::StringLiteral) || w.body.is_a?(Crystal::StringInterpolation) } ||
             (case_node.else.is_a?(Crystal::StringLiteral) || case_node.else.is_a?(Crystal::StringInterpolation))
            val_type = "String"
          end
        end
        if val_type.nil? && (target_name.ends_with?("_str") || target_name.ends_with?("duration_s") || target_name == "dur_s" || target_name.includes?("title") || target_name.includes?("header"))
          val_type = "String"
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
          instr_val = Instruction.call_native_raw(copy_dest, seq_base, NativeId::StructCopy)
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

      when Crystal::MultiAssign
        if node.values.size == 1
          val_reg = compile_node(node.values.first, allocator, instructions, fn)
          node.targets.each_with_index do |target, i|
            elem_reg = allocator.alloc_temp
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, val_reg, 0_u8)
            idx_reg = (seq_base + 1).to_u8
            instructions << Instruction.encode_load_int(idx_reg, i.to_u16)
            get_val = Instruction.call_native_raw(elem_reg, seq_base, NativeId::ArrayGet)
            instructions << Instruction.new(get_val)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)

            target_name = target.to_s
            loc_reg = allocator.allocate_local(target_name)
            instructions << Instruction.encode_abc(Opcode::Move, loc_reg, elem_reg, 0_u8)
            allocator.free_temp(elem_reg)
            @source_map.record_register(fn.name, loc_reg.to_i32, target_name)
          end
          allocator.free_temp(val_reg)
          dest = allocator.alloc_temp
          instructions << Instruction.encode_load_nil(dest)
          dest
        else
          temp_regs = node.values.map do |val|
            compile_node(val, allocator, instructions, fn)
          end
          node.targets.each_with_index do |target, i|
            t_reg = temp_regs[i]?
            next unless t_reg
            target_name = target.to_s
            loc_reg = allocator.allocate_local(target_name)
            instructions << Instruction.encode_abc(Opcode::Move, loc_reg, t_reg, 0_u8)
            @source_map.record_register(fn.name, loc_reg.to_i32, target_name)
          end
          temp_regs.each { |r| allocator.free_temp(r) }
          dest = allocator.alloc_temp
          instructions << Instruction.encode_load_nil(dest)
          dest
        end


      when Crystal::Var
        name = node.name
        if reg = allocator.get_local(name)
          reg
        else
          # Unknown local, allocate
          reg = allocator.allocate_local(name)
          instructions << Instruction.encode_load_nil(reg)
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
            instructions << Instruction.encode_load_int(dest, v64)
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
        instructions << Instruction.encode_load_bool(dest, node.value)
        dest

      when Crystal::NilLiteral
        dest = allocator.alloc_temp
        instructions << Instruction.encode_load_nil(dest)
        dest

      when Crystal::And
        dest = allocator.alloc_temp
        left_reg = compile_node(node.left, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, left_reg, 0_u8)
        jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(dest, 0_i16)
        right_reg = compile_node(node.right, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, right_reg, 0_u8)
        offset = (instructions.size - jump_idx - 1).to_i16
        instructions[jump_idx] = Instruction.encode_jump_if_false(dest, offset)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        dest

      when Crystal::Or
        dest = allocator.alloc_temp
        left_reg = compile_node(node.left, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, left_reg, 0_u8)
        jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_true(dest, 0_i16)
        right_reg = compile_node(node.right, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, right_reg, 0_u8)
        offset = (instructions.size - jump_idx - 1).to_i16
        instructions[jump_idx] = Instruction.encode_jump_if_true(dest, offset)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        dest

      when Crystal::Not
        dest = allocator.alloc_temp
        inner_reg = compile_node(node.exp, allocator, instructions, fn)
        # Not: if true -> false, if false -> true
        # Compare with false/nil
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_bool(false_reg, false)
        instructions << Instruction.encode_cmp(CompareSubOp::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        dest

      when Crystal::If
        dest = allocator.alloc_temp
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_else_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        # Then branch
        then_reg = compile_node(node.then, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, then_reg, 0_u8)
        allocator.free_temp(then_reg)
        jump_end_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

        # Patch else
        else_target_offset = (instructions.size - jump_else_idx - 1).to_i16
        instructions[jump_else_idx] = Instruction.encode_jump_if_false(cond_reg, else_target_offset)

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

      when Crystal::Unless
        dest = allocator.alloc_temp
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_else_idx = instructions.size
        instructions << Instruction.encode_jump_if_true(cond_reg, 0_i16)

        # Then branch
        then_reg = compile_node(node.then, allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, then_reg, 0_u8)
        allocator.free_temp(then_reg)
        jump_end_idx = instructions.size
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

        # Patch else
        else_target_offset = (instructions.size - jump_else_idx - 1).to_i16
        instructions[jump_else_idx] = Instruction.encode_jump_if_true(cond_reg, else_target_offset)

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
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        @loop_break_jumps.push([] of Int32)
        @loop_next_jumps.push([] of Int32)

        compile_node(node.body, allocator, instructions, fn)

        breaks = @loop_break_jumps.pop
        nexts = @loop_next_jumps.pop

        nexts.each do |n_idx|
          back = (loop_start - n_idx - 1).to_i16
          instructions[n_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, back)
        end

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
        instructions[jump_exit_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)

        end_pos = instructions.size
        breaks.each do |b_idx|
          b_off = (end_pos - b_idx - 1).to_i16
          instructions[b_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, b_off)
        end

        allocator.free_temp(cond_reg)
        instructions << Instruction.encode_load_nil(dest)
        dest

      when Crystal::Until
        dest = allocator.alloc_temp
        loop_start = instructions.size
        cond_reg = compile_node(node.cond, allocator, instructions, fn)
        jump_exit_idx = instructions.size
        instructions << Instruction.encode_jump_if_true(cond_reg, 0_i16)

        @loop_break_jumps.push([] of Int32)
        @loop_next_jumps.push([] of Int32)

        compile_node(node.body, allocator, instructions, fn)

        breaks = @loop_break_jumps.pop
        nexts = @loop_next_jumps.pop

        nexts.each do |n_idx|
          back = (loop_start - n_idx - 1).to_i16
          instructions[n_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, back)
        end

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
        instructions[jump_exit_idx] = Instruction.encode_jump_if_true(cond_reg, exit_offset)

        end_pos = instructions.size
        breaks.each do |b_idx|
          b_off = (end_pos - b_idx - 1).to_i16
          instructions[b_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, b_off)
        end

        allocator.free_temp(cond_reg)
        instructions << Instruction.encode_load_nil(dest)
        dest

      when Crystal::Break
        dest = allocator.alloc_temp
        j = instructions.size
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
        if @loop_break_jumps.size > 0
          @loop_break_jumps.last << j
        end
        instructions << Instruction.encode_load_nil(dest)
        dest

      when Crystal::Next
        dest = allocator.alloc_temp
        j = instructions.size
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
        if @loop_next_jumps.size > 0
          @loop_next_jumps.last << j
        end
        instructions << Instruction.encode_load_nil(dest)
        dest

      when Crystal::Call
        compile_call(node, allocator, instructions, fn)

      when Crystal::Path
        # Constant reference e.g. Button::Cross, Color::Red, Direction::North
        if node.names.size == 1 && (local_reg = allocator.get_local(node.names.first))
          dest = allocator.alloc_temp
          instructions << Instruction.encode_abc(Opcode::Move, dest, local_reg, 0_u8)
          return dest
        end

        dest = allocator.alloc_temp
        val = resolve_constant_path(node)
        if val.type == ConstType::Int32 && val.int_val >= -32768 && val.int_val <= 32767
          instructions << Instruction.encode_load_int(dest, val.int_val)
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
                    instructions << Instruction.encode_load_nil(r)
                    r
                  end
        instructions << Instruction.encode_ab_imm(Opcode::Return, ret_reg, 0_u16)
        ret_reg

      when Crystal::InstanceVar
        dest = allocator.alloc_temp
        if (cls = @current_class) && (self_reg = @current_self_reg)
          f_idx = cls.field_index(node.name)
          f_reg = allocator.alloc_temp
          instructions << Instruction.encode_load_int(f_reg, f_idx.to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, self_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, f_reg, 0_u8)
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ObjectGetField)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(f_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
        else
          instructions << Instruction.encode_load_nil(dest)
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
        instructions << Instruction.encode_load_int(idx_reg, 0_u16)
        c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerGet)
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
          instructions << Instruction.encode_load_nil(dest)
        end
        dest

      when Crystal::ArrayLiteral
        dest = allocator.alloc_temp
        cap = node.elements.size > 0 ? node.elements.size : 4
        cap_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(cap_reg, cap.to_u16)
        instr_val = Instruction.call_native_raw(dest, cap_reg, NativeId::ArrayNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(cap_reg)

        node.elements.each do |elem|
          elem_reg = compile_node(elem, allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, dest, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, elem_reg, 0_u8)
          push_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayPush)
          instructions << Instruction.new(push_val)
          allocator.free_temp(elem_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
        end
        dest

      when Crystal::TupleLiteral
        dest = allocator.alloc_temp
        cap = node.elements.size > 0 ? node.elements.size : 4
        cap_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(cap_reg, cap.to_u16)
        instr_val = Instruction.call_native_raw(dest, cap_reg, NativeId::ArrayNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(cap_reg)

        node.elements.each do |elem|
          elem_reg = compile_node(elem, allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, dest, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, elem_reg, 0_u8)
          push_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayPush)
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
          instructions << Instruction.encode_load_bool(dest, false)
        elsif target_ids.size == 1
          tid_reg = allocator.alloc_temp
          instructions << Instruction.encode_load_int(tid_reg, target_ids[0].to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::TypeIsA)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(tid_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
        else
          match_dest = allocator.alloc_temp
          instructions << Instruction.encode_load_bool(match_dest, false)
          jump_end_indices = [] of Int32

          target_ids.each do |tid|
            tid_reg = allocator.alloc_temp
            instructions << Instruction.encode_load_int(tid_reg, tid.to_u16)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
            cur_check = allocator.alloc_temp
            instr_val = Instruction.call_native_raw(cur_check, seq_base, NativeId::TypeIsA)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(tid_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)

            j_next = instructions.size
            instructions << Instruction.encode_jump_if_false(cur_check, 0_i16)
            instructions << Instruction.encode_load_bool(match_dest, true)
            j_end = instructions.size
            instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
            jump_end_indices << j_end
            instructions[j_next] = Instruction.encode_jump_if_false(cur_check, (instructions.size - j_next - 1).to_i16)
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
        instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
        allocator.free_temp(obj_reg)
        dest

      when Crystal::NilableCast
        dest = allocator.alloc_temp
        obj_reg = compile_node(node.obj, allocator, instructions, fn)

        target_types = [] of String
        case to_node = node.to
        when Crystal::Union
          to_node.types.each { |t| target_types << t.to_s }
        else
          target_types << to_node.to_s
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
          instructions << Instruction.encode_load_nil(dest)
        elsif target_ids.size == 1
          tid_reg = allocator.alloc_temp
          instructions << Instruction.encode_load_int(tid_reg, target_ids[0].to_u16)
          seq_base = allocator.alloc_contiguous(2)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
          is_match = allocator.alloc_temp
          instr_val = Instruction.call_native_raw(is_match, seq_base, NativeId::TypeIsA)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(tid_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)

          jump_nil = instructions.size
          instructions << Instruction.encode_jump_if_false(is_match, 0_i16)
          allocator.free_temp(is_match)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          jump_end = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

          instructions[jump_nil] = Instruction.encode_jump_if_false(is_match, (instructions.size - jump_nil - 1).to_i16)
          instructions << Instruction.encode_load_nil(dest)
          instructions[jump_end] = Instruction.encode_branch(Opcode::Jump, 0_u8, (instructions.size - jump_end - 1).to_i16)
        else
          match_dest = allocator.alloc_temp
          instructions << Instruction.encode_load_bool(match_dest, false)
          jump_end_indices = [] of Int32

          target_ids.each do |tid|
            tid_reg = allocator.alloc_temp
            instructions << Instruction.encode_load_int(tid_reg, tid.to_u16)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
            cur_check = allocator.alloc_temp
            instr_val = Instruction.call_native_raw(cur_check, seq_base, NativeId::TypeIsA)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(tid_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)

            j = instructions.size
            instructions << Instruction.encode_jump_if_false(cur_check, 0_i16)
            allocator.free_temp(cur_check)

            instructions << Instruction.encode_load_bool(match_dest, true)
            jump_end_indices << instructions.size
            instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

            instructions[j] = Instruction.encode_jump_if_false(cur_check, (instructions.size - j - 1).to_i16)
          end

          end_pos = instructions.size
          jump_end_indices.each do |j_end|
            instructions[j_end] = Instruction.encode_branch(Opcode::Jump, 0_u8, (end_pos - j_end - 1).to_i16)
          end

          jump_nil = instructions.size
          instructions << Instruction.encode_jump_if_false(match_dest, 0_i16)
          allocator.free_temp(match_dest)
          instructions << Instruction.encode_abc(Opcode::Move, dest, obj_reg, 0_u8)
          jump_end = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

          instructions[jump_nil] = Instruction.encode_jump_if_false(match_dest, (instructions.size - jump_nil - 1).to_i16)
          instructions << Instruction.encode_load_nil(dest)
          instructions[jump_end] = Instruction.encode_branch(Opcode::Jump, 0_u8, (instructions.size - jump_end - 1).to_i16)
        end
        allocator.free_temp(obj_reg)
        dest

      when Crystal::RespondsTo
        dest = allocator.alloc_temp
        method_name = node.name.to_s
        obj_reg = compile_node(node.obj, allocator, instructions, fn)

        matching_classes = @classes.values.select do |cls|
          cls.methods.has_key?(method_name) ||
          cls.ancestor_ids(@classes).any? do |aid|
            if anc = @classes.values.find { |c| c.class_id == aid }
              anc.methods.has_key?(method_name)
            else
              false
            end
          end
        end

        if matching_classes.empty?
          instructions << Instruction.encode_load_bool(dest, false)
        else
          target_ids = matching_classes.map(&.class_id).uniq
          if target_ids.size == 1
            tid_reg = allocator.alloc_temp
            instructions << Instruction.encode_load_int(tid_reg, target_ids[0].to_u16)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
            instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::TypeIsA)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(tid_reg)
            allocator.free_temp(seq_base)
            allocator.free_temp((seq_base + 1).to_u8)
          else
            match_dest = allocator.alloc_temp
            instructions << Instruction.encode_load_bool(match_dest, false)
            jump_end_indices = [] of Int32

            target_ids.each do |tid|
              tid_reg = allocator.alloc_temp
              instructions << Instruction.encode_load_int(tid_reg, tid.to_u16)
              seq_base = allocator.alloc_contiguous(2)
              instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
              instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
              cur_check = allocator.alloc_temp
              instr_val = Instruction.call_native_raw(cur_check, seq_base, NativeId::TypeIsA)
              instructions << Instruction.new(instr_val)
              allocator.free_temp(tid_reg)
              allocator.free_temp(seq_base)
              allocator.free_temp((seq_base + 1).to_u8)

              j = instructions.size
              instructions << Instruction.encode_jump_if_false(cur_check, 0_i16)
              allocator.free_temp(cur_check)

              instructions << Instruction.encode_load_bool(match_dest, true)
              jump_end_indices << instructions.size
              instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)

              instructions[j] = Instruction.encode_jump_if_false(cur_check, (instructions.size - j - 1).to_i16)
            end

            end_pos = instructions.size
            jump_end_indices.each do |j_end|
              instructions[j_end] = Instruction.encode_branch(Opcode::Jump, 0_u8, (end_pos - j_end - 1).to_i16)
            end
            instructions << Instruction.encode_abc(Opcode::Move, dest, match_dest, 0_u8)
            allocator.free_temp(match_dest)
          end
        end
        allocator.free_temp(obj_reg)
        dest

      when Crystal::TypeDeclaration
        target_name = node.var.to_s
        type_str = node.declared_type.to_s
        @var_types[target_name] = type_str

        if val = node.value
          assign = Crystal::Assign.new(node.var, val)
          compile_node(assign, allocator, instructions, fn)
        else
          local_reg = allocator.allocate_local(target_name)
          instructions << Instruction.encode_load_nil(local_reg)
          local_reg
        end

      when Crystal::RegexLiteral
        dest = allocator.alloc_temp
        pat_str = node.value.is_a?(Crystal::StringLiteral) ? node.value.as(Crystal::StringLiteral).value : node.value.to_s
        str_idx = add_string(pat_str)
        const_idx = add_constant(ConstValue.new(ConstType::String, int_val: str_idx, str_val: pat_str))
        pat_reg = allocator.alloc_temp
        instructions << Instruction.encode_ab_imm(Opcode::LoadConst, pat_reg, const_idx.to_u16)
        instr_val = Instruction.call_native_raw(dest, pat_reg, NativeId::RegexNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(pat_reg)
        dest

      when Crystal::Case
        compile_case(node, allocator, instructions, fn)

      else
        dest = allocator.alloc_temp
        instructions << Instruction.encode_load_nil(dest)
        dest
      end
    end
  end
end
