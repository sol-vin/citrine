require "../spec_helper"
require "../../src/citrine/core/dma"
require "../../src/citrine/dsl/dma"

describe "Citrine::DMA (Declarative DMA Packet Builder)" do
  it "generates canonical NTSC GS environment packet (224 bytes / 14 QWC)" do
    env = Citrine::DMA.env_packet(640, 448)
    env.size.should eq(224)
    # Must be 16-byte aligned (quadword aligned)
    (env.size % 16).should eq(0)
  end

  it "builds declarative GIF A+D drawing packet with EOP" do
    bytes = Citrine::DMA.draw(capacity_qwc: 16, eop: true) do |gs|
      gs.prim(:triangle)
      gs.rgba(255, 128, 64, 255)
      gs.xyz2(100, 100, 0)
      gs.xyz2(200, 100, 0)
      gs.xyz2(150, 200, 0)
    end

    bytes.size.should be > 0
    (bytes.size % 16).should eq(0)
  end

  it "builds source-chain DMA packet terminating with END tag" do
    buf = Citrine::DMA.chain(capacity_qwc: 64, auto_terminate: true) do |pkt|
      pkt.cnt do |chunk|
        chunk.gif_ad(eop: false) do |gs|
          gs.test(true, 1, 0xFF, 0, false, 0, true, 1)
        end
      end
    end

    buf.chain_terminated?.should be_true
    buf.byte_size.should be > 0
    (buf.byte_size % 16).should eq(0)
  end
end
