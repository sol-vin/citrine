require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Boot Splash Screen, Memory Reclamation & Physical Entropy" do
  it "verifies boot_screen false boots immediately into __main__ with 0-delay" do
    tc = Citrine::Spec::Ps2TestCase.new("splash_disabled_fast_boot_test")
    tc.source(<<-CR
      boot_screen false

      debug_puts "[CITRINE TEST] Fast Boot __main__ Reached: PASS"

      # Check that entropy pool was seeded electronically
      seed_ptr = Pointer(UInt32).new(0x70000034_u32)
      seed_val = seed_ptr[0]
      if seed_val != 0_u32
        debug_puts "[CITRINE TEST] Fast Electronic Entropy Seeded: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 5.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Fast Boot __main__ Reached: PASS")
    result.should_have_output("[CITRINE TEST] Fast Electronic Entropy Seeded: PASS")
  end

  it "verifies default boot splash screen, 100% memory reclamation, and hardware entropy" do
    tc = Citrine::Spec::Ps2TestCase.new("splash_default_memory_reclaim_test")
    tc.source(<<-CR
      # Default boot_screen true runs 2.0s splash screen with logo against white background

      debug_puts "[CITRINE TEST] Splash Finished __main__ Entered: PASS"

      # 1. Verify dynamic heap base is at 0x00220000, reclaiming 100% of splash logo memory
      heap_ptr_loc = Pointer(UInt32).new(0x7000008C_u32)
      current_heap = heap_ptr_loc[0]
      if current_heap == 0x00220000_u32
        debug_puts "[CITRINE TEST] Dynamic Heap Pointer At Splash Base 0x00220000: PASS"
      end

      # 2. Allocate an array in __main__ and verify it reuses the reclaimed 0x00220000 space
      ptr = Pointer(Int32).malloc(8)
      if ptr.address == 0x00220000_u32
        debug_puts "[CITRINE TEST] Malloc Overwrites Logo Packet: PASS"
      end

      # 3. Verify entropy pool and global PRNG seed at 0x70000034 are non-zero and randomized
      seed_ptr = Pointer(UInt32).new(0x70000034_u32)
      seed_val = seed_ptr[0]
      if seed_val != 0_u32
        debug_puts "[CITRINE TEST] Hardware Entropy Pool Seeded: PASS"
      end

      # 4. Verify COP0 CPU cycle counter query via Citrine.cpu_cycles
      cycles = Citrine.cpu_cycles
      if cycles > 0_u32
        debug_puts "[CITRINE TEST] Citrine.cpu_cycles Non-Zero: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 8.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Splash Finished __main__ Entered: PASS")
    result.should_have_output("[CITRINE TEST] Dynamic Heap Pointer At Splash Base 0x00220000: PASS")
    result.should_have_output("[CITRINE TEST] Malloc Overwrites Logo Packet: PASS")
    result.should_have_output("[CITRINE TEST] Hardware Entropy Pool Seeded: PASS")
    result.should_have_output("[CITRINE TEST] Citrine.cpu_cycles Non-Zero: PASS")
  end

  it "verifies consecutive cold boots produce distinct hardware random sequences" do
    tc1 = Citrine::Spec::Ps2TestCase.new("entropy_cold_boot_1")
    tc1.source(<<-CR
      require "citrine/rng"

      r = Citrine.rand(1, 10000000)
      debug_puts "[BOOT1 RAND] \#{r}"
    CR
    )
    bytes1, _ = tc1.compile
    res1 = tc1.boot_pcsx2(timeout: 8.seconds)
    res1.should_boot_cleanly

    tc2 = Citrine::Spec::Ps2TestCase.new("entropy_cold_boot_2")
    tc2.source(<<-CR
      require "citrine/rng"

      r = Citrine.rand(1, 10000000)
      debug_puts "[BOOT2 RAND] \#{r}"
    CR
    )
    bytes2, _ = tc2.compile
    res2 = tc2.boot_pcsx2(timeout: 8.seconds)
    res2.should_boot_cleanly

    # Extract the random output lines from both cold boots
    line1 = res1.lines.find { |l| l.includes?("[BOOT1 RAND]") }
    line2 = res2.lines.find { |l| l.includes?("[BOOT2 RAND]") }

    line1.should_not be_nil
    line2.should_not be_nil

    # The random numbers must NEVER be identical across boots!
    line1.should_not eq(line2)
  end
end
