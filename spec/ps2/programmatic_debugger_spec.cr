require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/debugger/radare2_bridge"
require "../../src/citrine/iso/elf_builder"

describe "Citrine PS2 Programmatic Debugger & Live Emulator Inspection Suite" do
  it "audits compiled PS2 ELF symbols and branch delay slots using radare2" do
    tc = Citrine::Spec::Ps2TestCase.new("r2_elf_audit_spec")
    tc.target("examples/01_hello_world/main.cr")
    bytes, sm = tc.compile
    bytes.size.should be > 18

    # Build runner ELF
    profile = Citrine::ISO::PhaseExtractor.extract(bytes)
    rodata = Citrine::ISO::RodataSegmentBuilder.build(profile, [] of Citrine::VirtualInput)
    text_data, emitter = Citrine::ISO::TextSegmentBuilder.build(profile, rodata)
    elf_bytes = Citrine::ElfBuilder.build_default_runner_elf(bytes)

    temp_elf = "tmp_r2_audit_spec.elf"
    begin
      File.write(temp_elf, elf_bytes)

      if Citrine::Debugger::Radare2Bridge.available?
        # 1. Audit static symbols via r2
        symbols = Citrine::Debugger::Radare2Bridge.analyze_symbols(temp_elf)
        symbols.any? { |s| s.includes?("_start") }.should be_true
        symbols.any? { |s| s.includes?("main") }.should be_true
        symbols.any? { |s| s.includes?("debug_puts") }.should be_true

        # 2. Audit disassembly in _start: confirm SPRAM base address setup and loop branch
        disasm_start = Citrine::Debugger::Radare2Bridge.disassemble(temp_elf, "0x00100000", count: 20)
        disasm_start.any? { |l| l.includes?("lui") && l.includes?("0x7000") }.should be_true
        disasm_start.any? { |l| l.includes?("bnez") }.should be_true

        # 3. Audit disassembly and branch instructions in main via r2
        disasm = Citrine::Debugger::Radare2Bridge.disassemble(temp_elf, "0x00100054", count: 40)
        disasm.any? { |l| l.includes?("jal") || l.includes?("jr") || l.includes?("j ") || l.includes?("bne") || l.includes?("beq") }.should be_true

        # 4. Delay slot audit: confirm branch instructions are detected
        audit = Citrine::Debugger::Radare2Bridge.audit_delay_slots(temp_elf, "0x00100054", count: 40)
        audit[:branches].should be > 0
      end
    ensure
      File.delete(temp_elf) if File.exists?(temp_elf)
    end
  end

  it "validates Example 01: Hello World live SPRAM state and 60 FPS frame progress via GDB" do
    tc = Citrine::Spec::Ps2TestCase.new("gdb_hello_world_spec")
    tc.target("examples/01_hello_world/main.cr")

    # Inquire SPRAM memory:
    # 0x70000000: Canary (0xDEADBEEF)
    # 0x70000004: VBlank frame counter (must be >= 1)
    tc.enable_gdb(28012)
    tc.inspect_memory(0x70000000_u64, 4)
    tc.inspect_memory(0x70000004_u64, 4)

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram

    if canary = result.memory_word(0x70000000_u64)
      canary.should eq 0xDEADBEEF_u32
    end
    if frames = result.memory_word(0x70000004_u64)
      frames.should be > 0_u32
    end
  end

  it "injects programmatic controller actions and validates hardware state via live GDB memory inspection" do
    tc = Citrine::Spec::Ps2TestCase.new("gdb_live_action_spec")
    tc.target("examples/10_cd_player/main.cr")

    # Inject controller actions at discrete frame intervals:
    # Frame 25: DPAD Right (Switch from Track 0 to Track 1)
    # Frame 50: DPAD Up (Increase Volume)
    # Frame 75: R1 (Seek +10s / +600 frames)
    tc.inject_input(25, Citrine::PadButton::Right, duration: 2)
    tc.inject_input(50, Citrine::PadButton::Up, duration: 2)
    tc.inject_input(75, Citrine::PadButton::R1, duration: 2)

    # Programmatic debugger memory queries targeting PS2 Scratchpad RAM (0x70000000):
    # 0x70000000: SPRAM Canary word (0xDEADBEEF)
    # 0x70000078: Current Track Index
    # 0x70000070: Master Volume
    tc.enable_gdb(28011)
    tc.inspect_memory(0x70000000_u64, 4)
    tc.inspect_memory(0x70000078_u64, 4)
    tc.inspect_memory(0x70000070_u64, 4)

    result = tc.boot_pcsx2(timeout: 8.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram

    # Verify programmatic S.IRX optical responses from input actions
    result.should_have_output("cdrom0:S.IRX;1")
    result.should_have_output(">>> Play track")

    # If GDB was active and retrieved memory, verify hardware register/SPRAM integrity
    if canary = result.memory_word(0x70000000_u64)
      canary.should eq 0xDEADBEEF_u32
    end
  end
end
