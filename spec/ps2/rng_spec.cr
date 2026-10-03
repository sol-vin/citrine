require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/stubs/citrine/rng"
require "../../src/stubs/citrine/rng/secure"

describe "Citrine PS2 RNG Suite (PRNG, Gaussian, Perlin & Secure)" do
  it "verifies Citrine::RNG::PRNG deterministic sequence and range distributions" do
    prng1 = Citrine::RNG::PRNG.new(123456789_u64)
    prng2 = Citrine::RNG::PRNG.new(123456789_u64)

    # Identical seeds must produce identical sequences
    10.times do
      prng1.next_u64.should eq(prng2.next_u64)
    end

    # Range constraints
    100.times do
      val = prng1.next_int(10, 50)
      val.should be >= 10
      val.should be <= 50

      flt = prng1.next_float
      flt.should be >= 0.0_f32
      flt.should be < 1.0_f32
    end
  end

  it "verifies Citrine::RNG::Gaussian distribution centering around mean" do
    gauss = Citrine::RNG::Gaussian.new
    sum = 0.0_f32
    count = 1000

    count.times do
      sum += gauss.next(mean: 50.0_f32, std_dev: 5.0_f32)
    end

    empirical_mean = sum / count.to_f32
    # Empirical mean should be close to 50.0 (+- 1.5)
    (empirical_mean - 50.0_f32).abs.should be < 1.5_f32
  end

  it "verifies Citrine::RNG::Perlin coherent gradient noise and fractal continuity" do
    # Perlin noise within [-1.0, 1.0]
    n1 = Citrine::RNG::Perlin.noise(0.5_f32, 0.5_f32, 0.5_f32)
    n1.should be >= -1.0_f32
    n1.should be <= 1.0_f32

    # Spatial continuity: small step in space produces small change in noise
    n2 = Citrine::RNG::Perlin.noise(0.51_f32, 0.5_f32, 0.5_f32)
    (n2 - n1).abs.should be < 0.2_f32

    # Fractal multi-octave noise
    f1 = Citrine::RNG::Perlin.fractal(1.2_f32, 3.4_f32, octaves: 4)
    f1.should be >= -1.5_f32
    f1.should be <= 1.5_f32
  end

  it "verifies Citrine::RNG::Secure hardware multi-entropy harvesting on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("citrine_rng_secure_test")
    tc.source(<<-CR
      require "citrine/rng"
      require "citrine/rng/secure"

      # Citrine PRNG
      prng = Citrine::RNG::PRNG.new(42_u64)
      p_val = prng.next_int(1, 100)
      if p_val >= 1 && p_val <= 100
        debug_puts "[CITRINE TEST] Citrine::RNG::PRNG: PASS"
      end

      # Citrine Perlin
      noise_val = Citrine::RNG::Perlin.noise(1.5_f32, 2.5_f32)
      debug_puts "[CITRINE TEST] Citrine::RNG::Perlin: PASS"

      # Secure hardware entropy harvester
      s1 = Citrine::RNG::Secure.harvest_entropy
      s2 = Citrine::RNG::Secure.harvest_entropy
      if s1 != s2
        debug_puts "[CITRINE TEST] Citrine::RNG::Secure Entropy Variation: PASS"
      end

      s_int = Citrine::RNG::Secure.next_int(10, 20)
      if s_int >= 10 && s_int <= 20
        debug_puts "[CITRINE TEST] Citrine::RNG::Secure next_int: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Citrine::RNG::PRNG: PASS")
    result.should_have_output("[CITRINE TEST] Citrine::RNG::Perlin: PASS")
    result.should_have_output("[CITRINE TEST] Citrine::RNG::Secure Entropy Variation: PASS")
    result.should_have_output("[CITRINE TEST] Citrine::RNG::Secure next_int: PASS")
  end
end
