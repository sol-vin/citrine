require "./spec_helper"
require "../src/citrine/runner/runner"

describe "Citrine Release Mode Stripping" do
  it "preserves debug log calls and symbols in debug mode" do
    source = <<-CR
    Citrine.log("Debug trace initialization")
    x = 10
    Citrine.log("Second debug trace")
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new
    compiler.release_mode = false
    bytes = compiler.compile(program)

    # String pool should contain the log message
    compiler.strings.should contain("Debug trace initialization")
  end

  it "strips debug log calls and debug overlay calls in release mode" do
    source = <<-CR
    Citrine.log("Debug trace initialization")
    Citrine.debug_overlay = true
    x = 10
    Citrine.log("Second debug trace")
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new
    compiler.release_mode = true
    bytes = compiler.compile(program)

    # String pool should NOT contain debug log strings
    compiler.strings.should_not contain("Debug trace initialization")
    compiler.strings.should_not contain("Second debug trace")

    # Bytecode size should be strictly smaller than debug mode
    compiler_dbg = Citrine::BytecodeCompiler.new
    compiler_dbg.release_mode = false
    dbg_bytes = compiler_dbg.compile(Citrine::DslParser.new.parse(source))

    bytes.size.should be < dbg_bytes.size
  end

  it "omits .cbcsym creation in Runner when release is enabled" do
    temp_cr = "tmp_release_test.cr"
    temp_cbc = "tmp_release_test.cbc"
    temp_sym = "tmp_release_test.cbcsym"

    File.write(temp_cr, "x = 42\nCitrine.log(\"Telemetry\")\n")

    begin
      runner = Citrine::Runner.new

      # Debug compile: sym should exist
      runner.compile_game(temp_cr, temp_cbc, release: false)
      File.exists?(temp_sym).should be_true
      File.delete(temp_sym)

      # Release compile: sym should NOT be created
      runner.compile_game(temp_cr, temp_cbc, release: true)
      File.exists?(temp_sym).should be_false
    ensure
      File.delete(temp_cr) if File.exists?(temp_cr)
      File.delete(temp_cbc) if File.exists?(temp_cbc)
      File.delete(temp_sym) if File.exists?(temp_sym)
    end
  end
end
