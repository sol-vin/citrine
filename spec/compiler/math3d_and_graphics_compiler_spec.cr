require "../spec_helper"

describe "Citrine Tier 1: Math3D, Vector2, Color & Graphics Compiler Suite" do
  it "compiles Vector2 construction, field reads, and field writes" do
    source = <<-CRYSTAL
      vec = Vector2.new(120, 240)
      vx = vec.x
      vy = vec.y
      vec.x = 320
      vec.y = 480
    CRYSTAL

    parser = Citrine::DslParser.new("vector2.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("vector2.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    main_fn = compiler.functions.last
    opcodes = main_fn.instructions.map(&.opcode)
    opcodes.should contain(Citrine::Opcode::Vec2Math)
    opcodes.should contain(Citrine::Opcode::Vec2Prop)
  end

  it "compiles Color creation from literal RGBA, hex integer, and dynamic values" do
    source = <<-CRYSTAL
      c1 = Color.new(255, 128, 64, 255)
      c2 = Color.new(0xFF8040FF)
      def make_color(r, g, b)
        Color.new(r, g, b, 255)
      end
    CRYSTAL

    parser = Citrine::DslParser.new("color.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("color.cr")
    bytes = compiler.compile(prog)

    # Lit Color.new loads color constant
    compiler.constants.any? { |c| c.type == Citrine::ConstType::Color }.should be_true
    # Dynamic Color.new emits bitwise shifts and OR operations
    fn = compiler.functions.find { |f| f.name == "make_color" }.not_nil!
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::Shift }.should be_true
    fn.instructions.any? { |i| i.opcode == Citrine::Opcode::Bitwise }.should be_true
  end

  it "compiles clamp, float conversions, and arithmetic utilities" do
    source = <<-CRYSTAL
      def test_clamp(val, min_val, max_val)
        val.clamp(min_val, max_val)
      end
      val = 150
      f = val.to_f32
      i = f.to_i32
    CRYSTAL

    parser = Citrine::DslParser.new("math_util.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("math_util.cr")
    bytes = compiler.compile(prog)

    clamp_fn = compiler.functions.find { |f| f.name == "test_clamp" }.not_nil!
    # clamp emits compare and conditional branch instructions (fused into BranchCmp by optimizer)
    clamp_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::BranchCmp || i.opcode == Citrine::Opcode::Compare }.should be_true
    # to_i32 emits float conversion subop
    main_fn = compiler.functions.last
    main_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::FloatAlu }.should be_true
  end

  it "compiles 2D drawing API calls into native GS stubs" do
    source = <<-CRYSTAL
      col = Color.new(255, 0, 0, 255)
      Citrine.draw_rectangle(10, 20, 100, 50, col)
      Citrine.draw_circle(50, 50, 25, col)
      Citrine.draw_line(0, 0, 100, 100, col)
      Citrine.draw_text("Citrine Engine", 10, 10, 20, col)
    CRYSTAL

    parser = Citrine::DslParser.new("draw2d.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("draw2d.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::DrawRectangle)
    native_ids.should contain(Citrine::NativeId::DrawCircle)
    native_ids.should contain(Citrine::NativeId::DrawLine)
    native_ids.should contain(Citrine::NativeId::DrawText)
  end

  it "compiles 3D mode and GL immediate mode vertex submissions" do
    source = <<-CRYSTAL
      GL.begin(4)
      GL.color4f(1.0, 0.0, 0.0, 1.0)
      GL.vertex3f(0.0, 1.0, 0.0)
      GL.vertex3f(-1.0, -1.0, 0.0)
      GL.vertex3f(1.0, -1.0, 0.0)
      GL.end
    CRYSTAL

    parser = Citrine::DslParser.new("gl_mode.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("gl_mode.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::GLBegin)
    native_ids.should contain(Citrine::NativeId::GLColor)
    native_ids.should contain(Citrine::NativeId::GLVertex)
    native_ids.should contain(Citrine::NativeId::GLEnd)
  end
end
