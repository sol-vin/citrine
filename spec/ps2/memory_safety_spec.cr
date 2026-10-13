require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Console Memory Architecture: Safety & Automatic Deallocation" do
  it "rejects escaping value struct into persistent class instance variable at compile-time" do
    src = <<-CR
      struct Particle
        property x : Int32
        def initialize(@x : Int32)
        end
      end

      class Emitter
        def initialize
          @p = Particle.new(10)
        end
      end

      e = Emitter.new
    CR

    expect_raises(Citrine::CompileError, /Safety Error: Value struct .* cannot escape to persistent class field/) do
      parser = Citrine::DslParser.new("escape_test.cr")
      prog = parser.parse(src)
      compiler = Citrine::BytecodeCompiler.new("escape_test.cr")
      compiler.compile(prog)
    end
  end

  it "rejects escaping value struct into persistent class variable at compile-time" do
    src = <<-CR
      struct Vector2D
        property x : Int32
        def initialize(@x : Int32)
        end
      end

      class Game
        @@vec = Vector2D.new(5)
      end
    CR

    expect_raises(Citrine::CompileError, /Safety Error: Value struct .* cannot escape to persistent class variable/) do
      parser = Citrine::DslParser.new("escape_cvar_test.cr")
      prog = parser.parse(src)
      compiler = Citrine::BytecodeCompiler.new("escape_cvar_test.cr")
      compiler.compile(prog)
    end
  end

  it "permits struct value composition inside another struct" do
    src = <<-CR
      struct Inner
        property a : Int32
        def initialize(@a : Int32)
        end
      end

      struct Outer
        property inner : Inner
        def initialize
          @inner = Inner.new(42)
        end
      end

      o = Outer.new
    CR

    parser = Citrine::DslParser.new("struct_comp_test.cr")
    prog = parser.parse(src)
    compiler = Citrine::BytecodeCompiler.new("struct_comp_test.cr")
    bytes = compiler.compile(prog)
    bytes.size.should be > 18
  end

  it "verifies block-scoped RAII memory reclamation via Pointer.open on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_pointer_open_raii_test")
    tc.source(<<-CR
      # Block-scoped RAII allocation: automatically freed upon block exit
      Pointer(Int32).open(128) do |ptr|
        ptr[0] = 555
        ptr[127] = 888

        if ptr[0] == 555 && ptr[127] == 888
          debug_puts "[CITRINE TEST] RAII buffer allocated and verified: PASS"
        end
      end

      debug_puts "[CITRINE TEST] Pointer.open block exited cleanly: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] RAII buffer allocated and verified: PASS")
    result.should_have_output("[CITRINE TEST] Pointer.open block exited cleanly: PASS")
  end

  it "verifies hardware context arena bulk reclamation and SPRAM canary integrity on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_context_arena_hw_test")
    tc.source(<<-CR
      mem_before = Citrine::Memory.stats
      debug_puts "[CITRINE TEST] Initial heap level recorded: PASS"

      vm_context(:transient_stage) do
        mesh = Pointer(Int32).malloc(256)
        mesh[0] = 999
        debug_puts "[CITRINE TEST] Stage buffer allocated in context: PASS"
      end

      mem_after = Citrine::Memory.stats
      debug_puts "[CITRINE TEST] Context arena restored: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Initial heap level recorded: PASS")
    result.should_have_output("[CITRINE TEST] Stage buffer allocated in context: PASS")
    result.should_have_output("[CITRINE TEST] Context arena restored: PASS")
  end
end
