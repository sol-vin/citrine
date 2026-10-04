require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Inline Assembly, VU0 SIMD & Audio Test Suite" do
  it "compiles and executes inline MIPS R5900 assembly with COP0 cycle counter on PCSX2" do
    tc = Citrine::Spec::Ps2TestCase.new("inline_asm_cop0_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Inline MIPS R5900 Assembly & COP0 Test"

      # Single instruction assembly
      Citrine.asm "sync.l"

      # Read hardware cycle counter from COP0 register 9
      start_cycles = asm("mfc0 $v0, $9")

      # Multiline heredoc assembly with VU0 Macro Mode SIMD instructions
      Citrine.asm <<-ASM
        vadd.xyzw vf1, vf2, vf3
        vmul.xyzw vf4, vf5, vf6
        vmula.xyzw vf1, vf4
        vmadd.xyzw vf7, vf2, vf5
        sync.p
      ASM

      # Read ending cycles
      end_cycles = asm("mfc0 $v0, $9")
      elapsed = end_cycles - start_cycles

      if start_cycles > 0 && end_cycles >= start_cycles
        debug_puts "[CITRINE TEST] Inline Assembly & COP0 Cycle Counter: PASS"
      else
        debug_puts "[CITRINE TEST] Inline Assembly & COP0 Cycle Counter: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 20

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Inline Assembly & COP0 Cycle Counter: PASS")
  end

  it "verifies Citrine_InlineAsm_Block symbol is generated in the PS2 ELF text segment" do
    source = <<-CR
    Citrine.asm "sync.l"
    asm("mfc0 $v0, $9")
    Citrine.asm <<-ASM
      vadd.xyzw vf1, vf2, vf3
      sync.p
    ASM
    CR

    parser = Citrine::DslParser.new("asm_sym_test.cr")
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new("asm_sym_test.cr")
    cbc_bytes = compiler.compile(program)

    builder = Citrine::ElfBuilder.new
    elf_bytes = builder.generate(cbc_bytes)
    elf_bytes.size.should be > 1024

    # Verify ELF header
    elf_bytes[0..3].should eq(Bytes[0x7F, 0x45, 0x4C, 0x46])
    builder.inline_asm_words.size.should be >= 3

    # Write temp file and check symbols if r2 is available
    if Process.find_executable("r2")
      temp_elf = File.tempfile("citrine_asm_elf", ".elf")
      temp_elf.close
      File.write(temp_elf.path, elf_bytes)

      output = IO::Memory.new
      Process.run("r2", ["-q", "-c", "is", temp_elf.path], input: Process::Redirect::Close, output: output)
      symbols_text = output.to_s
      symbols_text.should contain("Citrine_InlineAsm_Block")

      temp_elf.delete
    end
  end

  it "executes optical CD-DA audio streaming and volume control commands on PCSX2" do
    tc = Citrine::Spec::Ps2TestCase.new("cdda_audio_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] CD-DA Optical Audio & SPU2 Test"
      Citrine.play_cdda_track(2)
      Citrine.set_audio_volume(192)
      status = Citrine.cdda_status
      Citrine.stop_cdda

      if status == 1
        debug_puts "[CITRINE TEST] CD-DA Optical Audio Pipeline: PASS"
      else
        debug_puts "[CITRINE TEST] CD-DA Optical Audio Pipeline: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 20

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] CD-DA Optical Audio Pipeline: PASS")
  end

  it "executes batched VU0 SIMD vector co-processing without exceptions" do
    tc = Citrine::Spec::Ps2TestCase.new("vu0_batch_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] VU0 SIMD Batch Operations Test"
      p1 = Vector3.new(1.0, 2.0, 3.0)
      p2 = Vector3.new(4.0, 5.0, 6.0)
      pts = [p1, p2]
      mat = [1.0_f32, 0.0_f32, 0.0_f32, 0.0_f32,
             0.0_f32, 1.0_f32, 0.0_f32, 0.0_f32,
             0.0_f32, 0.0_f32, 1.0_f32, 0.0_f32,
             0.0_f32, 0.0_f32, 0.0_f32, 1.0_f32]

      res = Citrine::Hardware::VU0.batch_transform_points(pts, mat)
      dots = Citrine::Hardware::VU0.batch_dot_product(pts, pts)

      if res.size == 2 && dots.size == 2
        debug_puts "[CITRINE TEST] VU0 SIMD Co-Processor Batch: PASS"
      else
        debug_puts "[CITRINE TEST] VU0 SIMD Co-Processor Batch: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 20

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] VU0 SIMD Co-Processor Batch: PASS")
  end
end
