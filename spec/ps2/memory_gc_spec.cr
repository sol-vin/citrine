require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Console Memory Architecture: 4-Tier Hybrid Memory & GC" do
  it "verifies Tier 3 explicit pointer allocation and deallocation (Pointer.free and ptr.free) on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_pointer_free_test")
    tc.source(<<-CR
      # Allocate heavy mesh/texture buffer
      ptr = Pointer(Int32).malloc(256)
      ptr[0] = 1337
      ptr[255] = 9999

      if ptr[0] == 1337 && ptr[255] == 9999
        debug_puts "[CITRINE TEST] Heavy buffer allocated and written: PASS"
      end

      # Deterministic deallocation via ptr.free
      ptr.free
      debug_puts "[CITRINE TEST] ptr.free executed: PASS"

      # Also test Pointer.free(ptr2)
      ptr2 = Pointer(Int32).malloc(64)
      ptr2[0] = 777
      Pointer.free(ptr2)
      debug_puts "[CITRINE TEST] Pointer.free(ptr2) executed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Heavy buffer allocated and written: PASS")
    result.should_have_output("[CITRINE TEST] ptr.free executed: PASS")
    result.should_have_output("[CITRINE TEST] Pointer.free(ptr2) executed: PASS")
  end

  it "verifies Tier 4 idle mark-sweep collector via GC.collect on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_gc_collect_test")
    tc.source(<<-CR
      # Create temporary arrays and objects in a loop
      arr = [10, 20, 30]
      arr << 40

      # Trigger GC mark-sweep cycle
      reclaimed = GC.collect
      debug_puts "[CITRINE TEST] GC.collect executed: PASS"

      # Verify active live objects survived
      if arr.size == 4 && arr[0] == 10 && arr[3] == 40
        debug_puts "[CITRINE TEST] Active root preserved after GC sweep: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] GC.collect executed: PASS")
    result.should_have_output("[CITRINE TEST] Active root preserved after GC sweep: PASS")
  end

  it "verifies Tier 2 VM Context arena transitions on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_context_arenas_test")
    tc.source(<<-CR
      make_vm_context(:menu) do
        debug_puts "[ARENA] Menu context initialized"
      end

      make_vm_context(:gameplay) do
        debug_puts "[ARENA] Gameplay context initialized"
      end

      set_vm_context(:menu)
      debug_puts "[CITRINE TEST] Switched to menu arena: PASS"

      set_vm_context(:gameplay)
      debug_puts "[CITRINE TEST] Switched to gameplay arena: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Switched to menu arena: PASS")
    result.should_have_output("[CITRINE TEST] Switched to gameplay arena: PASS")
  end
end
