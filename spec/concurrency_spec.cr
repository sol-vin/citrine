require "./spec_helper"
require "../src/citrine/compiler/bytecode_compiler"
require "../src/citrine/compiler/budget_checker"
require "../src/citrine/iso/elf_builder"
require "../src/citrine/iso/iso_builder"
require "../src/stubs/citrine"

describe "Citrine Concurrency Subsystem" do
  describe "BudgetChecker Concurrency Safety" do
    it "computes concurrency memory footprint accurately for default 64 fibers" do
      functions = {"main" => 16_u8}
      report = Citrine::BudgetChecker.check(
        functions: functions,
        bytecode_size: 2048,
        max_fibers: 64,
        max_channels: 32,
        channel_capacity: 32
      )

      report.passed?.should be_true
      report.max_fibers.should eq(64)
      report.max_channels.should eq(32)
      # 64 * 1088 + 32 * (32 + 512) = 69632 + 17408 = 87040 bytes (~85 KB)
      report.concurrency_memory_bytes.should be > 80_000
      report.concurrency_memory_bytes.should be < 100_000
    end

    it "flags an error if max_fibers exceeds 256 threshold" do
      functions = {"main" => 16_u8}
      report = Citrine::BudgetChecker.check(
        functions: functions,
        bytecode_size: 2048,
        max_fibers: 300,
        max_channels: 32
      )

      report.passed?.should be_false
      report.errors.any? { |e| e.includes?("exceeds safe PS2 limit (256)") }.should be_true
    end

    it "flags an error if max_channels exceeds 128 threshold" do
      functions = {"main" => 16_u8}
      report = Citrine::BudgetChecker.check(
        functions: functions,
        bytecode_size: 2048,
        max_fibers: 64,
        max_channels: 150
      )

      report.passed?.should be_false
      report.errors.any? { |e| e.includes?("exceeds safe PS2 limit (128)") }.should be_true
    end
  end

  describe "Bytecode Compilation: Fibers & Scheduler" do
    it "compiles Citrine.spawn block into separate compiled function and emits OP_SPAWN_FIBER" do
      code = <<-CR
        Citrine.spawn do
          x = 10
          Citrine.yield
        end
      CR

      program = Citrine::DslParser.new("spawn_test.cr").parse(code)
      compiler = Citrine::BytecodeCompiler.new("spawn_test.cr")
      cbc = compiler.compile(program)

      cbc.size.should be > 18
      cbc[0, 4].should eq(Bytes[67, 66, 67, 49]) # "CBC1"

      # Functions table must have at least 2 functions: __fiber_0 and __main__
      compiler.functions.size.should be >= 2
      fiber_fn = compiler.functions.find { |f| f.name.starts_with?("__fiber") }
      fiber_fn.should_not be_nil

      # Main function should contain SpawnFiber opcode
      main_fn = compiler.functions.last
      has_spawn = main_fn.instructions.any? { |i| i.opcode == Citrine::Opcode::SpawnFiber }
      has_spawn.should be_true
    end

    it "compiles Citrine.yield and Fiber.yield into OP_YIELD" do
      code = <<-CR
        Citrine.yield
        Fiber.yield
      CR

      program = Citrine::DslParser.new("yield_test.cr").parse(code)
      compiler = Citrine::BytecodeCompiler.new("yield_test.cr")
      compiler.compile(program)

      main_fn = compiler.functions.last
      yield_count = main_fn.instructions.count { |i| i.opcode == Citrine::Opcode::Yield }
      yield_count.should eq(2)
    end

    it "compiles Citrine.sleep into NativeId::Sleep call" do
      code = <<-CR
        Citrine.sleep(0.5)
      CR

      program = Citrine::DslParser.new("sleep_test.cr").parse(code)
      compiler = Citrine::BytecodeCompiler.new("sleep_test.cr")
      compiler.compile(program)

      main_fn = compiler.functions.last
      has_sleep = main_fn.instructions.any? do |i|
        i.opcode == Citrine::Opcode::CallNative && (i.raw & 0xFF) == Citrine::NativeId::Sleep.value
      end
      has_sleep.should be_true
    end
  end

  describe "Bytecode Compilation: CSP Channels" do
    it "compiles Channel.new and emits NativeId::ChannelNew" do
      code = <<-CR
        chan = Channel(Int32).new(16)
      CR

      program = Citrine::DslParser.new("chan_test.cr").parse(code)
      compiler = Citrine::BytecodeCompiler.new("chan_test.cr")
      compiler.compile(program)

      main_fn = compiler.functions.last
      has_chan_new = main_fn.instructions.any? do |i|
        i.opcode == Citrine::Opcode::CallNative && (i.raw & 0xFF) == Citrine::NativeId::ChannelNew.value
      end
      has_chan_new.should be_true
    end

    it "compiles chan.send(42) and chan.receive into channel native calls" do
      code = <<-CR
        chan = Channel(Int32).new(16)
        chan.send(42)
        val = chan.receive
        tval = chan.try_receive
        cnt = chan.size
      CR

      program = Citrine::DslParser.new("chan_ops.cr").parse(code)
      compiler = Citrine::BytecodeCompiler.new("chan_ops.cr")
      compiler.compile(program)

      main_fn = compiler.functions.last
      native_calls = main_fn.instructions
        .select { |i| i.opcode == Citrine::Opcode::CallNative }
        .map { |i| (i.raw & 0xFF).to_u16 }

      native_calls.should contain(Citrine::NativeId::ChannelNew.value)
      native_calls.should contain(Citrine::NativeId::ChannelSend.value)
      native_calls.should contain(Citrine::NativeId::ChannelReceive.value)
      native_calls.should contain(Citrine::NativeId::ChannelTryReceive.value)
      native_calls.should contain(Citrine::NativeId::ChannelCount.value)
    end
  end

  describe "Crystal Language Concurrency Helpers" do
    it "provides Channel(T) operations with bounded capacity" do
      ch = Citrine::Channel(Int32).new(capacity: 10)
      ch.capacity.should eq(10)
      ch.send(100).should be_true
    end

    it "provides Fiber inspection and yield abstractions" do
      Citrine::Fiber.yield
      Citrine::Fiber.current_id.should eq(0_u32)
      Citrine::Fiber.alive?(0_u32).should be_true
    end

    it "provides Citrine::Concurrency::WorkerPool" do
      processed_items = [] of Int32
      pool = Citrine::Concurrency::WorkerPool(Int32).new(worker_count: 2) do |item|
        processed_items << item
      end
      pool.post(999).should be_true
    end
  end
end
