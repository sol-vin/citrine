require "compiler/crystal/syntax"
require "./error"

module Citrine
  class ParsedProgram
    property defs : Hash(String, Crystal::Def)
    property structs : Hash(String, Crystal::ClassDef)
    property top_level_nodes : Array(Crystal::ASTNode)
    property main_loop_body : Crystal::ASTNode?
    property filename : String?

    def initialize(@filename : String? = nil)
      @defs = {} of String => Crystal::Def
      @structs = {} of String => Crystal::ClassDef
      @top_level_nodes = [] of Crystal::ASTNode
      @main_loop_body = nil
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
      when Crystal::Def
        program.defs[node.name] = node
      when Crystal::ClassDef
        program.structs[node.name.to_s] = node
      when Crystal::Call
        if node.name == "main_loop" && (node.obj.nil? || node.obj.to_s == "Citrine")
          if block = node.block
            program.main_loop_body = block.body
          end
        elsif node.name == "require"
          # Skip require statements for now (e.g. require "citrine")
        else
          program.top_level_nodes << node
        end
      when Crystal::Nop
        # Skip empty
      else
        program.top_level_nodes << node
      end
    end
  end
end
