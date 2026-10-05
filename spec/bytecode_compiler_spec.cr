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
    String.new(bytes[0, 4]).should eq("CBC2")
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

  it "compiles first-class inline assembly DSL (asm) with COP0 cycle counter and VU0 macro mode" do
    source = <<-CRYSTAL
    # Single instruction via Crystal asm(...) and Citrine.asm
    asm("sync.l")
    Citrine.asm "sync.p"

    # Expression assignment with COP0 cycle counter
    start_cycles = asm("mfc0 $v0, $9")

    # Multiline heredoc with VU0 macro instructions via Citrine.asm
    Citrine.asm <<-ASM
      vadd.xyzw vf1, vf2, vf3
      vsub.xyzw vf4, vf5, vf6
      sync.p
    ASM

    # Raw machine word
    Citrine.asm 0x0000000F_u32

    end_cycles = asm("mfc0 $v0, $9")
    elapsed = end_cycles - start_cycles
    CRYSTAL

    parser = Citrine::DslParser.new("asm_test.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("asm_test.cr")
    bytes = compiler.compile(program)

    bytes.size.should be > 30
    main_fn = compiler.functions.last
    main_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::InlineAsm }.should be_true
  end

  it "compiles VU0 batch operations and CD-DA optical audio streaming" do
    source = <<-CRYSTAL
    Citrine.play_cdda_track(2)
    status = Citrine.cdda_status
    Citrine.set_audio_volume(128)
    Citrine.stop_cdda
    CRYSTAL

    parser = Citrine::DslParser.new("audio_test.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("audio_test.cr")
    bytes = compiler.compile(program)

    bytes.size.should be > 30
    main_fn = compiler.functions.last
    main_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::CallNative }.should be_true
  end
end
