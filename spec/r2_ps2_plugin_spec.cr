require "./spec_helper"
require "../src/citrine/cradare2/ps2_dissector"
require "../src/citrine/cradare2/plugin"

describe "Citrine PS2 Radare2 Plugin & Dissector" do
  it "validates a compliant runner ELF with all 11 PS2 hardware checks" do
    elf_path = "runtime/bin/citrine_runner.elf"
    File.exists?(elf_path).should be_true

    dissector = Citrine::Cradare2::Ps2Dissector.from_file(elf_path)
    dissector.entry_point.should eq(0x00100000_u32)
    dissector.sections.has_key?(".text").should be_true
    dissector.sections.has_key?(".rodata").should be_true
    dissector.sections.has_key?(".data").should be_true
    dissector.sections.has_key?(".spram").should be_true
    dissector.sections.has_key?(".symtab").should be_true

    report = dissector.validate
    report.should contain("  [PASS] ELF Entry Point: 0x00100000 (Standard EE MIPS)")
    report.should contain("  [PASS] Depth Test (TEST_1): ALLPASS (0x00030000) verified")
    report.should contain("  [PASS] Environment GIFTag: NLOOP=13, FLG=PACKED, EOP=true")
    report.should contain("  [PASS] Draw GIFTag: NLOOP=8876, FLG=PACKED, EOP=true")
  end

  it "dissects Environment GIF packet and decodes GS registers" do
    elf_path = "runtime/bin/citrine_runner.elf"
    dissector = Citrine::Cradare2::Ps2Dissector.from_file(elf_path)
    rodata = dissector.sections[".rodata"]

    items = dissector.dissect_gif_packet(rodata.offset, 13)
    items.size.should eq(13)

    # Item 0: FRAME_1
    items[0].reg_name.should eq("FRAME_1")
    items[0].description.should contain("PSMCT32 (RGBA32)")
    items[0].description.should contain("640px")

    # Item 4: XYOFFSET_1
    items[4].reg_name.should eq("XYOFFSET_1")
    items[4].description.should contain("OFX=0.0px")
    items[4].description.should contain("OFY=0.0px")

    # Item 6: SCISSOR_1
    items[6].reg_name.should eq("SCISSOR_1")
    items[6].description.should contain("Bounds: (0, 0) -> (639, 447)")

    # Item 11: TEST_1
    items[11].reg_name.should eq("TEST_1")
    items[11].description.should contain("ALWAYS (All pixels pass)")
  end

  it "dissects Draw GIF packet and verifies pairwise XYZ3/XYZ2 drawing kicks" do
    elf_path = "runtime/bin/citrine_runner.elf"
    dissector = Citrine::Cradare2::Ps2Dissector.from_file(elf_path)
    rodata = dissector.sections[".rodata"]

    draw_offset = rodata.offset + 16 + (13 * 16)
    items = dissector.dissect_gif_packet(draw_offset, 20)
    items.size.should be >= 16

    # Item 0: PRIM (SPRITE)
    items[0].reg_name.should eq("PRIM")
    items[0].description.should contain("Type=SPRITE")

    # Item 1: RGBAQ
    items[1].reg_name.should eq("RGBAQ")

    # Item 2: XYZ3 (Vertex 1, NO KICK)
    items[2].reg_name.should eq("XYZ3")
    items[2].description.should contain("[NO KICK]")

    # Item 3: XYZ2 (Vertex 2, DRAW KICK)
    items[3].reg_name.should eq("XYZ2")
    items[3].description.should contain("[DRAW KICK]")
    items[3].description.should contain("X=640.0px")
    items[3].description.should contain("Y=448.0px")
  end

  it "generates complete radare2 PS2 plugin script with memory maps, formats, and macros" do
    script = Citrine::Cradare2::R2PluginGenerator.generate_r2_script("CITRINE.ELF")
    script.should contain("e asm.arch = mips")
    script.should contain("e asm.cpu = mips3")
    script.should contain("f spram.start       = 0x70000000")
    script.should contain("f spram.canary      = 0x70000000")
    script.should contain("f spram.frame_count = 0x70000004")
    script.should contain("f gs.pmode    = 0x12000000")
    script.should contain("f gs.dispfb1  = 0x12000070")
    script.should contain("f gs.display1 = 0x12000080")
    script.should contain("f dmac.chcr2  = 0x1000A000")
    script.should contain("pf.gs_pmode")
    script.should contain("pf.giftag")
    script.should contain("(ps2_info; iI; iS; iE)")
    script.should contain("(ps2_disasm; pd 8 @ 0x00100000; pd 20 @ 0x00100020)")
  end

  it "executes python r2ps2.py CLI validator cleanly" do
    output = IO::Memory.new
    status = Process.run("python", ["tools/r2-ps2/r2ps2.py", "check", "runtime/bin/citrine_runner.elf"], output: output)
    status.success?.should be_true
    output.to_s.should contain("[PASS] Depth Test (TEST_1): ALLPASS")
    output.to_s.should contain("[PASS] SPRAM Canary: 0xDEADBEEF")
  end
end
