require "./spec_helper"

describe Citrine::Disassembler do
  it "disassembles valid compiled bytecode" do
    source = <<-CRYSTAL
    x = 42
    Citrine.draw_rectangle(x, 100, 50, 50, Color::Red)
    CRYSTAL

    parser = Citrine::DslParser.new("disasm_test.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("disasm_test.cr")
    bytes = compiler.compile(program)

    io = IO::Memory.new
    disasm = Citrine::Disassembler.new(io)
    disasm.disassemble(bytes)

    output = io.to_s
    output.should contain("Citrine Bytecode (.cbc) Disassembly")
    output.should contain(".function __main__")
    output.should contain("DrawRectangle")
  end
end
