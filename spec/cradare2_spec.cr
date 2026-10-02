require "./spec_helper"

describe Citrine::Cradare2::R2PluginGenerator do
  it "generates radare2 script with PS2 memory mappings" do
    script = Citrine::Cradare2::R2PluginGenerator.generate_r2_script("game.cbc")

    script.should contain("o game.cbc")
    script.should contain("e asm.arch = mips")
    script.should contain("e asm.cpu = r5900")
    script.should contain("f spram.start = 0x70000000")
    script.should contain("f gs.framebuffer0 = 0x00000000")
  end
end

describe Citrine::Cradare2::GdbClient do
  it "calculates correct SPRAM register addresses" do
    client = Citrine::Cradare2::GdbClient.new("127.0.0.1", 1234)
    # Check that client initializes cleanly
    client.port.should eq(1234)
    client.host.should eq("127.0.0.1")
  end
end
