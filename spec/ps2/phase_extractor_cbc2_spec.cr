require "../spec_helper"
require "../../src/citrine/iso/phase_extractor"

describe "Citrine::ISO::PhaseExtractor" do
  it "extracts profile from 01_hello_pad/game.cbc (CBC2)" do
    cbc = File.read("examples/01_hello_pad/game.cbc").to_slice
    profile = Citrine::ISO::PhaseExtractor.extract(cbc)
    profile.phases.size.should be > 0
    profile.phases[0].commands.size.should be >= 10
    profile.has_button_checks.should be_true
  end

  it "extracts animated profile from 05_hello_world/main.cbc (CBC2)" do
    cbc = File.read("examples/05_hello_world/main.cbc").to_slice
    profile = Citrine::ISO::PhaseExtractor.extract(cbc)
    profile.phases.size.should be > 0
    profile.phases[0].commands.size.should be >= 5
    profile.is_dvd_screensaver.should be_true
    profile.has_button_checks.should be_true
  end
end
