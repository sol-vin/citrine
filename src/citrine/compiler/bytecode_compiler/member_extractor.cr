require "compiler/crystal/syntax"
require "./types"

module Citrine
  class BytecodeCompiler
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
            cls_info.included_module_ids.concat(mod_info.included_module_ids)
            cls_info.included_module_ids.uniq!
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
          if ret = child.return_type
            ret_s = ret.to_s
            ret_s = ret_s.split("::").last if ret_s.includes?("::")
            cls_info.method_return_types[child.name] = ret_s
          end
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
              if (res = arg.restriction)
                res_s = res.to_s
                res_s = res_s.split("::").last if res_s.includes?("::")
                cls_info.field_types[clean_name] = res_s
              end
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
                cls_info.included_module_ids.concat(mod_info.included_module_ids)
                cls_info.included_module_ids.uniq!
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
            if prop_arg.is_a?(Crystal::TypeDeclaration)
              type_s = prop_arg.declared_type.to_s
              type_s = type_s.split("::").last if type_s.includes?("::")
              cls_info.field_types[prop_name] = type_s
              cls_info.method_return_types[prop_name] = type_s
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
      nodes.each do |raw_child|
        child = raw_child
        while child.is_a?(Crystal::VisibilityModifier)
          child = child.exp
        end
        if child.is_a?(Crystal::Include)
          inc_name = child.name.to_s
          if inc_mod = @modules[inc_name]?
            if mod_info
              mod_info.included_module_ids << inc_mod.module_id
              mod_info.included_module_ids.concat(inc_mod.included_module_ids)
              mod_info.included_module_ids.uniq!
              inc_mod.methods.each do |m_name, m_def|
                mod_info.methods[m_name] ||= m_def
              end
            end
          end
        elsif child.is_a?(Crystal::Extend)
          inc_name = child.name.to_s
          if inc_mod = @modules[inc_name]?
            if mod_info
              inc_mod.methods.each do |m_name, m_def|
                mod_info.methods[m_name] ||= m_def
              end
            end
          end
        elsif child.is_a?(Crystal::Def)
          fn_name = "#{mod_name}.#{child.name}"
          @program_defs[fn_name] = child
          @program_defs["#{mod_name}::#{child.name}"] = child
          mod_info.try { |m| m.methods[child.name] = child }
        elsif child.is_a?(Crystal::Assign)
          c_name = child.target.to_s
          @program_constants["#{mod_name}::#{c_name}"] = child.value
          @program_constants[c_name] = child.value
        elsif child.is_a?(Crystal::Call) && (child.name == "include" || child.name == "extend") && child.args.size > 0
          inc_name = child.args[0].to_s
          if inc_mod = @modules[inc_name]?
            if mod_info
              if child.name == "include"
                mod_info.included_module_ids << inc_mod.module_id
                mod_info.included_module_ids.concat(inc_mod.included_module_ids)
                mod_info.included_module_ids.uniq!
              end
              inc_mod.methods.each do |m_name, m_def|
                mod_info.methods[m_name] ||= m_def
              end
            end
          end
        end
      end
    end
  end
end
