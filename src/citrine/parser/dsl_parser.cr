require "compiler/crystal/syntax"
require "./error"
require "../compiler/macro_expander"
require "../ast/vm_context"

module Citrine
  class ParsedProgram
    property defs : Hash(String, Crystal::Def)
    property structs : Hash(String, Crystal::ClassDef)
    property modules : Hash(String, Crystal::ModuleDef)
    property enums : Hash(String, Crystal::EnumDef)
    property top_level_nodes : Array(Crystal::ASTNode)
    property main_loop_body : Crystal::ASTNode?
    property filename : String?
    property constants : Hash(String, Crystal::ASTNode)
    property loaded_requires : Set(String)
    property vm_contexts : Hash(String, VmContextDef)
    property active_context_name : String?

    def initialize(@filename : String? = nil)
      @defs = {} of String => Crystal::Def
      @structs = {} of String => Crystal::ClassDef
      @modules = {} of String => Crystal::ModuleDef
      @enums = {} of String => Crystal::EnumDef
      @constants = {} of String => Crystal::ASTNode
      @top_level_nodes = [] of Crystal::ASTNode
      @main_loop_body = nil
      @loaded_requires = Set(String).new
      @vm_contexts = {} of String => VmContextDef
      @active_context_name = nil
    end
  end

  class DslParser
    getter filename : String?
    property current_context : VmContextDef? = nil
    property in_main_loop_parse : Bool = false

    def initialize(@filename : String? = nil)
    end

    def parse(source : String, existing_program : ParsedProgram? = nil) : ParsedProgram
      program = existing_program || ParsedProgram.new(@filename)
      if (fn = @filename) && existing_program.nil?
        canon = File.realpath(fn) rescue fn
        program.loaded_requires << canon
      end

      begin
        parser = Crystal::Parser.new(source)
        parser.filename = @filename
        ast = parser.parse
      rescue ex : Crystal::SyntaxException
        raise ParseError.new(
          ex.message || "Crystal syntax error",
          filename: @filename,
          line_number: ex.line_number,
          column_number: ex.column_number
        )
      end

      expander = MacroExpander.new(@filename)
      ast = expander.expand(ast)

      process_node(ast, program)
      program
    end

    private def process_node(node : Crystal::ASTNode, program : ParsedProgram)
      process_top_level(node, program)
    end

    private def process_top_level(node : Crystal::ASTNode, program : ParsedProgram, namespace : Array(String) = [] of String)
      case node
      when Crystal::Expressions
        i = 0
        while i < node.expressions.size
          child = node.expressions[i]
          if child.is_a?(Crystal::Annotation) && child.path.to_s == "Context"
            ctx_names = child.args.map { |a| extract_name(a) }.compact
            ctx_names = ["default"] if ctx_names.empty?

            next_child = node.expressions[i + 1]?
            if next_child.is_a?(Crystal::Require)
              ctx_names.each do |cname|
                ctx = program.vm_contexts[cname] ||= VmContextDef.new(cname, (program.vm_contexts.size + 1).to_u16)
                old_ctx = @current_context
                @current_context = ctx
                handle_require(next_child.string, program)
                @current_context = old_ctx
              end
              i += 2
              next
            elsif next_child
              ctx_names.each do |cname|
                ctx = program.vm_contexts[cname] ||= VmContextDef.new(cname, (program.vm_contexts.size + 1).to_u16)
                old_ctx = @current_context
                @current_context = ctx
                process_top_level(next_child, program, namespace)
                @current_context = old_ctx
              end
              i += 2
              next
            end
          end

          process_top_level(child, program, namespace)
          i += 1
        end
      when Crystal::Def
        if namespace.empty?
          fn_names = [] of String
          if rec = node.receiver
            rec_str = rec.to_s
            fn_names << "#{rec_str}.#{node.name}"
            fn_names << "#{rec_str}::#{node.name}"
          else
            fn_names << node.name
          end
          fn_names.each do |fname|
            if ctx = @current_context
              ctx.defs[fname] = node
            end
            program.defs[fname] = node
          end
        end
      when Crystal::ClassDef
        cls_names = [] of String
        cls_names << node.name.to_s
        unless namespace.empty?
          (0...namespace.size).each do |i|
            cls_names << (namespace[i..-1] + [node.name.to_s]).join("::")
          end
        end
        cls_names.uniq!
        cls_names.each do |cname|
          if existing = program.structs[cname]?
            existing_nodes = existing.body.is_a?(Crystal::Expressions) ? existing.body.as(Crystal::Expressions).expressions : [existing.body].compact
            new_nodes = node.body.is_a?(Crystal::Expressions) ? node.body.as(Crystal::Expressions).expressions : [node.body].compact
            merged_body = Crystal::Expressions.new(existing_nodes + new_nodes)
            merged_sc = node.superclass || existing.superclass
            merged_cls = Crystal::ClassDef.new(existing.name, merged_body, merged_sc, existing.type_vars, existing.abstract?, existing.struct?)
            if ctx = @current_context
              ctx.structs[cname] = merged_cls
            end
            program.structs[cname] = merged_cls
          else
            if ctx = @current_context
              ctx.structs[cname] = node
            end
            program.structs[cname] = node
          end
        end
        if node.body && !node.body.is_a?(Crystal::Nop)
          process_top_level(node.body, program, namespace + [node.name.to_s])
        end
      when Crystal::ModuleDef
        mod_names = [] of String
        mod_names << node.name.to_s
        unless namespace.empty?
          (0...namespace.size).each do |i|
            mod_names << (namespace[i..-1] + [node.name.to_s]).join("::")
          end
        end
        mod_names.uniq!
        mod_names.each do |mname|
          if existing = program.modules[mname]?
            existing_nodes = existing.body.is_a?(Crystal::Expressions) ? existing.body.as(Crystal::Expressions).expressions : [existing.body].compact
            new_nodes = node.body.is_a?(Crystal::Expressions) ? node.body.as(Crystal::Expressions).expressions : [node.body].compact
            merged_body = Crystal::Expressions.new(existing_nodes + new_nodes)
            merged_mod = Crystal::ModuleDef.new(existing.name, merged_body, existing.type_vars)
            if ctx = @current_context
              ctx.modules[mname] = merged_mod
            end
            program.modules[mname] = merged_mod
          else
            if ctx = @current_context
              ctx.modules[mname] = node
            end
            program.modules[mname] = node
          end
        end
        if node.body && !node.body.is_a?(Crystal::Nop)
          process_top_level(node.body, program, namespace + [node.name.to_s])
        end
      when Crystal::EnumDef
        ename = node.name.to_s
        enum_names = [ename]
        unless namespace.empty?
          (0...namespace.size).each do |i|
            enum_names << (namespace[i..-1] + [ename]).join("::")
          end
        end
        enum_names.uniq!
        enum_names.each do |n|
          program.enums[n] = node
        end
      when Crystal::Alias
        aname = node.name.to_s
        target = node.value.to_s
        target_struct = program.structs[target]?
        unless target_struct
          unless namespace.empty?
            (0...namespace.size).each do |i|
              cand = (namespace[i..-1] + [target]).join("::")
              if found = program.structs[cand]?
                target_struct = found
                break
              end
            end
          end
        end
        if target_struct
          alias_names = [aname]
          unless namespace.empty?
            (0...namespace.size).each do |i|
              alias_names << (namespace[i..-1] + [aname]).join("::")
            end
          end
          alias_names.each do |n|
            program.structs[n] = target_struct
            if ctx = @current_context
              ctx.structs[n] = target_struct
            end
          end
        end
      when Crystal::Require
        handle_require(node.string, program)
      when Crystal::Assign
        target_str = node.target.to_s
        is_const_name = target_str[0]?.try(&.uppercase?) || false
        if is_const_name
          short_name = target_str.split("::").last
          full_name = namespace.empty? ? target_str : "#{namespace.join("::")}::#{target_str}"
          program.constants[full_name] = node.value
          program.constants[short_name] = node.value
        end
        program.top_level_nodes << node if namespace.empty?
      when Crystal::Call
        if node.name == "main_loop" && (node.obj.nil? || node.obj.to_s == "Citrine")
          if block = node.block
            program.main_loop_body = block.body
            old_loop = @in_main_loop_parse
            @in_main_loop_parse = true
            process_top_level(block.body, program, namespace)
            @in_main_loop_parse = old_loop
          end
          program.top_level_nodes << node if namespace.empty?
          return
        elsif (node.name == "context" || node.name == "vm_context" || node.name == "make_vm_context") && (node.obj.nil? || node.obj.to_s == "Citrine")
          if @in_main_loop_parse
            loc = node.location
            raise ParseError.new(
              "Context declarations cannot be placed inside main_loop. Declare contexts at the top-level.",
              filename: @filename,
              line_number: loc.try(&.line_number),
              column_number: loc.try(&.column_number)
            )
          end
          ctx_name = extract_name(node.args.first?) || "default"
          ctx = program.vm_contexts[ctx_name] ||= VmContextDef.new(ctx_name, (program.vm_contexts.size + 1).to_u16)
          if block = node.block
            old_ctx = @current_context
            @current_context = ctx
            process_top_level(block.body, program, namespace)
            @current_context = old_ctx
          end
          return
        elsif node.name == "set_vm_context" && (node.obj.nil? || node.obj.to_s == "Citrine")
          ctx_name = extract_name(node.args.first?)
          program.active_context_name = ctx_name
          program.top_level_nodes << node if namespace.empty?
          return
        end
        program.top_level_nodes << node if namespace.empty?
      when Crystal::Nop
        # Skip empty
      else
        program.top_level_nodes << node if namespace.empty?
      end
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

    private def handle_require(req_name : String, program : ParsedProgram)
      if req_name == "citrine" || req_name.ends_with?("stubs/citrine") || req_name.ends_with?("stubs/citrine.cr")
        program.loaded_requires << "citrine"
        return
      end

      if ctx = @current_context
        ctx.requires << req_name
      end

      target_file : String? = nil
      if req_name.starts_with?("citrine/") || req_name.starts_with?("opal/")
        candidates = [
          File.expand_path("../../stubs/#{req_name}.cr", __DIR__),
          File.expand_path("../../../lib/#{req_name}.cr", __DIR__),
          File.expand_path("../../../lib/#{req_name}/src/#{req_name}.cr", __DIR__),
          File.expand_path("../../../lib/opal/src/#{req_name}.cr", __DIR__)
        ]
        target_file = candidates.find { |c| File.exists?(c) }
      elsif req_name.starts_with?(".")
        base_dir = @filename ? File.dirname(@filename.not_nil!) : "."
        rel_path = req_name.ends_with?(".cr") ? req_name : "#{req_name}.cr"
        candidate = File.expand_path(rel_path, base_dir)
        target_file = candidate if File.exists?(candidate)
      elsif @filename
        base_dir = File.dirname(@filename.not_nil!)
        rel_path = req_name.ends_with?(".cr") ? req_name : "#{req_name}.cr"
        candidate = File.expand_path(rel_path, base_dir)
        target_file = candidate if File.exists?(candidate)
      end

      if target_file && File.exists?(target_file)
        program.loaded_requires << req_name
        canon_path = File.realpath(target_file) rescue target_file
        return if program.loaded_requires.includes?(canon_path)
        program.loaded_requires << canon_path

        sub_source = File.read(target_file)
        sub_parser = DslParser.new(filename: target_file)
        sub_parser.current_context = @current_context
        sub_parser.parse(sub_source, existing_program: program)
      end
    end
  end
end
