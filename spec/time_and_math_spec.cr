require "./spec_helper"
require "../src/stubs/citrine/time"
require "../src/stubs/citrine/math"
require "../src/stubs/citrine/fastmath"

describe "Citrine Time & Math Subsystems" do
  describe "Time & Timer" do
    it "measures TimeSpan conversions and arithmetic" do
      t1 = TimeSpan.from_seconds(1.5_f32)
      t2 = TimeSpan.from_milliseconds(500.0_f32)

      t1.total_milliseconds.should eq(1500.0_f32)
      t2.total_seconds.should eq(0.5_f32)

      sum = t1 + t2
      sum.total_seconds.should eq(2.0_f32)

      diff = t1 - t2
      diff.total_seconds.should eq(1.0_f32)

      (t2 < t1).should be_true
    end

    it "operates Timer with progress and expiration" do
      timer = Citrine::Timer.new(duration: 2.0_f32)
      timer.finished?.should be_false
      timer.progress.should eq(0.0_f32)

      expired = timer.tick(1.0_f32)
      expired.should be_false
      timer.progress.should eq(0.5_f32)

      expired = timer.tick(1.0_f32)
      expired.should be_true
      timer.finished?.should be_true
      timer.progress.should eq(1.0_f32)
    end
  end

  describe "Standard Math" do
    it "computes trigonometry and roots" do
      Citrine::Math.sin(0.0_f32).abs.should be < 0.001_f32
      Citrine::Math.cos(0.0_f32).should be_close(1.0_f32, 0.01_f32)
      Citrine::Math.sqrt(16.0_f32).should be_close(4.0_f32, 0.001_f32)
      Citrine::Math.hypot(3.0_f32, 4.0_f32).should be_close(5.0_f32, 0.001_f32)
      Citrine::Math.dist(0.0_f32, 0.0_f32, 3.0_f32, 4.0_f32).should be_close(5.0_f32, 0.001_f32)
    end

    it "clamps and lerps correctly" do
      Citrine::Math.clamp(15.0_f32, 0.0_f32, 10.0_f32).should eq(10.0_f32)
      Citrine::Math.clamp(-5.0_f32, 0.0_f32, 10.0_f32).should eq(0.0_f32)
      Citrine::Math.lerp(10.0_f32, 20.0_f32, 0.5_f32).should eq(15.0_f32)
    end
  end

  describe "FastMath (LUT & Bitwise)" do
    it "computes fast inverse square root (Carmack algorithm)" do
      # 1/sqrt(4) = 0.5
      fast_inv = Citrine::FastMath.fast_inv_sqrt(4.0_f32)
      fast_inv.should be_close(0.5_f32, 0.05_f32)

      # 1/sqrt(16) = 0.25
      fast_inv16 = Citrine::FastMath.fast_inv_sqrt(16.0_f32)
      fast_inv16.should be_close(0.25_f32, 0.03_f32)
    end

    it "checks power of two and fast integer sqrt" do
      Citrine::FastMath.is_power_of_two?(64).should be_true
      Citrine::FastMath.is_power_of_two?(63).should be_false
      Citrine::FastMath.next_power_of_two(17).should eq(32)
      Citrine::FastMath.isqrt(100).should eq(10)
    end
  end
end
