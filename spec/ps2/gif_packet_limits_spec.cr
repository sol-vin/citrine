require "../spec_helper"
require "../../src/stubs/citrine"

describe "Citrine PS2 GIFTag & DMAC Hardware Packet Limits" do
  describe "128-bit GIFTag Specification" do
    it "encodes valid GIFTag with NLOOP within 15-bit boundary" do
      tag = Citrine::Hardware::GIF::GIFTag.new(
        nloop: 500_u32,
        eop: true,
        pre: true,
        prim: 4_u32, # Triangles
        flg: Citrine::Hardware::GIF::Format::PACKED,
        nreg: 2_u32
      )

      tag.nloop.should eq(500)
      tag.eop.should be_true
      tag.pre.should be_true
      tag.prim.should eq(4)
      tag.flg.should eq(Citrine::Hardware::GIF::Format::PACKED)

      lo = tag.encode_lo
      # Check NLOOP in bits [0..14]
      (lo & 0x7FFF_u64).should eq(500_u64)
      # Check EOP in bit 15
      ((lo >> 15) & 1_u64).should eq(1_u64)
      # Check PRE in bit 46
      ((lo >> 46) & 1_u64).should eq(1_u64)
      # Check PRIM in bits [47..57]
      ((lo >> 47) & 0x7FF_u64).should eq(4_u64)
      # Check NREG in bits [60..63]
      ((lo >> 60) & 0xF_u64).should eq(2_u64)
    end

    it "rejects NLOOP exceeding 15-bit hardware maximum (32,767)" do
      expect_raises(ArgumentError, /exceeds 15-bit hardware maximum/) do
        Citrine::Hardware::GIF::GIFTag.new(nloop: 32768_u32)
      end

      expect_raises(ArgumentError, /exceeds 15-bit hardware maximum/) do
        Citrine::Hardware::GIF::GIFTag.new(nloop: 65536_u32)
      end
    end
  end

  describe "DMAC Channel 2 (GIF) 16-bit QWC Bounds" do
    it "validates safe quadword count fits within 16-bit hardware register" do
      Citrine::Hardware::GIF.validate_qwc!(100).should be_true
      Citrine::Hardware::GIF.validate_qwc!(65500).should be_true
      Citrine::Hardware::GIF.validate_qwc!(65535).should be_true
    end

    it "raises error if quadword count exceeds hardware register limit (65,535)" do
      expect_raises(ArgumentError, /exceeds 16-bit hardware register limit/) do
        Citrine::Hardware::GIF.validate_qwc!(65536)
      end

      expect_raises(ArgumentError, /exceeds 16-bit hardware register limit/) do
        Citrine::Hardware::GIF.validate_qwc!(100_000)
      end
    end

    it "splits massive vertex batches into safe DMAC chunks of <= 65,500 QW" do
      # Submit 150,000 quadwords (e.g. huge particle or terrain mesh)
      chunks = Citrine::Hardware::GIF.split_dma_batches(150_000)

      chunks.size.should eq(3)
      chunks[0].should eq(65500)
      chunks[1].should eq(65500)
      chunks[2].should eq(19000)
      chunks.sum.should eq(150_000)

      chunks.all? { |c| c <= 65500 }.should be_true
    end

    it "handles zero and small quadword batches seamlessly" do
      Citrine::Hardware::GIF.split_dma_batches(0).should eq([0])
      Citrine::Hardware::GIF.split_dma_batches(128).should eq([128])
      Citrine::Hardware::GIF.split_dma_batches(65500).should eq([65500])
    end
  end
end
