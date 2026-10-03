require "compiler/crystal/syntax"

module Citrine
  # Represents an isolated VM context scope for memory-conscious PS2 modularization
  class VmContextDef
    property name : String
    property id : UInt16
    property requires : Set(String)
    property defs : Hash(String, Crystal::Def)
    property structs : Hash(String, Crystal::ClassDef)
    property modules : Hash(String, Crystal::ModuleDef)
    property top_level_nodes : Array(Crystal::ASTNode)

    def initialize(@name : String, @id : UInt16 = 0_u16)
      @requires = Set(String).new
      @defs = {} of String => Crystal::Def
      @structs = {} of String => Crystal::ClassDef
      @modules = {} of String => Crystal::ModuleDef
      @top_level_nodes = [] of Crystal::ASTNode
    end
  end
end
