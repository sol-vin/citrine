require "../spec_helper"

describe "Citrine Tier 1: Collections, Strings & Streams Compiler Suite" do
  it "compiles dynamic arrays, push, pop, index access, and mutation" do
    source = <<-CRYSTAL
      arr = [10, 20, 30]
      arr << 40
      arr.push(50)
      v = arr.pop
      arr[0] = 99
      elem = arr[1]
      len = arr.size
      arr.clear
    CRYSTAL

    parser = Citrine::DslParser.new("arr.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("arr.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::ArrayNew)
    native_ids.should contain(Citrine::NativeId::ArrayPush)
    native_ids.should contain(Citrine::NativeId::ArrayPop)
    native_ids.should contain(Citrine::NativeId::ArraySet)
    native_ids.should contain(Citrine::NativeId::ArrayGet)
    native_ids.should contain(Citrine::NativeId::ArraySize)
    native_ids.should contain(Citrine::NativeId::ArrayClear)
  end

  it "compiles StaticArray fixed buffer allocations" do
    source = <<-CRYSTAL
      sarr = StaticArray(Int32, 8).new(0)
      sarr[0] = 123
      sarr[7] = 456
      first = sarr[0]
      len = sarr.size
    CRYSTAL

    parser = Citrine::DslParser.new("sarr.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("sarr.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::StaticArrayNew)
    native_ids.should contain(Citrine::NativeId::ArraySet)
    native_ids.should contain(Citrine::NativeId::ArrayGet)
    native_ids.should contain(Citrine::NativeId::ArraySize)
  end

  it "compiles string interpolation, methods, and concatenation" do
    source = <<-CRYSTAL
      name = "PlayStation"
      year = 2000
      msg = "System: \#{name} launched in \#{year}"
      upper = msg.upcase
      lower = msg.downcase
      clean = msg.strip
      has_ps = msg.includes?("PlayStation")
      starts = msg.starts_with?("System")
      ends = msg.ends_with?("2000")
      joined = upper + " - OK"
    CRYSTAL

    parser = Citrine::DslParser.new("str.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("str.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::StringUpcase)
    native_ids.should contain(Citrine::NativeId::StringDowncase)
    native_ids.should contain(Citrine::NativeId::StringStrip)
    native_ids.should contain(Citrine::NativeId::StringIncludes)
    native_ids.should contain(Citrine::NativeId::StringStartsWith)
    native_ids.should contain(Citrine::NativeId::StringEndsWith)
    native_ids.should contain(Citrine::NativeId::StringConcat)
  end

  it "compiles IO::Memory stream buffer operations" do
    source = <<-CRYSTAL
      io = IO::Memory.new
      io.print("Hello, ")
      io.puts("World!")
      pos = io.pos
      sz = io.size
      io.rewind
      str = io.to_s
      io.clear
    CRYSTAL

    parser = Citrine::DslParser.new("io.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("io.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::MemoryIONew)
    native_ids.should contain(Citrine::NativeId::MemoryIOWrite)
    native_ids.should contain(Citrine::NativeId::MemoryIOPuts)
    native_ids.should contain(Citrine::NativeId::MemoryIOPos)
    native_ids.should contain(Citrine::NativeId::ArraySize)
    native_ids.should contain(Citrine::NativeId::MemoryIORewind)
    native_ids.should contain(Citrine::NativeId::MemoryIOToS)
    native_ids.should contain(Citrine::NativeId::ArrayClear)
  end
end
