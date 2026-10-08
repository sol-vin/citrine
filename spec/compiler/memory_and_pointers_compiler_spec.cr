require "../spec_helper"

describe "Citrine Tier 1: Memory, Pointers, Box & IO::Memory Compiler Suite" do
  it "compiles pointer allocation, dereferencing, assignment, and address inspection" do
    source = <<-CRYSTAL
      ptr = Pointer(Int32).malloc(16)
      ptr.value = 42
      curr = ptr.value
      addr = ptr.address
      ptr.free
    CRYSTAL

    parser = Citrine::DslParser.new("pointer_mem.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("pointer_mem.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::PointerMalloc)
    native_ids.should contain(Citrine::NativeId::PointerSet)
    native_ids.should contain(Citrine::NativeId::PointerGet)
    native_ids.should contain(Citrine::NativeId::PointerAddress)
    native_ids.should contain(Citrine::NativeId::PointerFree)
  end

  it "compiles pointer creation from raw hardware address" do
    source = <<-CRYSTAL
      spram_ptr = Pointer(UInt32).new(0x70000000)
      val = spram_ptr[0]
      spram_ptr[1] = 0xDEADBEEF
    CRYSTAL

    parser = Citrine::DslParser.new("spram_ptr.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("spram_ptr.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::PointerNew)
    native_ids.should contain(Citrine::NativeId::PointerGet)
    native_ids.should contain(Citrine::NativeId::PointerSet)
  end

  it "compiles value boxing and unboxing" do
    source = <<-CRYSTAL
      boxed = Box(Int32).box(999)
      unboxed = Box(Int32).unbox(boxed)
    CRYSTAL

    parser = Citrine::DslParser.new("box.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("box.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::BoxNew)
    native_ids.should contain(Citrine::NativeId::BoxUnbox)
  end

  it "compiles IO::Memory stream operations" do
    source = <<-CRYSTAL
      io = IO::Memory.new(128)
      io.write_byte(0x5A)
      io.print("Hello")
      io.puts(" Citrine")
      p = io.pos
      io.rewind
      str = io.to_s
      io.clear
    CRYSTAL

    parser = Citrine::DslParser.new("io_mem.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("io_mem.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::MemoryIONew)
    native_ids.should contain(Citrine::NativeId::MemoryIOWriteByte)
    native_ids.should contain(Citrine::NativeId::MemoryIOWrite)
    native_ids.should contain(Citrine::NativeId::MemoryIOPuts)
    native_ids.should contain(Citrine::NativeId::MemoryIOPos)
    native_ids.should contain(Citrine::NativeId::MemoryIORewind)
    native_ids.should contain(Citrine::NativeId::MemoryIOToS)
    native_ids.should contain(Citrine::NativeId::MemoryIOClear)
  end

  it "compiles arena contexts with automatic block-exit cleanup and manual clear" do
    source = <<-CRYSTAL
      vm_context(:transient_scratch) do
        ptr = Pointer(Int32).malloc(8)
        ptr.value = 123
      end

      set_vm_context(:render_pool)
      clear_vm_context(:render_pool)
    CRYSTAL

    parser = Citrine::DslParser.new("context.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("context.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::ContextSet)
    native_ids.should contain(Citrine::NativeId::ContextClear)
  end

  it "compiles memory statistics and garbage collection cycles" do
    source = <<-CRYSTAL
      stats = Citrine::Memory.stats
      bytes = Citrine::Memory.heap_bytes
      GC.collect
    CRYSTAL

    parser = Citrine::DslParser.new("gc_stats.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("gc_stats.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::MemoryStats)
    native_ids.should contain(Citrine::NativeId::GCCycle)
  end
end
