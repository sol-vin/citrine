require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/iso/phase_extractor"

describe "Citrine::ISO::PhaseExtractor" do
  it "extracts profile from 01_hello_world/game.cbc (CBC2)" do
    tc = Citrine::Spec::Ps2TestCase.new("01_hello_world_phase")
    tc.target("examples/01_hello_world/main.cr")
    cbc, _ = tc.compile
    profile = Citrine::ISO::PhaseExtractor.extract(cbc)
    profile.phases.size.should be > 0
    profile.phases[0].commands.size.should be >= 4
    profile.is_animated.should be_true
  end

  it "extracts animated profile from 05_hello_world/main.cbc (CBC2)" do
    tc = Citrine::Spec::Ps2TestCase.new("05_hello_world_phase")
    tc.target("examples/05_hello_world/main.cr")
    cbc, _ = tc.compile
    profile = Citrine::ISO::PhaseExtractor.extract(cbc)
    profile.phases.size.should be > 0
    profile.phases[0].commands.size.should be >= 5
    profile.is_animated.should be_true
    profile.has_button_checks.should be_true
  end

  it "extracts profile from 02_shapes_and_text/main.cr including DrawQuad" do
    tc = Citrine::Spec::Ps2TestCase.new("02_shapes_and_text_phase")
    tc.target("examples/02_shapes_and_text/main.cr")
    cbc, _ = tc.compile
    profile = Citrine::ISO::PhaseExtractor.extract(cbc)
    profile.phases.size.should be > 0
    quads = profile.phases[0].commands.select { |c| c.type == Citrine::GS::DrawCommand::Type::Quad }
    quads.size.should be >= 1
    quad = quads.first
    quad.x1.should eq(450)
    quad.y1.should eq(96)
    quad.x2.should eq(530)
    quad.y2.should eq(106)
  end
end
