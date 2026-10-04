require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/hardware/cdvd"
require "../src/stubs/citrine/hardware/dmac"
require "../src/stubs/citrine/hardware/gs"
require "../src/stubs/citrine/events"

describe "Citrine Hardware Architecture & Engine Utilities" do
  describe "CDVD Optical Drive Sector Calculations" do
    it "converts LBA sectors to byte offsets accurately" do
      Citrine::Hardware::CDVD::SECTOR_SIZE_STANDARD.should eq(2048)
      Citrine::Hardware::CDVD.lba_to_bytes(0_u32).should eq(0_u64)
      Citrine::Hardware::CDVD.lba_to_bytes(1_u32).should eq(2048_u64)
      Citrine::Hardware::CDVD.lba_to_bytes(16_u32).should eq(32768_u64) # ISO-9660 PVD sector 16
    end

    it "computes standard sector allocation for arbitrary payloads" do
      Citrine::Hardware::CDVD.bytes_to_sectors(0_u64).should eq(0_u32)
      Citrine::Hardware::CDVD.bytes_to_sectors(512_u64).should eq(1_u32)
      Citrine::Hardware::CDVD.bytes_to_sectors(2048_u64).should eq(1_u32)
      Citrine::Hardware::CDVD.bytes_to_sectors(2049_u64).should eq(2_u32)
      Citrine::Hardware::CDVD.bytes_to_sectors(1048576_u64).should eq(512_u32) # 1 MB
    end
  end

  describe "DMAC Channel Routing" do
    it "maps channel IDs to correct diagnostic names" do
      Citrine::Hardware::DMAC.channel_name(Citrine::Hardware::DMAC::CHANNEL_GIF).should eq("GIF (Channel 2)")
      Citrine::Hardware::DMAC.channel_name(Citrine::Hardware::DMAC::CHANNEL_VIF0).should eq("VIF0 (Channel 0)")
      Citrine::Hardware::DMAC.channel_name(Citrine::Hardware::DMAC::CHANNEL_VIF1).should eq("VIF1 (Channel 1)")
      Citrine::Hardware::DMAC.channel_name(Citrine::Hardware::DMAC::CHANNEL_SIF0).should eq("SIF0 (Channel 5)")
      Citrine::Hardware::DMAC.channel_name(Citrine::Hardware::DMAC::CHANNEL_SPR_FROM).should eq("SPR_FROM (Channel 8)")
      Citrine::Hardware::DMAC.channel_name(Citrine::Hardware::DMAC::CHANNEL_SPR_TO).should eq("SPR_TO (Channel 9)")
      Citrine::Hardware::DMAC.channel_name(99).should eq("Unknown DMAC Channel")
    end
  end

  describe "Graphics Synthesizer (GS) VRAM Mapping" do
    it "computes GS VRAM addresses based on page tiling" do
      addr0 = Citrine::Hardware::GS.calc_vram_addr(0, 0)
      addr0.should eq(0_u32)

      # Next page horizontally (x >= 64)
      addr1 = Citrine::Hardware::GS.calc_vram_addr(64, 0)
      addr1.should eq(2048_u32)

      # Next page vertically (y >= 32)
      addr_y = Citrine::Hardware::GS.calc_vram_addr(0, 32)
      addr_y.should eq(20480_u32)
    end
  end

  describe "EventEmitter Pub-Sub Dispatcher" do
    it "dispatches events to multiple registered listeners with payloads" do
      emitter = Citrine::EventEmitter.new
      received_payloads = [] of String

      emitter.on("score_up") do |payload|
        received_payloads << "Listener 1: #{payload}"
      end

      emitter.on("score_up") do |payload|
        received_payloads << "Listener 2: #{payload}"
      end

      emitter.emit("score_up", "100pts")

      received_payloads.size.should eq(2)
      received_payloads[0].should eq("Listener 1: 100pts")
      received_payloads[1].should eq("Listener 2: 100pts")
    end

    it "supports selective and full listener clearing" do
      emitter = Citrine::EventEmitter.new
      called = false

      emitter.on("temp_event") { |_| called = true }
      emitter.clear("temp_event")
      emitter.emit("temp_event")

      called.should be_false
    end
  end
end
