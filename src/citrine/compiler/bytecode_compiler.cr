require "compiler/crystal/syntax"
require "./opcode"
require "./register_alloc"
require "./source_map"
require "./budget_checker"
require "./optimizer"
require "../ast/types"
require "../parser/dsl_parser"
require "../mips/assembler"

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

    private def ensure_class_extracted(cls_name : String, program : ParsedProgram)
      return if @classes.has_key?(cls_name)
      cls_node = program.structs[cls_name]?
      return unless cls_node

      if sc = cls_node.superclass
        sc_name = sc.to_s
        sc_name = sc_name[2..-1] if sc_name.starts_with?("::")
        ensure_class_extracted(sc_name, program)
      end

      cls_info = ClassInfo.new((@classes.size + 1).to_u32, cls_name)
      if sc = cls_node.superclass
        sc_name = sc.to_s
        sc_name = sc_name[2..-1] if sc_name.starts_with?("::")
        if sc_info = @classes[sc_name]?
          cls_info.superclass_id = sc_info.class_id
          cls_info.superclass_name = sc_name
          sc_info.fields.each do |fname, fidx|
            cls_info.fields[fname] = fidx
          end
        end
      end

      extract_class_members(cls_node, cls_info)
      @classes[cls_name] = cls_info
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
            has_at_args = child.args.any? { |a| a.name.starts_with?("@") }
            child.args.each do |arg|
              clean_name = arg.name.gsub(/^@/, "")
              ivar_name = "@#{clean_name}"
              if arg.name.starts_with?("@") || (!has_at_args && child.name == "initialize" && cls_info.fields.has_key?(ivar_name))
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
        elsif child.is_a?(Crystal::Assign)
          c_name = child.target.to_s
          @program_constants["#{mod_name}::#{c_name}"] = child.value
          @program_constants[c_name] = child.value
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

    private def compile_main_loop(
      call_node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      ctx_name : String? = nil
      if named = call_node.named_args
        named.each do |na|
          if na.name == "context"
            ctx_name = extract_name(na.value)
          end
        end
      end
      if ctx_name.nil? && call_node.args.size > 0
        ctx_name = extract_name(call_node.args.first)
      end
      if ctx_name.nil?
        if (p = @program) && p.vm_contexts.size > 0
          ctx_name = p.vm_contexts.keys.first
        else
          ctx_name = "default"
        end
      end

      # Context switch native call before loop starts
      ctx_id = @program.try(&.vm_contexts[ctx_name]?.try(&.id)) || 1_u16
      subsys_mask = compute_subsys_mask(ctx_name)

      ctx_reg = allocator.alloc_temp
      mask_reg = allocator.alloc_temp
      instructions << Instruction.encode_load_int(ctx_reg, ctx_id.to_u16)
      instructions << Instruction.encode_load_int(mask_reg, (subsys_mask & 0xFFFF_u32).to_u16)
      instructions << Instruction.encode_call_native(ctx_reg, 2_u8, NativeId::ContextSet.value)
      allocator.free_temp(ctx_reg)
      allocator.free_temp(mask_reg)

      old_loop_ctx = @active_loop_context
      old_in_loop = @in_main_loop
      @active_loop_context = ctx_name
      @in_main_loop = true

      loop_break_jumps = [] of Int32
      @loop_break_jumps.push(loop_break_jumps)

      loop_start_offset = instructions.size

      # Check window_open?
      cond_reg = allocator.alloc_temp
      native_id = NativeId::WindowOpen.value
      instructions << Instruction.encode_call_native(cond_reg, 0_u8, native_id)

      # Branch if false to exit
      jump_exit_idx = instructions.size
      instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

      # Body
      body = call_node.block.not_nil!.body
      body_reg = compile_node(body, allocator, instructions, fn)
      allocator.free_temp(body_reg)

      # Loop back
      loop_end_offset = instructions.size
      back_offset = (loop_start_offset - loop_end_offset - 1).to_i16
      instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

      # Patch exit jump
      exit_offset = (instructions.size - jump_exit_idx - 1).to_i16
      instructions[jump_exit_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)
      allocator.free_temp(cond_reg)

      # Patch all break / exit jumps!
      loop_break_jumps.each do |j_idx|
        b_offset = (instructions.size - j_idx - 1).to_i16
        instructions[j_idx] = Instruction.encode_branch(Opcode::Jump, 0_u8, b_offset)
      end
      @loop_break_jumps.pop

      @active_loop_context = old_loop_ctx
      @in_main_loop = old_in_loop

      ret_reg = allocator.alloc_temp
      instructions << Instruction.encode_load_nil(ret_reg)
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
            instructions << Instruction.encode_load_int(dest, v64.to_u16!)
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
          instructions << Instruction.encode_load_int(dest, val.int_val.to_u16!)
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
        target_name = node.to.to_s
        target_id = resolve_type_id(target_name) || 0_u32
        tid_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(tid_reg, target_id.to_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, obj_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::TypeAsCast)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(obj_reg)
        allocator.free_temp(tid_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
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
              instructions << Instruction.encode_cmp(CompareSubOp::Ge, ge_reg, cond_reg, from_reg)

              le_reg = allocator.alloc_temp
              if c.exclusive?
                instructions << Instruction.encode_cmp(CompareSubOp::Lt, le_reg, cond_reg, to_reg)
              else
                instructions << Instruction.encode_cmp(CompareSubOp::Le, le_reg, cond_reg, to_reg)
              end

              range_match = allocator.alloc_temp
              instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::And.value, range_match, ge_reg, le_reg)
              allocator.free_temp(from_reg)
              allocator.free_temp(to_reg)
              allocator.free_temp(ge_reg)
              allocator.free_temp(le_reg)

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_jump_if_false(range_match, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_jump_if_true(range_match, 0_i16)
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
                instructions << Instruction.encode_load_bool(type_match, false)
              elsif target_ids.size == 1
                tid_reg = allocator.alloc_temp
                instructions << Instruction.encode_load_int(tid_reg, target_ids[0].to_u16)
                seq_base = allocator.alloc_contiguous(2)
                instructions << Instruction.encode_abc(Opcode::Move, seq_base, cond_reg, 0_u8)
                instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
                instr_val = Instruction.call_native_raw(type_match, seq_base, NativeId::TypeIsA)
                instructions << Instruction.new(instr_val)
                allocator.free_temp(tid_reg)
                allocator.free_temp(seq_base)
                allocator.free_temp((seq_base + 1).to_u8)
              else
                instructions << Instruction.encode_load_bool(type_match, false)
                tid_jump_ends = [] of Int32
                target_ids.each do |tid|
                  tid_reg = allocator.alloc_temp
                  instructions << Instruction.encode_load_int(tid_reg, tid.to_u16)
                  seq_base = allocator.alloc_contiguous(2)
                  instructions << Instruction.encode_abc(Opcode::Move, seq_base, cond_reg, 0_u8)
                  instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, tid_reg, 0_u8)
                  cur_check = allocator.alloc_temp
                  instr_val = Instruction.call_native_raw(cur_check, seq_base, NativeId::TypeIsA)
                  instructions << Instruction.new(instr_val)
                  allocator.free_temp(tid_reg)
                  allocator.free_temp(seq_base)
                  allocator.free_temp((seq_base + 1).to_u8)

                  j_next = instructions.size
                  instructions << Instruction.encode_jump_if_false(cur_check, 0_i16)
                  instructions << Instruction.encode_load_bool(type_match, true)
                  j_done = instructions.size
                  instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
                  tid_jump_ends << j_done
                  instructions[j_next] = Instruction.encode_jump_if_false(cur_check, (instructions.size - j_next - 1).to_i16)
                  allocator.free_temp(cur_check)
                end
                tid_end_pos = instructions.size
                tid_jump_ends.each do |tje|
                  instructions[tje] = Instruction.encode_branch(Opcode::Jump, 0_u8, (tid_end_pos - tje - 1).to_i16)
                end
              end

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_jump_if_false(type_match, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_jump_if_true(type_match, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(type_match)

            else
              val_reg = compile_node(c, allocator, instructions, fn)
              eq_reg = allocator.alloc_temp
              instructions << Instruction.encode_cmp(CompareSubOp::Eq, eq_reg, cond_reg, val_reg)
              allocator.free_temp(val_reg)

              if is_last_cond
                j = instructions.size
                instructions << Instruction.encode_jump_if_false(eq_reg, 0_i16)
                next_when_jump_patches << j
              else
                j = instructions.size
                instructions << Instruction.encode_jump_if_true(eq_reg, 0_i16)
                body_jump_patches << j
              end
              allocator.free_temp(eq_reg)
            end
          end

          cur_pos = instructions.size
          body_jump_patches.each do |bp|
            instructions[bp] = Instruction.encode_jump_if_true(instructions[bp].dst, (cur_pos - bp - 1).to_i16)
          end

          body_reg = compile_node(w.body, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, body_reg, 0_u8)
          allocator.free_temp(body_reg)

          j_exit = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
          exit_jumps << j_exit

          after_pos = instructions.size
          next_when_jump_patches.each do |np|
            instructions[np] = Instruction.encode_jump_if_false(instructions[np].dst, (after_pos - np - 1).to_i16)
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
              instructions << Instruction.encode_jump_if_false(cond_res, 0_i16)
              next_when_jump_patches << j
            else
              j = instructions.size
              instructions << Instruction.encode_jump_if_true(cond_res, 0_i16)
              body_jump_patches << j
            end
            allocator.free_temp(cond_res)
          end

          cur_pos = instructions.size
          body_jump_patches.each do |bp|
            instructions[bp] = Instruction.encode_jump_if_true(instructions[bp].dst, (cur_pos - bp - 1).to_i16)
          end

          body_reg = compile_node(w.body, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, body_reg, 0_u8)
          allocator.free_temp(body_reg)

          j_exit = instructions.size
          instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
          exit_jumps << j_exit

          after_pos = instructions.size
          next_when_jump_patches.each do |np|
            instructions[np] = Instruction.encode_jump_if_false(instructions[np].dst, (after_pos - np - 1).to_i16)
          end
        end
      end

      if el = node.else
        if !el.is_a?(Crystal::Nop)
          el_reg = compile_node(el, allocator, instructions, fn)
          instructions << Instruction.encode_abc(Opcode::Move, dest, el_reg, 0_u8)
          allocator.free_temp(el_reg)
        else
          instructions << Instruction.encode_load_nil(dest)
        end
      else
        instructions << Instruction.encode_load_nil(dest)
      end

      end_pos = instructions.size
      exit_jumps.each do |ej|
        instructions[ej] = Instruction.encode_branch(Opcode::Jump, 0_u8, (end_pos - ej - 1).to_i16)
      end

      dest
    end

    private def compile_error(message : String, node : Crystal::ASTNode? = nil) : NoReturn
      loc = node.try(&.location)
      raise CompileError.new(
        message,
        filename: @filename,
        line_number: loc.try(&.line_number),
        column_number: loc.try(&.column_number)
      )
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


    private def compile_call(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp

      if node.name == "asm" && (node.obj.nil? || node.obj.to_s == "Citrine")
        asm_lines = [] of String
        node.args.each do |arg|
          if arg.is_a?(Crystal::StringLiteral)
            asm_lines << arg.value
          elsif arg.is_a?(Crystal::StringInterpolation)
            text = String.build do |sb|
              arg.expressions.each do |piece|
                sb << piece.value if piece.is_a?(Crystal::StringLiteral)
              end
            end
            asm_lines << text
          elsif arg.is_a?(Crystal::NumberLiteral)
            asm_lines << arg.value
          else
            compile_error("asm arguments must be string or numeric literals (e.g. asm(\"sync.l\") or asm(0x0000000F))", arg)
          end
        end

        assembled_words = [] of UInt32
        asm_lines.each do |block_text|
          begin
            words = Citrine::MIPS::Assembler.assemble(block_text)
            assembled_words.concat(words)
          rescue ex
            compile_error("Inline assembly syntax error: #{ex.message}", node)
          end
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
        return dest
      end

      obj_str = node.obj ? node.obj.to_s : ""

      if @in_main_loop
        if node.name == "exit" && (obj_str.empty? || obj_str == "Citrine")
          if @loop_break_jumps.size > 0
            dest = allocator.alloc_temp
            j = instructions.size
            instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, 0_i16)
            @loop_break_jumps.last << j
            instructions << Instruction.encode_load_nil(dest)
            return dest
          end
        end
        if (node.name == "switch_context" || node.name == "set_vm_context") && (obj_str.empty? || obj_str == "Citrine")
          compile_error("Safety Error: Cannot switch context inside active main_loop! Exit the loop first.", node)
        end
        if (node.name == "context" || node.name == "vm_context" || node.name == "make_vm_context") && (obj_str.empty? || obj_str == "Citrine")
          compile_error("Compile Error: Context definitions cannot be placed inside main_loop.", node)
        end
        if active_ctx = @active_loop_context
          validate_context_subsystem_call(obj_str, node.name, active_ctx, node)
        end
      end

      is_collection_push = obj_str.downcase.includes?("arr") || obj_str.downcase.includes?("list") ||
                           obj_str.downcase.includes?("io") || obj_str.downcase.includes?("buf") ||
                           (node.obj.is_a?(Crystal::Var) && @var_types[node.obj.as(Crystal::Var).name]?.try { |t| t.starts_with?("Array") || t.includes?("IO") }) ||
                           node.obj.is_a?(Crystal::ArrayLiteral) || node.args.first?.is_a?(Crystal::StringLiteral) ||
                           (node.name == "<<" && node.args.first?.try { |arg| !arg.is_a?(Crystal::NumberLiteral) && !(arg.is_a?(Crystal::Var) && @var_types[arg.as(Crystal::Var).name]? == "Int") })

      if ["+", "-", "*", "/", "//", "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "&*", "&+", "&-"].includes?(node.name) && node.obj && node.args.size == 1 && !(node.name == "<<" && is_collection_push)
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
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::StringConcat)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(left_reg)
          allocator.free_temp(right_reg)
          allocator.free_temp(seq_base)
          allocator.free_temp((seq_base + 1).to_u8)
          return dest
        end

        if (node.name == "/" || node.name == "//" || node.name == "%") && node.args[0].is_a?(Crystal::NumberLiteral)
          num_str = node.args[0].as(Crystal::NumberLiteral).value
          if num_str == "0" || num_str == "0.0"
            compile_error("Division by zero is undefined", node)
          end
        end

        left_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        right_reg = compile_node(node.args[0], allocator, instructions, fn)
        op, subop = case node.name
                    when "+", "&+" then {Opcode::Add, AddSubOp::AddI32.value}
                    when "-", "&-" then {Opcode::Sub, SubSubOp::SubI32.value}
                    when "*", "&*" then {Opcode::Mul, MulSubOp::MulLo.value}
                    when "/", "//" then {Opcode::DivMod, DivModSubOp::DivS32.value}
                    when "%"       then {Opcode::DivMod, DivModSubOp::ModS32.value}
                    when "&"       then {Opcode::Bitwise, BitwiseSubOp::And.value}
                    when "|"       then {Opcode::Bitwise, BitwiseSubOp::Or.value}
                    when "^"       then {Opcode::Bitwise, BitwiseSubOp::Xor.value}
                    when "<<"      then {Opcode::Shift, ShiftSubOp::Sll.value}
                    when ">>"      then {Opcode::Shift, ShiftSubOp::Sra.value}
                    when "=="      then {Opcode::Compare, CompareSubOp::Eq.value}
                    when "!="      then {Opcode::Compare, CompareSubOp::Ne.value}
                    when "<"       then {Opcode::Compare, CompareSubOp::Lt.value}
                    when "<="      then {Opcode::Compare, CompareSubOp::Le.value}
                    when ">"       then {Opcode::Compare, CompareSubOp::Gt.value}
                    when ">="      then {Opcode::Compare, CompareSubOp::Ge.value}
                    else {Opcode::Add, AddSubOp::AddI32.value}
                    end
        instructions << Instruction.encode_rrr(op, subop, dest, left_reg, right_reg)
        allocator.free_temp(left_reg)
        allocator.free_temp(right_reg)
        return dest
      elsif node.name == "!" && node.obj
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        false_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_bool(false_reg, false)
        instructions << Instruction.encode_cmp(CompareSubOp::Eq, dest, inner_reg, false_reg)
        allocator.free_temp(inner_reg)
        allocator.free_temp(false_reg)
        return dest
      elsif node.name == "-" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_rrr(Opcode::Sub, SubSubOp::NegI32.value, dest, inner_reg, 0_u8)
        allocator.free_temp(inner_reg)
        return dest
      elsif node.name == "~" && node.obj && node.args.empty?
        inner_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Nor.value, dest, inner_reg, 0_u8)
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
        loop_ret = compile_main_loop(node, allocator, instructions, fn)
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
        instructions << Instruction.encode_yield
        return dest
      end

      # Concurrency: Channel.new(cap)
      if (obj_str.includes?("Channel") || node.name == "channel_new") && (node.name == "new" || node.name == "channel_new")
        cap_reg = if node.args.size > 0
                    compile_node(node.args[0], allocator, instructions, fn)
                  else
                    r = allocator.alloc_temp
                    instructions << Instruction.encode_load_int(r, 32_u16)
                    r
                  end
        instr_val = Instruction.call_native_raw(dest, cap_reg, NativeId::ChannelNew)
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
        instr_val = Instruction.call_native_raw(dest, arg0, NativeId::ChannelSend)
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
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelReceive)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.try_receive
      if node.name == "try_receive" && node.obj
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelTryReceive)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.size / ch.count
      is_chan = obj_str.downcase.includes?("chan") || node.name == "count"
      if is_chan && node.obj && (node.name == "size" || node.name == "count") && node.args.empty?
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelCount)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Concurrency: ch.capacity
      if node.name == "capacity" && node.obj && node.args.empty?
        ch_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ch_reg, NativeId::ChannelCapacity)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ch_reg)
        return dest
      end

      # Controller handles: Citrine.player(port) or Citrine.pad(port)
      if (obj_str == "Citrine" || obj_str.empty?) && (node.name == "player" || node.name == "pad")
        if node.args.size != 1
          compile_error("Citrine.#{node.name} requires exactly 1 argument: (port)", node)
        end
        check_port_literal(node.args[0], node.name, node)
        port_reg = compile_node(node.args[0], allocator, instructions, fn)
        instructions << Instruction.encode_abc(Opcode::Move, dest, port_reg, 0_u8)
        allocator.free_temp(port_reg)
        return dest
      end

      # Controller Method Calls on Controller instance (e.g. p1.button_pressed?(Button::Cross))
      if (node.name == "button_pressed?" || node.name == "button_down?" || node.name == "button_released?") && node.obj && obj_str != "Citrine" && !obj_str.includes?("VirtualPad")
        if node.args.size != 1
          compile_error("Controller##{node.name} requires exactly 1 argument: (button)", node)
        end
        ctrl_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        btn_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ctrl_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, btn_reg, 0_u8)
        native_id = case node.name
                    when "button_pressed?"  then NativeId::ButtonPressed
                    when "button_down?"     then NativeId::ButtonDown
                    else                         NativeId::ButtonReleased
                    end
        instr_val = Instruction.call_native_raw(dest, seq_base, native_id)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctrl_reg)
        allocator.free_temp(btn_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Godot-style InputMap Action queries (Action.is_pressed?, Action.is_down?, Action.is_released?)
      if (obj_str == "Action" || obj_str == "Citrine::Action")
        if ["is_pressed?", "is_down?", "is_released?", "is_action_just_pressed", "is_action_pressed", "is_action_just_released"].includes?(node.name)
          if node.args.size != 1
            compile_error("Action.#{node.name} requires exactly 1 argument: (action)", node)
          end
          act_reg = compile_node(node.args[0], allocator, instructions, fn)
          seq_base = allocator.alloc_contiguous(1)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, act_reg, 0_u8)
          native_id = case node.name
                      when "is_pressed?", "is_action_just_pressed" then NativeId::ActionPressed
                      when "is_down?", "is_action_pressed"         then NativeId::ActionDown
                      when "is_released?", "is_action_just_released" then NativeId::ActionReleased
                      else                                         nil
                      end
          if native_id
            instr_val = Instruction.call_native_raw(dest, seq_base, native_id)
            instructions << Instruction.new(instr_val)
            allocator.free_temp(act_reg)
            allocator.free_temp(seq_base)
            return dest
          end
        end
      end

      # Native API Calls (Citrine.draw_rectangle, GL.begin, etc.)
      is_gl_obj = obj_str == "Citrine::GL" || obj_str == "GL"
      is_pad_obj = obj_str == "Citrine" || obj_str.empty? || is_gl_obj || obj_str.includes?("VirtualPad") || obj_str.includes?("VU0") || obj_str.includes?("Audio") || obj_str.includes?("Compute") || obj_str.includes?("Shader") || obj_str.includes?("Draw2D") || obj_str.includes?("Draw3D")
      if is_pad_obj

        if native_id = map_native_call(node.name, is_gl_obj)
          validate_native_call_arity(native_id, node.name, node.args.size, node)


          if (native_id == NativeId::ButtonPressed || native_id == NativeId::ButtonDown || native_id == NativeId::ButtonReleased)
            if node.args.size != 2
              compile_error("Citrine.#{node.name} requires explicit port and button: Citrine.#{node.name}(port, button), Citrine.player(port).#{node.name}(button), or Action.is_pressed?(action)", node)
            end
            check_port_literal(node.args[0], node.name, node)
          elsif native_id == NativeId::GetAnalog
            check_port_literal(node.args[0], "get_analog", node)
            if node.args[1].is_a?(Crystal::NumberLiteral)
              axis_val = node.args[1].as(Crystal::NumberLiteral).value.to_i?
              if axis_val.nil? || axis_val < 0 || axis_val > 3
                compile_error("Invalid analog axis #{node.args[1].as(Crystal::NumberLiteral).value}. Valid axes are 0 (LX), 1 (LY), 2 (RX), 3 (RY).", node)
              end
            end
          elsif native_id == NativeId::SetRumble
            check_port_literal(node.args[0], "set_rumble", node)
          end

          if @release_mode && (native_id == NativeId::Log || native_id == NativeId::DebugLog || native_id == NativeId::SetDebugOverlay)
            instructions << Instruction.encode_load_nil(dest)
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
          instr_val = Instruction.call_native_raw(dest, base_reg, native_id)
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
        instructions << Instruction.encode_vec2_new(dest, x_reg, y_reg)
        allocator.free_temp(x_reg)
        allocator.free_temp(y_reg)
        return dest
      end

      # Color constructors: Color.new(r, g, b, a = 255) or Color.new(packed_u32)
      if (obj_str == "Color" || obj_str == "Citrine::Color") && node.name == "new"
        if node.args.size == 1 && node.args[0].is_a?(Crystal::NumberLiteral)
          num_str = node.args[0].as(Crystal::NumberLiteral).value.gsub("_", "")
          val = if num_str.starts_with?("0x") || num_str.starts_with?("0X")
                  num_str[2..-1].to_u32?(16) || 0_u32
                else
                  num_str.to_u32? || 0_u32
                end
          c_idx = add_constant(ConstValue.new(ConstType::Color, uint_val: val))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, c_idx.to_u16)
          return dest
        end

        all_literals = node.args.all? { |a| a.is_a?(Crystal::NumberLiteral) }
        if all_literals
          parse_u8 = ->(arg : Crystal::ASTNode?, default_val : UInt8) : UInt8 {
            if arg.is_a?(Crystal::NumberLiteral)
              clean = arg.value.gsub(/[^0-9]/, "")
              clean.to_u8? || default_val
            else
              default_val
            end
          }
          r = parse_u8.call(node.args[0]?, 0_u8)
          g = parse_u8.call(node.args[1]?, 0_u8)
          b = parse_u8.call(node.args[2]?, 0_u8)
          a = node.args.size >= 4 ? parse_u8.call(node.args[3]?, 255_u8) : 255_u8
          packed = ColorVal.new(r, g, b, a).to_u32
          c_idx = add_constant(ConstValue.new(ConstType::Color, uint_val: packed))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, dest, c_idx.to_u16)
          return dest
        else
          r_reg = node.args.size > 0 ? compile_node(node.args[0], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 0_u16)
            t
          end
          g_reg = node.args.size > 1 ? compile_node(node.args[1], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 0_u16)
            t
          end
          b_reg = node.args.size > 2 ? compile_node(node.args[2], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 0_u16)
            t
          end
          a_reg = node.args.size > 3 ? compile_node(node.args[3], allocator, instructions, fn) : begin
            t = allocator.alloc_temp
            instructions << Instruction.encode_load_int(t, 255_u16)
            t
          end

          shift8 = allocator.alloc_temp
          instructions << Instruction.encode_load_int(shift8, 8_u16)
          g_sh = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Shift, ShiftSubOp::Sll.value, g_sh, g_reg, shift8)

          shift16 = allocator.alloc_temp
          instructions << Instruction.encode_load_int(shift16, 16_u16)
          b_sh = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Shift, ShiftSubOp::Sll.value, b_sh, b_reg, shift16)

          shift24 = allocator.alloc_temp
          instructions << Instruction.encode_load_int(shift24, 24_u16)
          a_sh = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Shift, ShiftSubOp::Sll.value, a_sh, a_reg, shift24)

          t1 = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Or.value, t1, r_reg, g_sh)
          t2 = allocator.alloc_temp
          instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Or.value, t2, t1, b_sh)
          instructions << Instruction.encode_rrr(Opcode::Bitwise, BitwiseSubOp::Or.value, dest, t2, a_sh)

          allocator.free_temp(r_reg)
          allocator.free_temp(g_reg)
          allocator.free_temp(b_reg)
          allocator.free_temp(a_reg)
          allocator.free_temp(shift8)
          allocator.free_temp(g_sh)
          allocator.free_temp(shift16)
          allocator.free_temp(b_sh)
          allocator.free_temp(shift24)
          allocator.free_temp(a_sh)
          allocator.free_temp(t1)
          allocator.free_temp(t2)
          return dest
        end
      end


      has_class_method = @functions.any? { |f| f.name.ends_with?("##{node.name}") }
      if !has_class_method
        if node.name == "x" && node.obj
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instructions << Instruction.encode_vec2_get_x(dest, obj_reg)
          return dest
        elsif node.name == "y" && node.obj
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          instructions << Instruction.encode_vec2_get_y(dest, obj_reg)
          return dest
        elsif node.name == "x=" && node.obj && node.args.size > 0
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          instructions << Instruction.encode_vec2_set_x(obj_reg, val_reg)
          return obj_reg
        elsif node.name == "y=" && node.obj && node.args.size > 0
          obj_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
          val_reg = compile_node(node.args[0], allocator, instructions, fn)
          instructions << Instruction.encode_vec2_set_y(obj_reg, val_reg)
          return obj_reg
        end
      end


      # times loop: e.g. 10.times do |i| ... end
      if node.name == "times" && node.obj && (block = node.block)
        count_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        if block_arg = block.args.first?
          allocator.allocate_local(block_arg.name)
          local_iter = allocator.get_local(block_arg.name).not_nil!
        else
          local_iter = iter_reg
        end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, count_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        # Assign block arg
        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        # iter += 1
        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)
        return dest
      end

      # Array index read: arr[idx] or custom #[] method dispatch
      if node.name == "[]" && node.obj && node.args.size == 1
        custom_bracket_method = nil
        bracket_recv_type = if node.obj.is_a?(Crystal::Var)
                              @var_types[node.obj.as(Crystal::Var).name]?
                            elsif node.obj.is_a?(Crystal::Path)
                              node.obj.as(Crystal::Path).names.last
                            else
                              nil
                            end

        if bracket_recv_type
          clean_vtype = bracket_recv_type.split("(").first.strip
          clean_vtype = clean_vtype[2..-1] if clean_vtype.starts_with?("::")
          if !clean_vtype.starts_with?("Array") && !clean_vtype.starts_with?("StaticArray")
            cands = [clean_vtype, clean_vtype.split("::").last]
            cands.each do |c|
              if @functions.any? { |f| f.name == "#{c}#[]" }
                custom_bracket_method = "#{c}#[]"
                break
              end
            end
          end
        end

        if custom_bracket_method && (f_idx = @functions.index { |f| f.name == custom_bracket_method })
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

        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        idx_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayGet)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArraySet)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayPush)
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
        instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArrayPop)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array size: arr.size / arr.length
      if (node.name == "size" || node.name == "length") && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array clear: arr.clear
      if node.name == "clear" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, arr_reg, NativeId::ArrayClear)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        return dest
      end

      # Array first: arr.first
      if node.name == "first" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(zero_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array last: arr.last
      if node.name == "last" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        sz_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(sz_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)
        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        idx_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Sub, idx_reg, sz_reg, one_reg)
        allocator.free_temp(sz_reg)
        allocator.free_temp(one_reg)

        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(arr_reg)
        allocator.free_temp(idx_reg)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)
        return dest
      end

      # Array empty?: arr.empty?
      if node.name == "empty?" && node.obj && node.args.empty?
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        sz_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(sz_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instructions << Instruction.encode_cmp(CompareSubOp::Eq, dest, sz_reg, zero_reg)
        allocator.free_temp(arr_reg)
        allocator.free_temp(sz_reg)
        allocator.free_temp(zero_reg)
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
          instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, to_reg)
        else
          instructions << Instruction.encode_cmp(CompareSubOp::Le, cond_reg, iter_reg, to_reg)
        end
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        instructions << Instruction.encode_abc(Opcode::Move, local_iter, iter_reg, 0_u8)
        compile_node(block.body, allocator, instructions, fn)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)

        exit_offset = (instructions.size - exit_jump_idx - 1).to_i16
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, exit_offset)
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
        instr_val = Instruction.call_native_raw(size_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(instr_val)

        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        block_item_reg = if block_arg = block.args.first?
                           allocator.allocate_local(block_arg.name)
                         else
                           allocator.alloc_temp
                         end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, size_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, iter_reg, 0_u8)
        get_val = Instruction.call_native_raw(block_item_reg, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(get_val)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)

        compile_node(block.body, allocator, instructions, fn)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, (instructions.size - exit_jump_idx - 1).to_i16)
        allocator.free_temp(arr_reg)
        allocator.free_temp(size_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)
        return dest
      end

      # Array map: arr.map do |x| ... end
      if node.name == "map" && node.obj && (block = node.block)
        arr_reg = compile_node(node.obj.not_nil!, allocator, instructions, fn)
        size_reg = allocator.alloc_temp
        sz_instr = Instruction.call_native_raw(size_reg, arr_reg, NativeId::ArraySize)
        instructions << Instruction.new(sz_instr)

        # Allocate result array
        res_arr = allocator.alloc_temp
        cap_reg = allocator.alloc_temp
        instructions << Instruction.encode_abc(Opcode::Move, cap_reg, size_reg, 0_u8)
        new_instr = Instruction.call_native_raw(res_arr, cap_reg, NativeId::ArrayNew)
        instructions << Instruction.new(new_instr)
        allocator.free_temp(cap_reg)

        iter_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(iter_reg, 0_u16)

        block_item_reg = if block_arg = block.args.first?
                           allocator.allocate_local(block_arg.name)
                         else
                           allocator.alloc_temp
                         end

        loop_start = instructions.size
        cond_reg = allocator.alloc_temp
        instructions << Instruction.encode_cmp(CompareSubOp::Lt, cond_reg, iter_reg, size_reg)
        exit_jump_idx = instructions.size
        instructions << Instruction.encode_jump_if_false(cond_reg, 0_i16)

        # Item = arr[iter]
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, arr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, iter_reg, 0_u8)
        get_val = Instruction.call_native_raw(block_item_reg, seq_base, NativeId::ArrayGet)
        instructions << Instruction.new(get_val)
        allocator.free_temp(seq_base)
        allocator.free_temp((seq_base + 1).to_u8)

        # Evaluate mapped value
        mapped_val_reg = compile_node(block.body, allocator, instructions, fn)

        # Push to res_arr
        push_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, push_base, res_arr, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (push_base + 1).to_u8, mapped_val_reg, 0_u8)
        dummy_dest = allocator.alloc_temp
        push_instr = Instruction.call_native_raw(dummy_dest, push_base, NativeId::ArrayPush)
        instructions << Instruction.new(push_instr)
        allocator.free_temp(mapped_val_reg)
        allocator.free_temp(push_base)
        allocator.free_temp((push_base + 1).to_u8)
        allocator.free_temp(dummy_dest)

        one_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(one_reg, 1_u16)
        instructions << Instruction.encode_abc(Opcode::Add, iter_reg, iter_reg, one_reg)
        allocator.free_temp(one_reg)

        back_offset = (loop_start - instructions.size - 1).to_i16
        instructions << Instruction.encode_branch(Opcode::Jump, 0_u8, back_offset)
        instructions[exit_jump_idx] = Instruction.encode_jump_if_false(cond_reg, (instructions.size - exit_jump_idx - 1).to_i16)

        allocator.free_temp(arr_reg)
        allocator.free_temp(size_reg)
        allocator.free_temp(iter_reg)
        allocator.free_temp(cond_reg)

        instructions << Instruction.encode_abc(Opcode::Move, dest, res_arr, 0_u8)
        allocator.free_temp(res_arr)
        return dest
      end

      # StaticArray.new / StaticArray(...)
      if obj_str.starts_with?("StaticArray") && node.name == "new"
        sz = 4
        if obj_str =~ /\((\w+),\s*(\d+)\)/
          sz = $2.to_i
        end
        sz_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(sz_reg, sz.to_u16)
        def_val_reg = if node.args.size > 0
                        compile_node(node.args[0], allocator, instructions, fn)
                      else
                        r = allocator.alloc_temp
                        instructions << Instruction.encode_load_nil(r)
                        r
                      end
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, sz_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, def_val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::StaticArrayNew)
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
                 instructions << Instruction.encode_load_int(r, 64_u16)
                 r
               end
        instr_val = Instruction.call_native_raw(dest, arg0, NativeId::MemoryIONew)
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
            instr_val = Instruction.call_native_raw(dest, io_reg, native_op)
            instructions << Instruction.new(instr_val)
          else
            val_reg = compile_node(node.args[0], allocator, instructions, fn)
            seq_base = allocator.alloc_contiguous(2)
            instructions << Instruction.encode_abc(Opcode::Move, seq_base, io_reg, 0_u8)
            instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, val_reg, 0_u8)
            instr_val = Instruction.call_native_raw(dest, seq_base, native_op)
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
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        seq_base = allocator.alloc_contiguous(2)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerGet)
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
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, ptr_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, zero_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerSet)
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
        instr_val = Instruction.call_native_raw(dest, ptr_reg, NativeId::PointerAddress)
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
                     instructions << Instruction.encode_load_int(r, 1_u16)
                     r
                   end
        instr_val = Instruction.call_native_raw(dest, size_reg, NativeId::PointerMalloc)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(size_reg)
        return dest
      end

      # Pointer(T).new(addr)
      if obj_str.starts_with?("Pointer") && node.name == "new" && node.args.size > 0
        addr_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, addr_reg, NativeId::PointerNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(addr_reg)
        return dest
      end

      # Box(T).box(val)
      if obj_str.starts_with?("Box") && node.name == "box" && node.args.size > 0
        val_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, val_reg, NativeId::BoxNew)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(val_reg)
        return dest
      end

      # Box(T).unbox(ptr)
      if obj_str.starts_with?("Box") && node.name == "unbox" && node.args.size > 0
        ptr_reg = compile_node(node.args[0], allocator, instructions, fn)
        instr_val = Instruction.call_native_raw(dest, ptr_reg, NativeId::BoxUnbox)
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
        instr_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextSet)
        instructions << Instruction.new(instr_val)

        # Compile body of block inside context
        compile_node(block.body, allocator, instructions, fn)

        # Auto-rewind/clear context arena on block exit
        clear_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextClear)
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
        instr_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextClear)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ctx_reg)
        return dest
      end

      # Memory Stats: Citrine::Memory.stats / Citrine::Memory.heap_bytes / memory_stats
      if ((node.name == "stats" || node.name == "heap_bytes") && obj_str.ends_with?("Memory")) || node.name == "memory_stats"
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instr_val = Instruction.call_native_raw(dest, zero_reg, NativeId::MemoryStats)
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
        instr_val = Instruction.call_native_raw(dest, ctx_reg, NativeId::ContextSet)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerFree)
        instructions << Instruction.new(instr_val)
        allocator.free_temp(ptr_reg)
        allocator.free_temp(seq_base)
        return dest
      end

      # GC.collect
      if (obj_str == "GC" || obj_str.ends_with?("::GC")) && node.name == "collect"
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instr_val = Instruction.call_native_raw(dest, zero_reg, NativeId::GCCycle)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::RegexNew)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::RegexMatch)
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
        instr_val = Instruction.call_native_raw(match_pos, seq_base, NativeId::RegexMatch)
        instructions << Instruction.new(instr_val)
        zero_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(zero_reg, 0_u16)
        instructions << Instruction.encode_cmp(CompareSubOp::Ge, dest, match_pos, zero_reg)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, s_op)
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
        instr_val = Instruction.call_native_raw(dest, seq_base, s_op)
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
          instr_val = Instruction.call_native_raw(dest, p_reg, NativeId::Panic)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(p_reg)
          return dest
        end
        cid_reg = allocator.alloc_temp
        cnt_reg = allocator.alloc_temp
        is_struct_reg = allocator.alloc_temp
        instructions << Instruction.encode_load_int(cid_reg, cls_info.class_id.to_u16)
        f_count = cls_info.fields.size > 0 ? cls_info.fields.size : 1
        instructions << Instruction.encode_load_int(cnt_reg, f_count.to_u16)
        instructions << Instruction.encode_load_int(is_struct_reg, cls_info.is_struct ? 1_u16 : 0_u16)
        seq_base = allocator.alloc_contiguous(3)
        instructions << Instruction.encode_abc(Opcode::Move, seq_base, cid_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, cnt_reg, 0_u8)
        instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, is_struct_reg, 0_u8)
        obj_val = Instruction.call_native_raw(dest, seq_base, NativeId::ObjectNew)
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

      # Super call: super / super(args...)
      if node.name == "super"
        cls = @current_class
        unless cls && (sc_name = cls.superclass_name)
          compile_error("Cannot call super outside of a subclass method", node)
        end
        m_name = @current_method_name || compile_error("super called outside of a method", node)

        # Look up method in ancestor classes
        super_f_idx : Int32? = nil
        curr_sc : String? = sc_name
        while curr_sc
          cand = "#{curr_sc}##{m_name}"
          if idx = @functions.index { |f| f.name == cand }
            super_f_idx = idx
            break
          end
          curr_sc = @classes[curr_sc]?.try(&.superclass_name)
        end

        unless super_f_idx
          compile_error("super: method '#{m_name}' not found in any superclass of #{cls.name}", node)
        end

        self_reg = @current_self_reg || allocator.get_local("self") || 0_u8

        call_base = allocator.alloc_call_frame(node.args.size + 2)
        instructions << Instruction.encode_abc(Opcode::Move, (call_base + 1).to_u8, self_reg, 0_u8)

        node.args.each_with_index do |arg, i|
          arg_reg = compile_node(arg, allocator, instructions, fn)
          target_reg = (call_base + 2_u8 + i.to_u8).to_u8
          instructions << Instruction.encode_abc(Opcode::Move, target_reg, arg_reg, 0_u8)
          allocator.free_temp(arg_reg)
        end

        dest_call = call_base
        instructions << Instruction.encode_ab_imm(Opcode::Call, dest_call, super_f_idx.to_u16)
        (node.args.size + 1).times { |i| allocator.free_temp((dest_call + 1_u8 + i.to_u8).to_u8) }
        instructions << Instruction.encode_abc(Opcode::Move, dest, dest_call, 0_u8)
        allocator.free_temp(dest_call)
        return dest
      end

      # Instance method call: obj.method(args...)
      if node.obj
        recv_type : String? = nil
        case recv_node = node.obj
        when Crystal::Var
          if recv_node.name == "self" && @current_class
            recv_type = @current_class.try(&.name)
          else
            recv_type = @var_types[recv_node.name]?
          end
        when Crystal::Self
          if @current_class
            recv_type = @current_class.try(&.name)
          end
        when Crystal::Call
          if (recv_node.name == "new" || recv_node.name == "malloc") && (r_obj = recv_node.obj)
            recv_type = r_obj.to_s
          elsif recv_node.name == "as" && recv_node.args.size > 0
            recv_type = recv_node.args.first.to_s
          end
        when Crystal::Cast
          recv_type = recv_node.to.to_s
        when Crystal::NilableCast
          recv_type = recv_node.to.to_s
        end

        matched_method : String? = nil
        if recv_type
          clean_recv = recv_type.split("(").first.strip
          clean_recv = clean_recv[2..-1] if clean_recv.starts_with?("::")
          curr_cls : String? = clean_recv
          while curr_cls
            cand = "#{curr_cls}##{node.name}"
            if @functions.any? { |f| f.name == cand }
              matched_method = cand
              break
            end
            curr_cls = @classes[curr_cls]?.try(&.superclass_name)
          end
        end

        unless matched_method
          @classes.each do |cname, _|
            cand = "#{cname}##{node.name}"
            if @functions.any? { |f| f.name == cand }
              matched_method = cand
              break
            end
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
          instructions << Instruction.encode_load_int(idx_reg, 0_u16)
          c_idx = add_constant(ConstValue.new(ConstType::Int32, int_val: addr_val.to_i32))
          instructions << Instruction.encode_ab_imm(Opcode::LoadConst, addr_reg, c_idx.to_u16)
          seq_base = allocator.alloc_contiguous(3)
          instructions << Instruction.encode_abc(Opcode::Move, seq_base, addr_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 1).to_u8, idx_reg, 0_u8)
          instructions << Instruction.encode_abc(Opcode::Move, (seq_base + 2).to_u8, val_reg, 0_u8)
          instr_val = Instruction.call_native_raw(dest, seq_base, NativeId::PointerSet)
          instructions << Instruction.new(instr_val)
          allocator.free_temp(addr_reg)
          allocator.free_temp(idx_reg)
          allocator.free_temp(val_reg)
          3.times { |i| allocator.free_temp((seq_base + i).to_u8) }
          return dest
        elsif node.args.empty?
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
          return dest
        end
      end

      # Implicit self instance method call: func(args...) within a class instance method
      if node.obj.nil? && (cls = @current_class) && (self_reg = @current_self_reg)
        self_cls : String? = cls.name
        matched_self_method : String? = nil
        while self_cls
          cand = "#{self_cls}##{node.name}"
          if @functions.any? { |f| f.name == cand }
            matched_self_method = cand
            break
          end
          self_cls = @classes[self_cls]?.try(&.superclass_name)
        end

        if matched_self_method && (f_idx = @functions.index { |f| f.name == matched_self_method })
          call_base = allocator.alloc_call_frame(node.args.size + 2)
          dest_call = call_base
          instructions << Instruction.encode_abc(Opcode::Move, (dest_call + 1).to_u8, self_reg, 0_u8)
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

      instructions << Instruction.encode_load_nil(dest)
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

    private def compile_spawn(
      node : Crystal::Call,
      allocator : RegisterAllocator,
      instructions : Array(Instruction),
      fn : CompiledFunction
    ) : UInt8
      dest = allocator.alloc_temp
      block = node.block
      unless block
        instructions << Instruction.encode_load_nil(dest)
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

      instructions << Instruction.encode_spawn_fiber(dest, func_idx.to_u16)
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
      when Crystal::Var
        if @var_types[piece.name]? == "String"
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
        if piece.name == "to_s" || ["strip", "downcase", "upcase"].includes?(piece.name)
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
      when "stop_cdda", "stop_stream", "stop_music", "pause_stream", "pause_music" then NativeId::AudioStopCDDA
      when "cdda_status", "get_cdda_status", "stream_status", "music_status", "music_playing?" then NativeId::AudioGetCDDAStatus
      when "set_volume", "set_audio_volume", "set_cdda_volume", "set_stream_volume", "set_music_volume", "master_volume=" then NativeId::AudioSetVolume
      when "seek_stream", "stream_seek", "seek_music" then NativeId::AudioSeekStream
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
      io.write_bytes(2_u16, IO::ByteFormat::LittleEndian) # Version 2
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
