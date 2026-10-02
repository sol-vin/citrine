require "./spec_helper"

describe Citrine::BytecodeCompiler do
  it "compiles arithmetic and variable assignments" do
    source = <<-CRYSTAL
    x = 100
    y = 50
    sum = x + y
    CRYSTAL

    parser = Citrine::DslParser.new("math.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("math.cr")
    bytes = compiler.compile(program)

    bytes.size.should be > 16
    String.new(bytes[0, 4]).should eq("CBC1")
  end

  it "compiles Vector2 manipulation and Native API calls" do
    source = <<-CRYSTAL
    pos = Vector2.new(120.0, 340.0)
    pos.x = 200.0
    Citrine.begin_drawing
    Citrine.clear_background(Color::Black)
    Citrine.draw_rectangle(pos.x, pos.y, 40, 40, Color::Red)
    Citrine.end_drawing
    CRYSTAL

    parser = Citrine::DslParser.new("render.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("render.cr")
    bytes = compiler.compile(program)

    bytes.size.should be > 20
    compiler.functions.size.should be >= 1
    main_fn = compiler.functions.last
    main_fn.name.should eq("__main__")
    main_fn.instructions.size.should be > 5
  end

  it "compiles while and times loops" do
    source = <<-CRYSTAL
    count = 0
    5.times do |i|
      count = count + i
    end
    CRYSTAL

    parser = Citrine::DslParser.new("loops.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("loops.cr")
    bytes = compiler.compile(program)

    bytes.size.should be > 20
  end
end
