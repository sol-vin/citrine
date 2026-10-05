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
      cbc[0, 4].should eq(Bytes[67, 66, 67, 50]) # "CBC2"

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
      pool.shutdown
    end
  end

  describe "CSP Channel Mechanics & Bounded Buffering" do
    it "enqueues, dequeues, and tracks size and capacity accurately" do
      ch = Citrine::Channel(String).new(capacity: 4)
      ch.empty?.should be_true
      ch.full?.should be_false
      ch.size.should eq(0)

      ch.send("Alpha").should be_true
      ch.send("Beta").should be_true
      ch.size.should eq(2)
      ch.empty?.should be_false

      ch.receive.should eq("Alpha")
      ch.receive.should eq("Beta")
      ch.size.should eq(0)
      ch.empty?.should be_true
    end

    it "supports non-blocking try_receive without blocking" do
      ch = Citrine::Channel(Int32).new(capacity: 2)
      ch.try_receive.should be_nil

      ch.send(42).should be_true
      ch.try_receive.should eq(42)
      ch.try_receive.should be_nil
    end

    it "handles channel closing cleanly" do
      ch = Citrine::Channel(Int32).new(capacity: 2)
      ch.send(10).should be_true
      ch.close
      ch.closed?.should be_true
      ch.send(20).should be_false
      ch.try_receive.should eq(10)
      ch.try_receive.should be_nil
    end
  end

  describe "Multi-Channel Select Arbitration" do
    it "receives from the ready channel among multiple options" do
      ch1 = Citrine::Channel(String).new(capacity: 2)
      ch2 = Citrine::Channel(String).new(capacity: 2)

      ch2.send("Hello from ch2")

      received_value = ""
      selected_channel = 0

      selected = Citrine.select do |s|
        s.receive(ch1) do |msg|
          received_value = msg
          selected_channel = 1
        end
        s.receive(ch2) do |msg|
          received_value = msg
          selected_channel = 2
        end
      end

      selected.should be_true
      selected_channel.should eq(2)
      received_value.should eq("Hello from ch2")
    end

    it "executes non-blocking else fallback when no channels are ready" do
      ch1 = Citrine::Channel(Int32).new(capacity: 2)
      ch2 = Citrine::Channel(Int32).new(capacity: 2)

      else_executed = false
      selected = Citrine.select do |s|
        s.receive(ch1) { |_| }
        s.receive(ch2) { |_| }
        s.else do
          else_executed = true
        end
      end

      selected.should be_true
      else_executed.should be_true
    end

    it "sends to a channel with available capacity" do
      ch = Citrine::Channel(Int32).new(capacity: 2)
      send_acknowledged = false

      selected = Citrine.select do |s|
        s.send(ch, 777) do
          send_acknowledged = true
        end
      end

      selected.should be_true
      send_acknowledged.should be_true
      ch.receive.should eq(777)
    end

    it "provides fair round-robin arbitration when multiple channels are simultaneously ready" do
      ch1 = Citrine::Channel(Int32).new(capacity: 10)
      ch2 = Citrine::Channel(Int32).new(capacity: 10)

      5.times do |i|
        ch1.send(100 + i)
        ch2.send(200 + i)
      end

      ch1_count = 0
      ch2_count = 0

      10.times do
        Citrine.select do |s|
          s.receive(ch1) { |_| ch1_count += 1 }
          s.receive(ch2) { |_| ch2_count += 1 }
        end
      end

      # Fair arbitration ensures neither channel starves
      ch1_count.should be > 0
      ch2_count.should be > 0
      (ch1_count + ch2_count).should eq(10)
    end
  end

  describe "WaitGroup Synchronization" do
    it "synchronizes multiple concurrent worker fibers" do
      wg = Citrine::WaitGroup.new
      results = [] of Int32
      mutex = Citrine::Mutex.new

      3.times do |i|
        wg.add(1)
        Citrine.spawn do
          Citrine.yield
          mutex.synchronize do
            results << (i * 10)
          end
          wg.done
        end
      end

      wg.wait
      results.size.should eq(3)
      results.sort.should eq([0, 10, 20])
    end

    it "detects and panics on negative counter underflow" do
      wg = Citrine::WaitGroup.new
      expect_raises(Exception, /WaitGroup underflow/) do
        wg.done
      end
    end

    it "detects canary memory corruption" do
      wg = Citrine::WaitGroup.new
      wg.corrupt_canary_for_testing!
      expect_raises(Exception, /WaitGroup memory corruption/) do
        wg.add(1)
      end
    end
  end

  describe "Mutex Primitive & Synchronization" do
    it "enforces mutual exclusion across concurrent fibers" do
      mutex = Citrine::Mutex.new
      counter = 0
      wg = Citrine::WaitGroup.new

      5.times do
        wg.add(1)
        Citrine.spawn do
          10.times do
            mutex.synchronize do
              c = counter
              Citrine.yield
              counter = c + 1
            end
          end
          wg.done
        end
      end

      wg.wait
      counter.should eq(50)
    end

    it "tracks owner fiber ID and supports try_lock" do
      mutex = Citrine::Mutex.new
      mutex.locked?.should be_false

      mutex.try_lock.should be_true
      mutex.locked?.should be_true
      mutex.owner_fiber_id.should_not be_nil

      mutex.try_lock.should be_false
      mutex.unlock
      mutex.locked?.should be_false
    end

    it "panics on unlocking an unlocked mutex and non-owner unlock" do
      mutex = Citrine::Mutex.new
      expect_raises(Exception, /attempted to unlock an unlocked Mutex/) do
        mutex.unlock
      end

      mutex.lock
      wg = Citrine::WaitGroup.new
      wg.add(1)
      Citrine.spawn do
        expect_raises(Exception, /Mutex invariant violation/) do
          mutex.unlock
        end
        wg.done
      end
      wg.wait
      mutex.unlock
    end

    it "detects re-entrant deadlock attempts" do
      mutex = Citrine::Mutex.new
      mutex.lock
      expect_raises(Exception, /Mutex deadlock/) do
        mutex.lock
      end
      mutex.unlock
    end
  end

  describe "Counting Semaphore" do
    it "limits concurrent resource permits" do
      sema = Citrine::Semaphore.new(permits: 2, max_permits: 2)
      sema.permits.should eq(2)

      sema.try_acquire(1).should be_true
      sema.permits.should eq(1)

      sema.try_acquire(1).should be_true
      sema.permits.should eq(0)

      sema.try_acquire(1).should be_false

      sema.release(1)
      sema.permits.should eq(1)
      sema.release(1)
      sema.permits.should eq(2)
    end

    it "panics if release exceeds maximum permits" do
      sema = Citrine::Semaphore.new(permits: 2, max_permits: 2)
      expect_raises(Exception, /Semaphore overflow/) do
        sema.release(1)
      end
    end

    it "panics on invalid initialization" do
      expect_raises(Exception, /negative permits/) do
        Citrine::Semaphore.new(permits: -1)
      end
    end
  end

  describe "Once Guaranteed Single Execution" do
    it "guarantees execution exactly once across concurrent fibers" do
      once = Citrine::Once.new
      call_count = 0
      wg = Citrine::WaitGroup.new

      10.times do
        wg.add(1)
        Citrine.spawn do
          once.do do
            call_count += 1
          end
          wg.done
        end
      end

      wg.wait
      call_count.should eq(1)
      once.done?.should be_true
    end
  end

  describe "Future & Promise Asynchronous Primitives" do
    it "resolves asynchronously and cooperatively awaits result" do
      promise = Citrine::Promise(Int32).new
      future = promise.future
      future.completed?.should be_false

      Citrine.spawn do
        Citrine.yield
        promise.resolve(1337)
      end

      val = future.await
      val.should eq(1337)
      future.completed?.should be_true
      future.failed?.should be_false
    end

    it "propagates errors on rejection" do
      promise = Citrine::Promise(Int32).new
      future = promise.future

      Citrine.spawn do
        Citrine.yield
        promise.reject("Calculated failure")
      end

      expect_raises(Exception, /Calculated failure/) do
        future.await
      end
      future.failed?.should be_true
    end

    it "executes asynchronous blocks via Citrine.async helper" do
      future = Citrine.async do
        Citrine.yield
        "async result completed"
      end

      future.await.should eq("async result completed")
      future.completed?.should be_true
    end
  end

  describe "High-Level Job Abstractions: WorkerPool & ComputePool" do
    it "dispatches tasks across worker fibers and drains with wait_idle" do
      processed = [] of Int32
      mutex = Citrine::Mutex.new

      pool = Citrine::WorkerPool(Int32).new(worker_count: 3) do |num|
        mutex.synchronize { processed << num }
      end

      pool.active_workers.should eq(3)

      10.times { |i| pool.post(i).should be_true }
      pool.wait_idle

      processed.size.should eq(10)
      pool.completed_tasks.should eq(10)
      pool.failed_tasks.should eq(0)
      pool.shutdown(drain: true)
    end

    it "supports post_sync to await individual task completion" do
      handled = false
      pool = Citrine::WorkerPool(String).new(worker_count: 2) do |text|
        handled = true
      end

      pool.post_sync("hello sync").should be_true
      handled.should be_true
      pool.shutdown
    end

    it "supports ComputePool for map-reduce calculations with return values" do
      compute = Citrine::ComputePool(Int32, Int32).new(worker_count: 4) do |n|
        n * n
      end

      fut1 = compute.post_async(5)
      fut2 = compute.post_async(10)

      fut1.await.should eq(25)
      fut2.await.should eq(100)

      sync_res = compute.post_sync(7)
      sync_res.should eq(49)

      compute.shutdown(drain: true)
    end
  end

  describe "Concurrent Pipeline" do
    it "processes data sequentially through chained stages" do
      pipe = Citrine::Pipeline(Int32, String).new(capacity: 8) do |x|
        "Number: #{x}"
      end

      stage2 = pipe.pipe(capacity: 8) do |str|
        str.size
      end

      stage2.push(42).should be_true
      len = stage2.receive_blocking
      len.should eq("Number: 42".size)
    end
  end

  describe "Structured Concurrency Scope" do
    it "joins all child fibers before exiting scope" do
      finished_count = 0
      mutex = Citrine::Mutex.new

      Citrine.with_scope do |scope|
        4.times do
          scope.spawn do
            Citrine.yield
            mutex.synchronize { finished_count += 1 }
          end
        end
      end

      # All fibers in scope are guaranteed completed upon exit
      finished_count.should eq(4)
    end
  end

  describe "Memory Safety & Concurrency Diagnostics" do
    it "validates stack canary guard bands and catches corruption" do
      canary = Citrine::Concurrency::Safety::StackCanary.new
      canary.valid?.should be_true
      canary.audit!(1_u32)

      bad_canary = Citrine::Concurrency::Safety::StackCanary.new(top_canary: 0xBAD00000_u64)
      bad_canary.valid?.should be_false
      expect_raises(Exception, /Stack Canary Corrupted/) do
        bad_canary.audit!(2_u32)
      end
    end

    it "records dependencies and detects unresolvable wait deadlocks" do
      detector = Citrine::Concurrency::Safety::DeadlockDetector.new

      detector.record_wait(1_u32, Citrine::Concurrency::Safety::DeadlockDetector::ResourceType::MutexLock, 100_u32)
      detector.record_wait(2_u32, Citrine::Concurrency::Safety::DeadlockDetector::ResourceType::ChannelReceive, 200_u32)

      detector.wait_count.should eq(2)
      detector.detect_deadlock(active_fiber_count: 2).should be_true

      report = detector.deadlock_report
      report.should contain("Deadlock Detected Across 2 Dependencies")
      report.should contain("Fiber #1")
      report.should contain("Fiber #2")

      detector.record_wake(1_u32)
      detector.wait_count.should eq(1)
      detector.detect_deadlock(active_fiber_count: 2).should be_false
    end

    it "tracks linear handle ownership across channel transfers" do
      tracker = Citrine::Concurrency::Safety::LinearOwnershipTracker.new
      handle_id = 999_u32

      tracker.register(handle_id, owner_fiber_id: 1_u32)
      tracker.owner_of(handle_id).should eq(1_u32)

      # Valid transfer from fiber 1 to fiber 2
      tracker.transfer!(handle_id, from_fiber_id: 1_u32, to_fiber_id: 2_u32)
      tracker.owner_of(handle_id).should eq(2_u32)

      # Invalid transfer attempt by fiber 1 (no longer owner)
      expect_raises(Exception, /Linear Ownership Violation/) do
        tracker.transfer!(handle_id, from_fiber_id: 1_u32, to_fiber_id: 3_u32)
      end
    end
  end

  describe "Hardware Co-Processor: VU0 TaskScheduler Simulation" do
    it "scans 4-lane priority vectors simultaneously and selects the highest priority lane" do
      val, lane = Citrine::Hardware::VU0::TaskScheduler.parallel_priority_scan(10, 45, 20, 5)
      val.should eq(45)
      lane.should eq(1)

      val2, lane2 = Citrine::Hardware::VU0::TaskScheduler.parallel_priority_scan(100, 20, 30, 99)
      val2.should eq(100)
      lane2.should eq(0)
    end

    it "decrements sleep timers across 4 fibers in SIMD vector fashion" do
      t0, t1, t2, t3 = Citrine::Hardware::VU0::TaskScheduler.parallel_timer_decrement(
        1.5_f32, 0.5_f32, 0.2_f32, 3.0_f32, delta: 0.5_f32
      )

      t0.should eq(1.0_f32)
      t1.should eq(0.0_f32)
      t2.should eq(0.0_f32)
      t3.should eq(2.5_f32)
    end

    it "identifies ready fibers in a 4-lane quad" do
      Citrine::Hardware::VU0::TaskScheduler.quad_any_ready?(1.0_f32, 2.0_f32, 3.0_f32, 4.0_f32).should be_false
      Citrine::Hardware::VU0::TaskScheduler.quad_any_ready?(1.0_f32, 0.0_f32, 3.0_f32, 4.0_f32).should be_true
    end
  end

  describe "Hardware Co-Processor: IOP SIF Job Offloading" do
    it "submits and asynchronously awaits offloaded I/O and media jobs" do
      dispatcher = Citrine::Hardware::IOP::JobDispatcher.new

      ticket_id = dispatcher.submit_job(Citrine::Hardware::IOP::JobType::DiscSectorRead, size_bytes: 4096_u32)
      ticket_id.should be > 0_u32

      dispatcher.job_completed?(ticket_id).should be_false

      # Cooperatively awaits job completion across the SIF bus
      dispatcher.await_job(ticket_id).should be_true
      dispatcher.job_completed?(ticket_id).should be_true
    end

    it "handles background audio decoding and decompression tickets" do
      t1 = Citrine::Hardware::IOP.submit_job(Citrine::Hardware::IOP::JobType::AudioStreamDecode, 16384_u32)
      t2 = Citrine::Hardware::IOP.submit_job(Citrine::Hardware::IOP::JobType::BackgroundDecompress, 65536_u32)

      Citrine::Hardware::IOP.await_job(t1).should be_true
      Citrine::Hardware::IOP.await_job(t2).should be_true

      Citrine::Hardware::IOP.job_completed?(t1).should be_true
      Citrine::Hardware::IOP.job_completed?(t2).should be_true
    end
  end

  describe "WorkerPool Throughput & Exception Isolation" do
    it "processes 100+ tasks in a burst across worker pool" do
      processed_count = 0
      mutex = Citrine::Mutex.new
      pool = Citrine::Concurrency::WorkerPool(Int32).new(worker_count: 4, capacity: 128) do |item|
        mutex.synchronize { processed_count += 1 }
      end

      # Submit 100 tasks
      100.times do |i|
        pool.post(i).should be_true
      end

      pool.wait_idle

      processed_count.should eq(100)
      pool.completed_tasks.should eq(100)
      pool.failed_tasks.should eq(0)
      pool.shutdown(drain: true)
    end

    it "isolates worker exceptions and allows subsequent tasks to proceed" do
      executed = [] of Int32
      mutex = Citrine::Mutex.new
      pool = Citrine::Concurrency::WorkerPool(Int32).new(worker_count: 2, capacity: 16) do |item|
        if item == 13
          raise "Unlucky task 13 failed!"
        end
        mutex.synchronize { executed << item }
      end

      pool.post(10).should be_true
      pool.post(13).should be_true # Faulty task
      pool.post(20).should be_true

      pool.wait_idle

      executed.should eq([10, 20])
      pool.completed_tasks.should eq(2)
      pool.failed_tasks.should eq(1)
      pool.shutdown(drain: true)
    end
  end

  describe "Multi-Stage Pipeline Chaining" do
    it "transforms data across three chained stages with type safety" do
      # Stage 1: Int32 -> String
      # Stage 2: String -> Int32 (length)
      # Stage 3: Int32 -> String ("Length: X")
      stage1 = Citrine::Pipeline(Int32, String).new(capacity: 8) do |n|
        "Number_#{n}"
      end
      stage2 = stage1.pipe(capacity: 8) do |s|
        s.size
      end
      stage3 = stage2.pipe(capacity: 8) do |len|
        "Length: #{len}"
      end

      stage1.push(42).should be_true
      result = stage3.receive_blocking
      result.should eq("Length: 9")
    end
  end

  describe "Concurrency Safety: Stack Canary & Deadlock Detection" do
    it "audits stack canaries and detects top/bottom corruption" do
      canary = Citrine::Concurrency::Safety::StackCanary.new
      canary.valid?.should be_true

      # Corrupt bottom canary (stack underflow)
      canary.bottom_canary = 0xBAD00000_u64
      canary.valid?.should be_false

      # Corrupt top canary (stack overflow)
      canary.bottom_canary = Citrine::Concurrency::Safety::CANARY_BOTTOM
      canary.top_canary = 0xDEAD0000_u64
      canary.valid?.should be_false
    end

    it "tracks resource dependencies and generates deadlock diagnostic reports" do
      detector = Citrine::Concurrency::Safety::DeadlockDetector.new

      # Fiber 1 waits on ChannelReceive from Resource 101
      detector.record_wait(1_u32, Citrine::Concurrency::Safety::DeadlockDetector::ResourceType::ChannelReceive, 101_u32)
      detector.detect_deadlock(active_fiber_count: 2).should be_false

      # Fiber 2 waits on MutexLock from Resource 202
      detector.record_wait(2_u32, Citrine::Concurrency::Safety::DeadlockDetector::ResourceType::MutexLock, 202_u32)
      detector.detect_deadlock(active_fiber_count: 2).should be_true

      report = detector.deadlock_report
      report.includes?("Deadlock Detected Across 2 Dependencies").should be_true
      report.includes?("Fiber #1 waiting on ChannelReceive (Resource ID: 101)").should be_true
      report.includes?("Fiber #2 waiting on MutexLock (Resource ID: 202)").should be_true

      # Waking Fiber 1 resolves deadlock
      detector.record_wake(1_u32)
      detector.detect_deadlock(active_fiber_count: 2).should be_false
    end

    it "enforces linear ownership tracking and prevents double releases" do
      tracker = Citrine::Concurrency::Safety::LinearOwnershipTracker.new

      # Fiber 10 acquires Buffer Handle 500
      tracker.register(500_u32, owner_fiber_id: 10_u32)
      tracker.owner_of(500_u32).should eq(10_u32)

      # Fiber 10 transfers ownership to Fiber 20 via channel
      tracker.transfer!(500_u32, from_fiber_id: 10_u32, to_fiber_id: 20_u32)
      tracker.owner_of(500_u32).should eq(20_u32)

      # Fiber 20 successfully releases the handle
      tracker.release(500_u32, fiber_id: 20_u32)
      tracker.owner_of(500_u32).should be_nil
    end
  end
end
