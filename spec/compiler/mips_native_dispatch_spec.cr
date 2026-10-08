require "../spec_helper"
require "../../src/citrine/iso/mips_compiler"
require "../../src/citrine/iso/text_segment_builder"
require "../../src/citrine/iso/rodata_segment_builder"

describe "Citrine Tier 1: MIPS R5900 Native Dispatch & AOT Codegen Suite" do
  it "translates 2D graphics native calls into MIPS subroutine branches" do
    source = <<-CRYSTAL
      Citrine.draw_rectangle(10, 20, 100, 50, 0xFF0000FF)
      Citrine.draw_circle(50, 50, 25, 0x00FF00FF)
      Citrine.draw_line(0, 0, 100, 100, 0x0000FFFF)
    CRYSTAL

    parser = Citrine::DslParser.new("draw.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("draw.cr")
    cbc_bytes = compiler.compile(prog)

    profile = Citrine::ISO::PhaseExtractor.extract(cbc_bytes)
    rodata = Citrine::ISO::RodataSegmentBuilder.build(profile)
    text_bytes, emitter, mips_comp = Citrine::ISO::TextSegmentBuilder.build(profile, rodata, cbc_bytes)

    text_bytes.size.should be > 100
    mips_comp.should_not be_nil

    # Verify that the emitter recorded calls to our runtime subroutines
    emitter.labels.has_key?("Citrine_DrawRectangle").should be_true
    emitter.labels.has_key?("Citrine_DrawCircle").should be_true
    emitter.labels.has_key?("Citrine_DrawLine").should be_true
  end

  it "translates audio and CDDA calls into SPU2 machine instructions" do
    source = <<-CRYSTAL
      Citrine.play_sound(1)
      Citrine.set_volume(200)
      Citrine.play_cdda(2)
      Citrine.stop_cdda
    CRYSTAL

    parser = Citrine::DslParser.new("audio.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("audio.cr")
    cbc_bytes = compiler.compile(prog)

    profile = Citrine::ISO::PhaseExtractor.extract(cbc_bytes)
    rodata = Citrine::ISO::RodataSegmentBuilder.build(profile)
    text_bytes, emitter, mips_comp = Citrine::ISO::TextSegmentBuilder.build(profile, rodata, cbc_bytes)

    emitter.labels.has_key?("Citrine_PlaySound").should be_true
    emitter.labels.has_key?("Citrine_SetVolume").should be_true
    emitter.labels.has_key?("Citrine_StopSound").should be_true
  end

  it "translates collection and dynamic array operations into leaf subroutines" do
    source = <<-CRYSTAL
      arr = [10, 20, 30]
      arr << 40
      val = arr[1]
      arr[2] = 99
      sz = arr.size
      popped = arr.pop
    CRYSTAL

    parser = Citrine::DslParser.new("coll.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("coll.cr")
    cbc_bytes = compiler.compile(prog)

    profile = Citrine::ISO::PhaseExtractor.extract(cbc_bytes)
    rodata = Citrine::ISO::RodataSegmentBuilder.build(profile)
    text_bytes, emitter, mips_comp = Citrine::ISO::TextSegmentBuilder.build(profile, rodata, cbc_bytes)

    emitter.labels.has_key?("Citrine_ArrayNew").should be_true
    emitter.labels.has_key?("Citrine_ArrayPush").should be_true
    emitter.labels.has_key?("Citrine_ArrayGet").should be_true
    emitter.labels.has_key?("Citrine_ArraySet").should be_true
    emitter.labels.has_key?("Citrine_ArraySize").should be_true
    emitter.labels.has_key?("Citrine_ArrayPop").should be_true
  end

  it "translates input controller action mapping calls" do
    source = <<-CRYSTAL
      pressed = Action.is_pressed?(:jump)
      down = Action.is_down?(:fire)
      released = Action.is_released?(:pause)
    CRYSTAL

    parser = Citrine::DslParser.new("input.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("input.cr")
    cbc_bytes = compiler.compile(prog)

    profile = Citrine::ISO::PhaseExtractor.extract(cbc_bytes)
    rodata = Citrine::ISO::RodataSegmentBuilder.build(profile)
    text_bytes, emitter, mips_comp = Citrine::ISO::TextSegmentBuilder.build(profile, rodata, cbc_bytes)

    emitter.labels.has_key?("Citrine_ActionPressed").should be_true
    emitter.labels.has_key?("Citrine_ActionDown").should be_true
    emitter.labels.has_key?("Citrine_ActionReleased").should be_true
  end
end
