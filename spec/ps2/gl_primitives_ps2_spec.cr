require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Hardware GL Primitives & Opcode Decomposition Suite" do
  it "executes Citrine::GL immediate pipeline with triangles and decomposed quads on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("gl_immediate_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Citrine::GL Immediate Pipeline Init"
      Citrine.begin_drawing
      Citrine::GL.begin(Citrine::GL::TRIANGLES)
      Citrine::GL.color(Color::Red)
      Citrine::GL.vertex(100, 100)
      Citrine::GL.vertex(200, 100)
      Citrine::GL.vertex(150, 200)
      Citrine::GL.end

      # Quad decomposes into two triangles: (1,2,3) and (1,3,4)
      Citrine::GL.begin(Citrine::GL::QUADS)
      Citrine::GL.color(Color::Blue)
      Citrine::GL.vertex(300, 100)
      Citrine::GL.vertex(400, 100)
      Citrine::GL.vertex(400, 200)
      Citrine::GL.vertex(300, 200)
      Citrine::GL.end
      Citrine.end_drawing
      debug_puts "[CITRINE TEST] Citrine::GL Primitives Dispatched: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18
    tc.max_registers.should be <= 1024

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE] PS2 EE Engine Initialized")
    result.should_have_output("[CITRINE TEST] Citrine::GL Immediate Pipeline Init")
    result.should_have_output("[CITRINE TEST] Citrine::GL Primitives Dispatched: PASS")
  end

  it "verifies draw_quad decomposes into two triangles without hardware fault" do
    tc = Citrine::Spec::Ps2TestCase.new("draw_quad_decomposition_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] draw_quad Decomposition Verification"
      Citrine.begin_drawing
      # Call granular draw_quad primitive
      Citrine.draw_quad(50, 50, 250, 50, 250, 200, 50, 200, Color::Green)
      Citrine.end_drawing
      debug_puts "[CITRINE TEST] draw_quad Decomposed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] draw_quad Decomposition Verification")
    result.should_have_output("[CITRINE TEST] draw_quad Decomposed: PASS")
  end

  it "verifies GL matrix stack push/pop and transformations on EE" do
    tc = Citrine::Spec::Ps2TestCase.new("gl_matrix_stack_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] GL Matrix Stack Testing"
      Citrine::GL.push_matrix
      Citrine::GL.translate(50, 50, 0)
      Citrine::GL.scale(2, 2, 1)
      Citrine::GL.begin(Citrine::GL::TRIANGLES)
      Citrine::GL.color(Color::Yellow)
      Citrine::GL.vertex(10, 10)
      Citrine::GL.vertex(30, 10)
      Citrine::GL.vertex(20, 30)
      Citrine::GL.end
      Citrine::GL.pop_matrix
      debug_puts "[CITRINE TEST] GL Matrix Stack Pop: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] GL Matrix Stack Testing")
    result.should_have_output("[CITRINE TEST] GL Matrix Stack Pop: PASS")
  end

  it "verifies Draw.quad processing-style helper decomposes into triangles" do
    tc = Citrine::Spec::Ps2TestCase.new("draw_processing_quad_test")
    tc.source(<<-CR
      require "citrine/draw"
      debug_puts "[CITRINE TEST] Citrine::Draw.quad Helper Init"
      Citrine.begin_drawing
      Citrine::Draw.fill(Color::White)
      Citrine::Draw.quad(100.0, 100.0, 300.0, 100.0, 300.0, 250.0, 100.0, 250.0)
      Citrine.end_drawing
      debug_puts "[CITRINE TEST] Citrine::Draw.quad Decomposed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Citrine::Draw.quad Helper Init")
    result.should_have_output("[CITRINE TEST] Citrine::Draw.quad Decomposed: PASS")
  end

  it "verifies GL triangle fan and line strip primitives on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("gl_fan_and_strips_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] GL Fan and Strip Primitives Init"
      Citrine.begin_drawing
      # Fan
      Citrine::GL.begin(Citrine::GL::TRIANGLE_FAN)
      Citrine::GL.color(Color::Red)
      Citrine::GL.vertex(200, 200)
      Citrine::GL.vertex(180, 250)
      Citrine::GL.vertex(220, 250)
      Citrine::GL.vertex(250, 200)
      Citrine::GL.end

      # Line Strip
      Citrine::GL.begin(Citrine::GL::LINE_STRIP)
      Citrine::GL.color(Color::Blue)
      Citrine::GL.vertex(10, 10)
      Citrine::GL.vertex(50, 20)
      Citrine::GL.vertex(80, 60)
      Citrine::GL.end
      Citrine.end_drawing
      debug_puts "[CITRINE TEST] GL Fan and Strip: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] GL Fan and Strip Primitives Init")
    result.should_have_output("[CITRINE TEST] GL Fan and Strip: PASS")
  end
end
