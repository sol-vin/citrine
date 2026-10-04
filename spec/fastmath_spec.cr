require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/fastmath"

describe "Citrine FastMath Subsystem" do
  describe "Fast Inverse Square Root & Square Root" do
    it "computes fast inverse square root accurately within 1% error" do
      inv = Citrine::FastMath.fast_inv_sqrt(4.0_f32)
      inv.should be_close(0.5_f32, 0.01_f32)

      inv2 = Citrine::FastMath.fast_inv_sqrt(16.0_f32)
      inv2.should be_close(0.25_f32, 0.01_f32)

      inv3 = Citrine::FastMath.fast_inv_sqrt(100.0_f32)
      inv3.should be_close(0.1_f32, 0.01_f32)
    end

    it "handles zero and negative inputs safely" do
      Citrine::FastMath.fast_inv_sqrt(0.0_f32).should eq(0.0_f32)
      Citrine::FastMath.fast_inv_sqrt(-5.0_f32).should eq(0.0_f32)
      Citrine::FastMath.fast_sqrt(0.0_f32).should eq(0.0_f32)
      Citrine::FastMath.fast_sqrt(-10.0_f32).should eq(0.0_f32)
    end

    it "computes fast square root via fast_inv_sqrt reciprocal" do
      Citrine::FastMath.fast_sqrt(9.0_f32).should be_close(3.0_f32, 0.05_f32)
      Citrine::FastMath.fast_sqrt(25.0_f32).should be_close(5.0_f32, 0.05_f32)
      Citrine::FastMath.fast_sqrt(144.0_f32).should be_close(12.0_f32, 0.1_f32)
    end
  end

  describe "Bitwise Powers of Two & Logarithms" do
    it "identifies powers of two correctly" do
      Citrine::FastMath.is_power_of_two?(1).should be_true
      Citrine::FastMath.is_power_of_two?(2).should be_true
      Citrine::FastMath.is_power_of_two?(4).should be_true
      Citrine::FastMath.is_power_of_two?(1024).should be_true
      Citrine::FastMath.is_power_of_two?(65536).should be_true

      Citrine::FastMath.is_power_of_two?(0).should be_false
      Citrine::FastMath.is_power_of_two?(-4).should be_false
      Citrine::FastMath.is_power_of_two?(3).should be_false
      Citrine::FastMath.is_power_of_two?(100).should be_false
    end

    it "computes next power of two for arbitrary positive integers" do
      Citrine::FastMath.next_power_of_two(1).should eq(1)
      Citrine::FastMath.next_power_of_two(2).should eq(2)
      Citrine::FastMath.next_power_of_two(3).should eq(4)
      Citrine::FastMath.next_power_of_two(5).should eq(8)
      Citrine::FastMath.next_power_of_two(17).should eq(32)
      Citrine::FastMath.next_power_of_two(600).should eq(1024)
      Citrine::FastMath.next_power_of_two(-5).should eq(1)
    end

    it "computes fast log2 floor with bit shifts" do
      Citrine::FastMath.fast_log2(1).should eq(0)
      Citrine::FastMath.fast_log2(2).should eq(1)
      Citrine::FastMath.fast_log2(3).should eq(1)
      Citrine::FastMath.fast_log2(4).should eq(2)
      Citrine::FastMath.fast_log2(8).should eq(3)
      Citrine::FastMath.fast_log2(1024).should eq(10)
      Citrine::FastMath.fast_log2(0).should eq(0)
    end
  end

  describe "Integer Binary Restoring Square Root (isqrt)" do
    it "calculates exact integer roots without floating-point math" do
      Citrine::FastMath.isqrt(0).should eq(0)
      Citrine::FastMath.isqrt(1).should eq(1)
      Citrine::FastMath.isqrt(4).should eq(2)
      Citrine::FastMath.isqrt(9).should eq(3)
      Citrine::FastMath.isqrt(15).should eq(3)
      Citrine::FastMath.isqrt(16).should eq(4)
      Citrine::FastMath.isqrt(100).should eq(10)
      Citrine::FastMath.isqrt(144).should eq(12)
      Citrine::FastMath.isqrt(1_000_000).should eq(1000)
      Citrine::FastMath.isqrt(-10).should eq(0)
    end
  end
end
