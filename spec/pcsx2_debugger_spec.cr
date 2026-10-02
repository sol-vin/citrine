require "./spec_helper"
require "../src/citrine/debugger/pcsx2_bridge"
require "../src/citrine/debugger/crash_analyzer"

describe "Citrine PCSX2 Debugger Bridge & Crash Analyzer" do
  describe "Pcsx2Bridge Environment Discovery" do
    it "locates PCSX2 installation path" do
      bridge = Citrine::Debugger::Pcsx2Bridge.new
      pcsx2_bin = bridge.pcsx2_path
      pcsx2_bin.should_not be_nil
      File.exists?(pcsx2_bin.not_nil!).should be_true
    end

    it "locates PCSX2 user directory and INI configuration" do
      bridge = Citrine::Debugger::Pcsx2Bridge.new
      ini_path = bridge.inis_path
      ini_path.should_not be_nil
      File.exists?(ini_path.not_nil!).should be_true
    end

    it "configures EEConsole logging in PCSX2.ini" do
      bridge = Citrine::Debugger::Pcsx2Bridge.new
      configured = bridge.ensure_logging_configured
      configured.should be_true
    end
  end

  describe "CrashAnalyzer & Panic Detection" do
    it "detects hardware panic lines and generates structured report" do
      line = "[CITRINE PANIC] Maximum fiber limit (64) reached (at PC: 0048)"
      sm = Citrine::SourceMap.new
      sm.add(48, "src/game.cr", 32, 5, "__main__")

      report = Citrine::Debugger::CrashAnalyzer.analyze(line, sm)
      report.should_not be_nil
      rep = report.not_nil!
      rep.fault_type.should eq("Citrine-VM Hardware Panic")
      rep.message.should contain("Maximum fiber limit")
      rep.line.should eq(32)
      rep.file.should eq("src/game.cr")
    end

    it "detects Scratchpad RAM canary corruption" do
      line = "[CITRINE PANIC] SPRAM Stack Canary Corrupted: 0xBAADF00D (expected 0xDEADBEEF)"
      report = Citrine::Debugger::CrashAnalyzer.analyze(line, nil)
      report.should_not be_nil
      report.not_nil!.fault_type.should eq("Scratchpad RAM (SPRAM) Memory Corruption")
    end

    it "detects MIPS Emotion Engine CPU TLB/Bus traps" do
      line = "EE/IOP Trap Exception: Bus Error (Data) at EPC: 0x00104820"
      report = Citrine::Debugger::CrashAnalyzer.analyze(line, nil)
      report.should_not be_nil
      report.not_nil!.fault_type.should eq("Emotion Engine Hardware Exception")
    end
  end
end
