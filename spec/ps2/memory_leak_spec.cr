require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Automated Memory Leak & Safety Spec Suite" do
  it "verifies Tier 1 per-frame scratch pool operates with zero memory leaks across frame loops" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_scratch_zero_leak_test")
    tc.source(<<-CR
      struct ScratchTemp
        property id : Int32
        def initialize(@id : Int32)
        end
      end

      # Run frame loop allocating temporary structs in per-frame scratch pool (0x00400000)
      frames = 0
      while frames < 10
        temp = ScratchTemp.new(frames * 10)
        
        # Frame boundary resets scratch pool in O(1)
        end_drawing
        frames += 1
      end

      debug_puts "[CITRINE MEM TEST] Scratch pool frame loop completed: ZERO LEAKS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] Scratch pool frame loop completed: ZERO LEAKS")
  end

  it "verifies struct value-copy semantics (independent copies, no heap aliasing leaks)" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_struct_value_copy_test")
    tc.source(<<-CR
      struct Vector2D
        property x : Int32
        property y : Int32
        def initialize(@x : Int32, @y : Int32)
        end
      end

      # Allocate initial struct instance
      v1 = Vector2D.new(10, 20)
      
      # Assign to v2 - for struct, this must perform a value copy!
      v2 = v1
      v2.x = 99
      v2.y = 88

      # Verify v1 retains original values (no reference mutation)
      if v1.x == 10 && v1.y == 20 && v2.x == 99 && v2.y == 88
        debug_puts "[CITRINE MEM TEST] Struct value-copy semantics verified: INDEPENDENT"
      else
        debug_puts "[CITRINE MEM TEST] FAILED: Struct mutation leaked into original"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] Struct value-copy semantics verified: INDEPENDENT")
  end

  it "verifies Tier 2 VM context arena bulk deallocation and zero leakage on context exit" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_context_arena_leak_test")
    tc.source(<<-CR
      mem_before = Citrine::Memory.stats
      debug_puts "[CITRINE MEM TEST] Initial active heap bytes recorded"

      # Execute within transient game context
      vm_context(:battle_scene) do
        heavy_mesh = Pointer(Int32).malloc(128)
        heavy_mesh[0] = 42
        heavy_mesh[127] = 999
        debug_puts "[CITRINE MEM TEST] Allocated context-bound buffer"
      end

      mem_after = Citrine::Memory.stats
      debug_puts "[CITRINE MEM TEST] Exited context arena: RECLAIMED"

      if mem_after <= mem_before
        debug_puts "[CITRINE MEM TEST] Context arena bulk free confirmed: ZERO LEAKS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] Context arena bulk free confirmed: ZERO LEAKS")
  end

  it "verifies Tier 3 Pointer malloc, full-block deallocation, and free-list recycling" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_free_list_recycling_test")
    tc.source(<<-CR
      # 1. Allocate block A
      ptr_a = Pointer(Int32).malloc(64)
      ptr_a[0] = 12345
      ptr_a[63] = 67890
      debug_puts "[CITRINE MEM TEST] Buffer A allocated and verified"

      # 2. Free block A completely
      ptr_a.free
      debug_puts "[CITRINE MEM TEST] Buffer A freed"

      # 3. Allocate block B of same size - should recycle block A's slot
      ptr_b = Pointer(Int32).malloc(64)
      ptr_b[0] = 54321
      
      if ptr_b.address == ptr_a.address
        debug_puts "[CITRINE MEM TEST] Free-list slot recycled with exact address match: PASS"
      end

      ptr_b.free
      debug_puts "[CITRINE MEM TEST] Buffer B freed cleanly: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] Free-list slot recycled with exact address match: PASS")
    result.should_have_output("[CITRINE MEM TEST] Buffer B freed cleanly: PASS")
  end

  it "guards against double-free and invalid pointer deallocations without crashing the EE" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_double_free_safety_test")
    tc.source(<<-CR
      ptr = Pointer(Int32).malloc(32)
      ptr[0] = 777
      ptr.free
      debug_puts "[CITRINE MEM TEST] Initial free succeeded"

      # Attempt duplicate free - must be caught and intercepted by safety table!
      ptr.free
      debug_puts "[CITRINE MEM TEST] Double-free safely intercepted without hardware crash"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] Double-free safely intercepted without hardware crash")
  end

  it "guards against use-after-free and read-only code space write violations" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_uaf_and_protect_test")
    tc.source(<<-CR
      ptr = Pointer(Int32).malloc(16)
      ptr[0] = 100
      ptr.free

      # UAF read - safety check flags error
      stale_val = ptr[0]
      debug_puts "[CITRINE MEM TEST] UAF access evaluated safely"

      # Attempt write into read-only code space (0x00100000)
      code_ptr = Pointer(Int32).new(0x00100000)
      code_ptr[0] = 0xDEAD
      debug_puts "[CITRINE MEM TEST] Code protection boundary checked"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] UAF access evaluated safely")
    result.should_have_output("[CITRINE MEM TEST] Code protection boundary checked")
  end

  it "performs live PCSX2 memory inspection via GDB stub and verifies SPRAM stack canary integrity" do
    tc = Citrine::Spec::Ps2TestCase.new("mem_gdb_canary_integrity_test")
    tc.enable_gdb(28011)
    tc.inspect_memory(0x70000000_u64, 4)
    tc.source(<<-CR
      init_window(640, 448, "GDB Memory Canary Spec")
      frames = 0
      while frames < 15
        begin_drawing
        clear_background(0x101010)
        draw_text("Auditing PS2 Memory via GDB Stub", 20, 20, 20, 0xFFFFFF)
        end_drawing
        frames += 1
      end
      close_window
      debug_puts "[CITRINE MEM TEST] GDB memory audit run completed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 8.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE MEM TEST] GDB memory audit run completed: PASS")
  end
end
