require "./spec_helper"

describe "Radare2 & PS2 ELF / ISO Symbol Inspection" do
  it "builds a compliant MIPS R5900 ELF with full symbols for Citrine VM" do
    elf_bytes = Citrine::ElfBuilder.build_default_runner_elf
    elf_bytes.size.should be > 512

    # Verify ELF header magic: \x7FELF
    elf_bytes[0..3].should eq(Bytes[0x7F, 0x45, 0x4C, 0x46])
    # 32-bit (1), Little-endian (1), EV_CURRENT (1)
    elf_bytes[4].should eq(1_u8)
    elf_bytes[5].should eq(1_u8)
    elf_bytes[6].should eq(1_u8)

    # Machine = MIPS (8), e_flags has R5900 flags
    machine = IO::ByteFormat::LittleEndian.decode(UInt16, elf_bytes[18..19])
    machine.should eq(8_u16)

    temp_elf = File.tempfile("citrine_test_elf", ".elf")
    File.write(temp_elf.path, elf_bytes)

    # Inspect using radare2 if r2 binary is available
    if Process.find_executable("r2")
      output = IO::Memory.new
      Process.run("r2", ["-q", "-c", "is", temp_elf.path], output: output)
      symbols_text = output.to_s

      symbols_text.should contain("Citrine_VM_Run")
      symbols_text.should contain("Citrine_BeginMode3D")
      symbols_text.should contain("Citrine_DrawCube")
      symbols_text.should contain("Citrine_DrawMesh")
      symbols_text.should contain("Citrine_InitWindow")
      symbols_text.should contain("Citrine_ButtonDown")
      symbols_text.should contain("citrine_vm_panic")
      symbols_text.should contain("g_spram_base")
      symbols_text.should contain("0x70000000") # SPRAM register window

      # Inspect sections
      sec_out = IO::Memory.new
      Process.run("r2", ["-q", "-c", "iS", temp_elf.path], output: sec_out)
      sec_text = sec_out.to_s
      sec_text.should contain(".text")
      sec_text.should contain(".rodata")
      sec_text.should contain(".data")
      sec_text.should contain(".spram")
      sec_text.should contain(".symtab")
    end

    temp_elf.delete
  end

  it "packages Citrine bytecode into a valid ISO9660 image and verifies disc layout with r2" do
    sample_cbc = Bytes[0x43, 0x42, 0x43, 0x31, 0x01, 0x00, 0x00, 0x00] # CBC1 header
    temp_iso = File.tempfile("citrine_test", ".iso")
    Citrine::IsoBuilder.build(temp_iso.path, sample_cbc)

    iso_bytes = File.read(temp_iso.path).to_slice
    # Size must be 2048-byte sector aligned
    (iso_bytes.size % 2048).should eq(0)
    (iso_bytes.size // 2048).should be >= 24

    # Sector 16 (0x8000): Primary Volume Descriptor
    pvd_offset = 16 * 2048
    iso_bytes[pvd_offset].should eq(1_u8) # PVD type 1
    String.new(iso_bytes[pvd_offset + 1, 5]).should eq("CD001")
    String.new(iso_bytes[pvd_offset + 8, 11]).should eq("PLAYSTATION")
    String.new(iso_bytes[pvd_offset + 40, 11]).should eq("CITRINE_PS2")

    # Sector 17 (0x8800): Volume Descriptor Set Terminator
    term_offset = 17 * 2048
    iso_bytes[term_offset].should eq(255_u8) # 0xFF
    String.new(iso_bytes[term_offset + 1, 5]).should eq("CD001")

    # Sector 20 (0xA000): Root Directory Sector contains SYSTEM.CNF, CITRINE.ELF, GAME.CBC
    root_offset = 20 * 2048
    root_slice = iso_bytes[root_offset, 2048]
    root_str = String.new(root_slice)
    root_str.should contain("SYSTEM.CNF;1")
    root_str.should contain("CITRINE.ELF;1")
    root_str.should contain("GAME.CBC;1")

    # Sector 21 (0xA800): SYSTEM.CNF content
    cnf_offset = 21 * 2048
    cnf_str = String.new(iso_bytes[cnf_offset, 128])
    cnf_str.should contain("BOOT2 = cdrom0:\\CITRINE.ELF;1")
    cnf_str.should contain("VMODE = NTSC")

    # Inspect the ISO image with radare2
    if Process.find_executable("r2")
      output = IO::Memory.new
      Process.run("r2", ["-q", "-c", "izz", temp_iso.path], output: output)
      iso_strings = output.to_s

      iso_strings.should contain("CD001")
      iso_strings.should contain("PLAYSTATION")
      iso_strings.should contain("CITRINE_PS2")
      iso_strings.should contain("SYSTEM.CNF;1")
      iso_strings.should contain("CITRINE.ELF;1")
      iso_strings.should contain("GAME.CBC;1")
      iso_strings.should contain("BOOT2 = cdrom0:\\CITRINE.ELF;1")
      # Verify symbols from embedded runner ELF are present and searchable
      iso_strings.should contain("Citrine_VM_Run")
      iso_strings.should contain("Citrine_BeginMode3D")
      iso_strings.should contain("Citrine_DrawCube")
      iso_strings.should contain("Citrine_DrawMesh")
      iso_strings.should contain("g_spram_base")
    end

    temp_iso.delete
  end
end
