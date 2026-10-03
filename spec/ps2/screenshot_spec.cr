require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Visual Debugging: Screenshot Capture" do
  it "boots 05_hello_world on PCSX2, captures live framebuffer screenshot to PNG, and exports artifact" do
    tc = Citrine::Spec::Ps2TestCase.new("screenshot_capture_hello_world")
    tc.target("examples/05_hello_world/main.cr")
    snap_target = "tmp_snap_hello_world.png"
    tc.capture_screenshot(frame: 30, output_path: snap_target)

    result = tc.boot_pcsx2(timeout: 8.0.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram

    # Verify screenshot was captured
    File.exists?(snap_target).should be_true
    File.size(snap_target).should be > 1000

    # Verify PNG header
    File.open(snap_target, "rb") do |f|
      magic = Bytes.new(8)
      f.read_fully(magic)
      magic[0].should eq(0x89_u8)
      magic[1].should eq('P'.ord.to_u8)
      magic[2].should eq('N'.ord.to_u8)
      magic[3].should eq('G'.ord.to_u8)
    end

    # Clean up local temp file
    File.delete(snap_target) rescue nil
  end
end
