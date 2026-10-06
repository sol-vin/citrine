require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/draw2d"
require "../src/stubs/citrine/draw3d"
require "../src/stubs/citrine/audio"
require "../src/citrine/parser/dsl_parser"
require "../src/citrine/compiler/bytecode_compiler"

describe "Citrine Require-Driven Context DSL & Sequential Loops" do
  describe "Annotated Require Parser (@[Context(...)])" do
    it "associates require with specified context" do
      source = <<-CR
      require "citrine"

      @[Context(:menu)]
      require "citrine/draw2d"

      @[Context(:game)]
      require "citrine/draw3d"
      CR

      parser = Citrine::DslParser.new
      program = parser.parse(source)

      program.vm_contexts.has_key?("menu").should be_true
      program.vm_contexts["menu"].requires.should contain("citrine/draw2d")

      program.vm_contexts.has_key?("game").should be_true
      program.vm_contexts["game"].requires.should contain("citrine/draw3d")
    end

    it "supports multi-context annotations on a single require" do
      source = <<-CR
      require "citrine"

      @[Context(:menu, :game)]
      require "citrine/audio"
      CR

      parser = Citrine::DslParser.new
      program = parser.parse(source)

      program.vm_contexts["menu"].requires.should contain("citrine/audio")
      program.vm_contexts["game"].requires.should contain("citrine/audio")
    end
  end

  describe "Block-Scoped Context Requires (context(:name) do ... end)" do
    it "registers multiple modular requires and user files within a context block" do
      # Create a temporary user file
      user_file_dir = File.expand_path("../scratch/entities", __DIR__)
      Dir.mkdir_p(user_file_dir)
      user_file_path = File.join(user_file_dir, "hero.cr")
      File.write(user_file_path, <<-HERO
      struct Hero
        property x : Float32
        property y : Float32
        def initialize(@x : Float32, @y : Float32)
        end
      end
      HERO
      )

      source = <<-CR
      require "citrine"

      context(:game) do
        require "citrine/draw3d"
        require "./scratch/entities/hero"
      end
      CR

      parser = Citrine::DslParser.new(filename: File.expand_path("../main.cr", __DIR__))
      program = parser.parse(source)

      program.vm_contexts.has_key?("game").should be_true
      program.vm_contexts["game"].requires.should contain("citrine/draw3d")
      program.vm_contexts["game"].structs.has_key?("Hero").should be_true
    end

    it "forbids context blocks inside main_loop at parse time" do
      source = <<-CR
      require "citrine"

      Citrine.main_loop do
        context(:game) do
          require "citrine/draw3d"
        end
      end
      CR

      parser = Citrine::DslParser.new
      expect_raises(Citrine::ParseError, /Context declarations cannot be placed inside main_loop/) do
        parser.parse(source)
      end
    end
  end

  describe "Compile-Time Static Safety Checks" do
    it "rejects calls to unmounted subsystems inside a context-scoped main_loop" do
      source = <<-CR
      require "citrine"

      @[Context(:menu)]
      require "citrine/draw2d"

      @[Context(:game)]
      require "citrine/draw3d"

      Citrine.main_loop(context: :menu) do
        Draw3D.cube(0, 0, 5, 1, 1, 1)
        exit
      end
      CR

      parser = Citrine::DslParser.new
      program = parser.parse(source)

      compiler = Citrine::BytecodeCompiler.new
      expect_raises(Citrine::CompileError, /Subsystem violation.*Draw3D.*requires 'citrine\/draw3d'.*not mounted in active main_loop context ':menu'/) do
        compiler.compile(program)
      end
    end

    it "rejects cross-context user type instantiation" do
      # Create a user entity file
      user_file_dir = File.expand_path("../scratch/entities", __DIR__)
      Dir.mkdir_p(user_file_dir)
      boss_path = File.join(user_file_dir, "boss.cr")
      File.write(boss_path, <<-BOSS
      struct Boss
        property hp : Int32
        def initialize(@hp : Int32)
        end
      end
      BOSS
      )

      source = <<-CR
      require "citrine"

      context(:game) do
        require "./scratch/entities/boss"
      end

      Citrine.main_loop(context: :menu) do
        boss = Boss.new(100)
        exit
      end
      CR

      parser = Citrine::DslParser.new(filename: File.expand_path("../main.cr", __DIR__))
      program = parser.parse(source)

      compiler = Citrine::BytecodeCompiler.new
      expect_raises(Citrine::CompileError, /Context violation: Type 'Boss' belongs to context\(:game\).*not mounted in active main_loop context ':menu'/) do
        compiler.compile(program)
      end
    end

    it "rejects dynamic context switching inside an active main_loop" do
      source = <<-CR
      require "citrine"

      Citrine.main_loop(context: :menu) do
        Citrine.switch_context(:game)
        exit
      end
      CR

      parser = Citrine::DslParser.new
      program = parser.parse(source)

      compiler = Citrine::BytecodeCompiler.new
      expect_raises(Citrine::CompileError, /Safety Error: Cannot switch context inside active main_loop/) do
        compiler.compile(program)
      end
    end
  end

  describe "Sequential Main Loops & Exit Break Emission" do
    it "compiles sequential main loops with context shifts and exit break jumps" do
      source = <<-CR
      require "citrine"

      @[Context(:menu)]
      require "citrine/draw2d"

      @[Context(:game)]
      require "citrine/draw3d"

      Citrine.main_loop do
        exit
      end

      Citrine.main_loop(context: :game) do
        exit
      end
      CR

      parser = Citrine::DslParser.new
      program = parser.parse(source)

      compiler = Citrine::BytecodeCompiler.new
      bytes = compiler.compile(program)
      bytes.size.should be > 16

      # Check that instructions in the main function include ContextSet native calls
      main_fn = compiler.functions.find { |f| f.name == "__main__" }
      main_fn.should_not be_nil
      fn = main_fn.not_nil!

      context_calls = fn.instructions.select do |inst|
        inst.opcode == Citrine::Opcode::CallNative && (inst.raw & 0xFF) == Citrine::NativeId::ContextSet.value
      end
      # There should be 2 ContextSet calls: one before loop 1, and one before loop 2
      context_calls.size.should eq(2)
    end
  end
end
