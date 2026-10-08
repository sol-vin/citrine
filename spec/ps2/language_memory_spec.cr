require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Low-Level Memory & Hardware Interop Primitives" do
  it "verifies Pointer(T).malloc, indexed reads/writes, and ptr.value on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_pointer_malloc_test")
    tc.source(<<-CR
      # Allocate a buffer of 4 elements on the heap
      ptr = Pointer(Int32).malloc(4)
      ptr[0] = 100
      ptr[1] = 200
      ptr[2] = 300
      ptr[3] = 400

      if ptr[0] == 100 && ptr[1] == 200 && ptr[2] == 300 && ptr[3] == 400
        debug_puts "[CITRINE TEST] Pointer.malloc & indexed access: PASS"
      end

      # Value property access
      ptr.value = 999
      if ptr.value == 999 && ptr[0] == 999
        debug_puts "[CITRINE TEST] Pointer.value accessor: PASS"
      end

      # Pointer address inspection
      addr = ptr.address
      if addr >= 0x00100000
        debug_puts "[CITRINE TEST] Pointer.address in valid heap range: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Pointer.malloc & indexed access: PASS")
    result.should_have_output("[CITRINE TEST] Pointer.value accessor: PASS")
    result.should_have_output("[CITRINE TEST] Pointer.address in valid heap range: PASS")
  end

  it "verifies direct SPRAM hardware address wrapping with Pointer(UInt32).new" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_spram_pointer_test")
    tc.source(<<-CR
      # Direct wrapping of PS2 EE SPRAM controller button address (0x70000010)
      spram_ptr = Pointer(UInt32).new(0x70000010_u32)
      addr = spram_ptr.address
      if addr == 0x70000010_u32
        debug_puts "[CITRINE TEST] Pointer(UInt32).new(0x70000010): PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Pointer(UInt32).new(0x70000010): PASS")
  end

  it "verifies Box(T).box and Box(T).unbox heap object reference wrapping" do
    tc = Citrine::Spec::Ps2TestCase.new("memory_box_unbox_test")
    tc.source(<<-CR
      class Config
        property volume : Int32
        def initialize(@volume)
        end
      end

      cfg = Config.new(85)
      # Box object reference into a raw pointer
      raw_ptr = Box(Config).box(cfg)
      if raw_ptr >= 0x00100000
        debug_puts "[CITRINE TEST] Box.box raw pointer: PASS"
      end

      # Unbox pointer back into object reference
      restored = Box(Config).unbox(raw_ptr)
      if restored.volume == 85
        debug_puts "[CITRINE TEST] Box.unbox restored object: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Box.box raw pointer: PASS")
    result.should_have_output("[CITRINE TEST] Box.unbox restored object: PASS")
  end
end
