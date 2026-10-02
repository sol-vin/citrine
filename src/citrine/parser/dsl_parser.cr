require "compiler/crystal/syntax"
require "./error"
require "../compiler/macro_expander"

module Citrine
  class ParsedProgram
    property defs : Hash(String, Crystal::Def)
    property structs : Hash(String, Crystal::ClassDef)
    property top_level_nodes : Array(Crystal::ASTNode)
    property main_loop_body : Crystal::ASTNode?
    property filename : String?
    property loaded_requires : Set(String)

    def initialize(@filename : String? = nil)
      @defs = {} of String => Crystal::Def
      @structs = {} of String => Crystal::ClassDef
      @top_level_nodes = [] of Crystal::ASTNode
      @main_loop_body = nil
      @loaded_requires = Set(String).new
    end
  end

  class DslParser
    getter filename : String?

    def initialize(@filename : String? = nil)
    end

    def parse(source : String) : ParsedProgram
      program = ParsedProgram.new(@filename)

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

      expander = MacroExpander.new
      ast = expander.expand(ast)

      process_node(ast, program)
      program
    end

    private def process_node(node : Crystal::ASTNode, program : ParsedProgram)
      case node
      when Crystal::Expressions
        node.expressions.each do |child|
          process_top_level(child, program)
        end
      else
        process_top_level(node, program)
      end
    end

    private def process_top_level(node : Crystal::ASTNode, program : ParsedProgram)
      case node
      when Crystal::Expressions
        node.expressions.each do |child|
          process_top_level(child, program)
        end
      when Crystal::Def
        program.defs[node.name] = node
      when Crystal::ClassDef
        program.structs[node.name.to_s] = node
      when Crystal::Require
        handle_require(node.string, program)
      when Crystal::Call
        if node.name == "main_loop" && (node.obj.nil? || node.obj.to_s == "Citrine")
          if block = node.block
            program.main_loop_body = block.body
          end
        end
        program.top_level_nodes << node
      when Crystal::Nop
        # Skip empty
      else
        program.top_level_nodes << node
      end
    end

    private def handle_require(req_name : String, program : ParsedProgram)
      if req_name == "citrine" || req_name.ends_with?("stubs/citrine") || req_name.ends_with?("stubs/citrine.cr")
        program.loaded_requires << "citrine"
        return
      end
      return if program.loaded_requires.includes?(req_name)
      program.loaded_requires << req_name

      target_file : String? = nil
      if req_name.starts_with?("citrine/")
        candidate = File.expand_path("../../stubs/#{req_name}.cr", __DIR__)
        target_file = candidate if File.exists?(candidate)
      elsif req_name.starts_with?(".") && @filename
        rel_path = req_name.ends_with?(".cr") ? req_name : "#{req_name}.cr"
        candidate = File.expand_path(rel_path, File.dirname(@filename.not_nil!))
        target_file = candidate if File.exists?(candidate)
      end

      if target_file && File.exists?(target_file)
        sub_source = File.read(target_file)
        sub_parser = DslParser.new(filename: target_file)
        sub_prog = sub_parser.parse(sub_source)

        sub_prog.defs.each { |k, v| program.defs[k] = v }
        sub_prog.structs.each { |k, v| program.structs[k] = v }
        sub_prog.top_level_nodes.each { |n| program.top_level_nodes << n }
        sub_prog.loaded_requires.each { |r| program.loaded_requires << r }
      end
    end
  end
end
