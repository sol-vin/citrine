require "../spec_helper"

describe "Citrine Tier 1: Concurrency & CSP Channels Compiler Suite" do
  it "compiles fiber spawning via spawn block" do
    source = <<-CRYSTAL
      counter = 0
      Citrine.spawn do
        counter += 10
      end
    CRYSTAL

    parser = Citrine::DslParser.new("spawn.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("spawn.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    # Must have generated a fiber worker function and registered it
    compiler.functions.any? { |f| f.name.starts_with?("__fiber") }.should be_true
  end

  it "compiles cooperative fiber yield" do
    source = <<-CRYSTAL
      step = 0
      while step < 10
        step += 1
        Citrine.yield
      end
    CRYSTAL

    parser = Citrine::DslParser.new("yield.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("yield.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    main_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::FiberOp && i.subop == Citrine::FiberSubOp::Yield.value }.should be_true
  end

  it "compiles buffered channels, send, receive, and try_receive" do
    source = <<-CRYSTAL
      ch = Channel(Int32).new(16)
      ch.send(42)
      ch.send(99)
      val = ch.receive
      val2 = ch.try_receive
      count = ch.size
    CRYSTAL

    parser = Citrine::DslParser.new("chan.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("chan.cr")
    bytes = compiler.compile(prog)

    main_fn = compiler.functions.last
    native_calls = main_fn.instructions.select { |i| i.opcode == Citrine::Opcode::CallNative }
    native_ids = native_calls.map { |i| Citrine::NativeId.new((i.raw & 0xFF_u32).to_u16) }

    native_ids.should contain(Citrine::NativeId::ChannelNew)
    native_ids.should contain(Citrine::NativeId::ChannelSend)
    native_ids.should contain(Citrine::NativeId::ChannelReceive)
    native_ids.should contain(Citrine::NativeId::ChannelTryReceive)
  end
end
