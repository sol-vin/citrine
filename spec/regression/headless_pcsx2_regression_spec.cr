require "../spec_helper"
require "../../src/citrine/core/regression"
require "../../src/citrine/dsl/regression"

describe "Citrine Headless PCSX2 Automated Regression Subsystem" do
  describe "Core Engine (Tier 1): LogStreamParser & Milestones" do
    it "identifies boot and hardware milestones from emulation logs" do
      parser = Citrine::Core::Regression::LogStreamParser.new
      parser.feed("CDVD: Opening media: C:\\games\\CITRINE.ISO...")
      parser.feed("ISO-9660: Volume ID = 'CITRINE'")
      parser.feed("ELF Loading: cdrom0:\\CITRINE.ELF;1, EntryPoint = 0x00100000")
      parser.feed("ELF cdrom0:\\CITRINE.ELF;1 with entry point at 0x00100000 is executing.")
      parser.feed("Set GS CRTC configuration. NTSC 640x448 @ 59.940 (59.82) Interlaced (FIELD)")
      parser.feed("PS2 EE Engine Initialized successfully")

      parser.milestones.size.should be >= 4
      parser.milestones.any? { |m| m.milestone == Citrine::Core::Regression::Milestone::IsoMounted }.should be_true
      parser.milestones.any? { |m| m.milestone == Citrine::Core::Regression::Milestone::ElfLoaded }.should be_true
      parser.milestones.any? { |m| m.milestone == Citrine::Core::Regression::Milestone::EntryPoint }.should be_true
      parser.milestones.any? { |m| m.milestone == Citrine::Core::Regression::Milestone::GsCrtcConfigured }.should be_true
      parser.milestones.any? { |m| m.milestone == Citrine::Core::Regression::Milestone::EngineInit }.should be_true
    end

    it "extracts test harness assertions and signals early exit on close" do
      parser = Citrine::Core::Regression::LogStreamParser.new
      parser.feed("[CITRINE TEST] INIT: math_battery")
      parser.feed("[CITRINE TEST] 10 + 20 == 30: PASS")
      parser.feed("[CITRINE TEST] 5 * 5 == 25: PASS")
      parser.early_exit?.should be_false

      parser.feed("[CITRINE TEST] CLOSE: PASSED")
      parser.early_exit?.should be_true
      parser.close_status.should eq(:passed)
      parser.passed_assertions.size.should eq(2)
      parser.passed_assertions[0].message.should eq("10 + 20 == 30")
      parser.passed_assertions[1].message.should eq("5 * 5 == 25")
      parser.failed_assertions.should be_empty
    end

    it "detects test failures, panics, and SPRAM corruption" do
      parser = Citrine::Core::Regression::LogStreamParser.new
      parser.feed("[CITRINE TEST] INIT: fail_battery")
      parser.feed("[CITRINE TEST] Assertion A: PASS")
      parser.feed("[CITRINE TEST] Assertion B: FAIL")
      parser.feed("SPRAM Stack Canary Corrupted: 0xDEADBEEF overwritten")
      parser.feed("[Citrine Leak] 64 bytes unreferenced at 0x00240000")
      parser.feed("[CITRINE MEMORY ERROR] Use-after-free at 0x00300000")
      parser.feed("[CITRINE TEST] CLOSE: FAILED")

      parser.early_exit?.should be_true
      parser.close_status.should eq(:failed)
      parser.failed_assertions.size.should eq(1)
      parser.failed_assertions[0].message.should eq("Assertion B")
      parser.spram_canary_valid.should be_false
      parser.memory_leaks.size.should eq(1)
      parser.memory_faults.size.should eq(1)
    end
  end

  describe "Core Engine (Tier 1): Process Manager & Arguments" do
    it "builds standardized CLI arguments conforming to pcsx2-cli codex" do
      manager = Citrine::Core::Regression::HeadlessProcessManager.new
      args = manager.build_args("C:\\games\\test.iso", batch: true, nogui: true, fastboot: true, gdb_port: 28011)

      args.includes?("-fastboot").should be_true
      args.includes?("-earlyconsolelog").should be_true
      args.includes?("-batch").should be_true
      args.includes?("-nogui").should be_true
      args.includes?("-gdb").should be_true
      args.includes?("28011").should be_true
      args.includes?("--").should be_true
      args.last.should end_with("test.iso")
    end

    it "generates unique, collision-free temporary ISO names" do
      p1 = Citrine::Core::Regression::HeadlessProcessManager.generate_temp_iso_path("spec1")
      p2 = Citrine::Core::Regression::HeadlessProcessManager.generate_temp_iso_path("spec1")

      p1.should_not eq(p2)
      p1.should contain("spec1")
      p1.should end_with(".iso")
    end
  end

  describe "Core Engine (Tier 1): SuiteReport & Sol-Vin QA Markdown Exporter" do
    it "generates compliant Sol-Vin QA markdown reports with summary tables" do
      res1 = Citrine::Core::Regression::TestResult.new(
        name: "test_alpha",
        status: Citrine::Core::Regression::ExecutionStatus::Passed,
        duration: 1.25.seconds,
        passed_assertions: [
          Citrine::Core::Regression::AssertionRecord.new(:pass, "Check 1", 0.5.seconds, ""),
        ]
      )
      res2 = Citrine::Core::Regression::TestResult.new(
        name: "test_beta",
        status: Citrine::Core::Regression::ExecutionStatus::Failed,
        duration: 2.10.seconds,
        failed_assertions: [
          Citrine::Core::Regression::AssertionRecord.new(:fail, "Check 2 Failed", 1.8.seconds, ""),
        ],
        raw_logs: ["Log line 1", "Log line 2", "Failure trace"]
      )

      report = Citrine::Core::Regression::SuiteReport.new("Regression Suite Test", [res1, res2], 3.35.seconds)
      report.total_tests.should eq(2)
      report.passed_tests.should eq(1)
      report.failed_tests.should eq(1)
      report.pass_rate.should eq(50.0)

      md = report.to_markdown
      md.should contain("# Sol-Vin Headless PCSX2 Automated Regression Report")
      md.should contain("Regression Suite Test")
      md.should contain("50.0%")
      md.should contain("| `test_alpha` | ✅ PASS |")
      md.should contain("| `test_beta` | ❌ FAIL |")
      md.should contain("Failure trace")

      term = report.to_terminal
      term.should contain("PCSX2 HEADLESS AUTOMATED REGRESSION SUITE RESULTS")
    end
  end

  describe "Declarative DSL (Tier 2): Builder & Expectation System" do
    it "wraps raw source code into canonical Citrine test harness" do
      t = Citrine::DSL::Regression::TestDefinition.new("harness_verification")
      t.source <<-CR
        val = 42
        Test.assert_equal(42, val, "Answer")
      CR

      harnessed = t.build_harnessed_source
      harnessed.should contain("module Test")
      harnessed.should contain("Test.init(\"harness_verification\")")
      harnessed.should contain("Test.assert_equal(42, val, \"Answer\")")
      harnessed.should contain("Test.close")
    end

    it "validates expectations against execution results" do
      t = Citrine::DSL::Regression::TestDefinition.new("expectation_test")
      t.expect_clean_boot
      t.expect_pass("Check A", "Check B")
      t.expect_milestone(Citrine::Core::Regression::Milestone::GsCrtcConfigured)
      t.expect_spram_preserved
      t.expect_no_memory_leaks

      good_result = Citrine::Core::Regression::TestResult.new(
        name: "expectation_test",
        status: Citrine::Core::Regression::ExecutionStatus::Passed,
        milestones: [
          Citrine::Core::Regression::MilestoneRecord.new(Citrine::Core::Regression::Milestone::GsCrtcConfigured, "CRTC", 0.5.seconds, ""),
        ],
        passed_assertions: [
          Citrine::Core::Regression::AssertionRecord.new(:pass, "Check A", 0.2.seconds, ""),
          Citrine::Core::Regression::AssertionRecord.new(:pass, "Check B", 0.4.seconds, ""),
        ]
      )

      passed, failures = t.verify(good_result)
      passed.should be_true
      failures.should be_empty

      bad_result = Citrine::Core::Regression::TestResult.new(
        name: "expectation_test",
        status: Citrine::Core::Regression::ExecutionStatus::Panicked,
        panic_message: "TLB Miss at 0x00000000"
      )

      passed2, failures2 = t.verify(bad_result)
      passed2.should be_false
      failures2.should_not be_empty
      failures2.any? { |f| f.includes?("TLB Miss") }.should be_true
    end

    it "constructs a suite with fluent block configuration" do
      suite = Citrine::Regression.define_suite("Fluent PS2 Battery") do |s|
        s.default_timeout(8.seconds)
        s.watchdog_interval(2.seconds)

        s.test("alu_addition") do |t|
          t.description("Addition test")
          t.source("Test.pass(\"Added\")")
          t.expect_pass("Added")
        end

        s.test("alu_multiplication") do |t|
          t.description("Multiplication test")
          t.source("Test.pass(\"Multiplied\")")
          t.expect_pass("Multiplied")
        end
      end

      suite.tests.size.should eq(2)
      suite.tests[0].name.should eq("alu_addition")
      suite.tests[1].name.should eq("alu_multiplication")
      suite.default_timeout.should eq(8.seconds)
      suite.watchdog_interval.should eq(2.seconds)
    end
  end

  describe "Live Headless PCSX2 Regression Verification", tags: "pcsx2" do
    it "executes a compiled test case headlessly with rapid early termination" do
      manager = Citrine::Core::Regression::HeadlessProcessManager.new
      unless manager.available?
        next
      end

      t = Citrine::DSL::Regression::TestDefinition.new("smoke_live_regression")
      t.source <<-CR
        res = 100 * 20
        Test.assert_equal(2000, res, "Live PCSX2 math")
      CR
      t.expect_clean_boot
      t.expect_pass("Live PCSX2 math")
      t.expect_spram_preserved
      t.timeout(10.seconds)

      temp_iso = Citrine::Core::Regression::HeadlessProcessManager.generate_temp_iso_path("smoke_live")
      begin
        t.compile_to_iso(temp_iso)
        File.exists?(temp_iso).should be_true

        res = manager.execute(temp_iso, timeout: 10.seconds, early_exit: true)
        res.passed?.should be_true
        res.passed_count.should be >= 1

        passed, failures = t.verify(res)
        passed.should be_true
        failures.should be_empty
      ensure
        File.delete(temp_iso) if File.exists?(temp_iso)
        cue = temp_iso.sub(/\.iso$/i, ".cue")
        File.delete(cue) if File.exists?(cue)
      end
    end
  end
end
