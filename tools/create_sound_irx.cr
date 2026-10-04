# tools/create_sound_irx.cr
# Embeds full 45-second theme.vag ADPCM music stream into S.IRX at virtual address 0x1900.
# Uses full 32-bit transfer size (566,976 bytes = 35,436 blocks of 16 bytes = 45.0 seconds).
# Fully 64-byte aligned for PS2 SPU2 DMA hardware compliance.
# Configures SPU2 ADPCM loop flags: Block 0 = 0x06 (Start), Blocks 1..35434 = 0x02 (Repeat), Block 35435 = 0x03 (End+Repeat).

orig_elf = File.read("scratch/TESTSPU.irx").to_slice
vag_bytes = File.read("examples/10_video_and_audio/theme.vag").to_slice

puts "Original ELF size: #{orig_elf.size}"
puts "VAG file size: #{vag_bytes.size}"

vag_adpcm = vag_bytes[48..-1]
# Ensure chunk_size is a multiple of 64 bytes (4 blocks of 16 bytes)
max_blocks = vag_adpcm.size // 16
# Round down to multiple of 4 blocks (64 bytes)
target_blocks = (max_blocks // 4) * 4
chunk_size = (target_blocks * 16).to_u32
duration_sec = (target_blocks * 28) / 22050.0

puts "Selected ADPCM chunk size: #{chunk_size} bytes (#{target_blocks} blocks, #{duration_sec.round(2)} seconds of music!)"

# Create audio payload: 64-byte header + chunk_size bytes ADPCM
audio_mem = IO::Memory.new(64 + chunk_size)
audio_mem.write(vag_bytes[0..47])
16.times { audio_mem.write_byte(0_u8) } # 16 bytes padding -> 64 bytes total header
audio_mem.write(vag_adpcm[0 ... chunk_size])

audio_data = audio_mem.to_slice.dup

# SPU2 Hardware ADPCM Loop Flags:
# Block 0 (offset 0x40): flag = 0x06 (Loop Start + Loop Repeat: Bit 2 | Bit 1)
audio_data[0x40 + 1] = 0x06_u8

# Ensure all intermediate blocks have Bit 1 (0x02) set:
(1 ... target_blocks - 1).each do |b|
  audio_data[0x40 + b * 16 + 1] = 0x02_u8
end

# Last block: flag = 0x03 (Loop End + Loop Repeat: Bit 0 | Bit 1)
last_blk_off = 0x40 + chunk_size.to_i - 16
audio_data[last_blk_off + 1] = 0x03_u8

puts "Configured hardware loop: Block 0 (0x06) -> Blocks 1..#{target_blocks - 2} (0x02) -> Block #{target_blocks - 1} (0x03)"

orig_data_end = 0x1870_u32
target_audio_offset = 0x1990_u32
pad_size = target_audio_offset - orig_data_end # 288 bytes (0x120)
shift = pad_size + audio_data.size.to_u32
puts "Padding size: #{pad_size} bytes"
puts "Total file shift: #{shift} bytes (0x#{shift.to_s(16)})"

new_elf_mem = IO::Memory.new(orig_elf.size + shift)
# 1. Write everything up to 0x1870
new_elf_mem.write(orig_elf[0 ... orig_data_end])
# 2. Write padding zeroes up to 0x1990
pad_size.times { new_elf_mem.write_byte(0_u8) }
# 3. Write audio data
new_elf_mem.write(audio_data)
# 4. Write remaining sections (.mdebug, .shstrtab, .rel.text, .rel.rodata, .symtab, .strtab)
new_elf_mem.write(orig_elf[orig_data_end .. -1])

out_bytes = new_elf_mem.to_slice.dup
puts "New ELF size: #{out_bytes.size} bytes"

# 1. Update Program Header 1 (PT_LOAD) at offset 0x54:
ph1_off = 0x54_u32
new_p_filesz = 0x1900_u32 + audio_data.size.to_u32
new_p_memsz = new_p_filesz
IO::ByteFormat::LittleEndian.encode(new_p_filesz, out_bytes[ph1_off + 16, 4])
IO::ByteFormat::LittleEndian.encode(new_p_memsz, out_bytes[ph1_off + 20, 4])
puts "Updated PT_LOAD: filesz=0x#{new_p_filesz.to_s(16)} memsz=0x#{new_p_memsz.to_s(16)}"

# 2. Update e_shoff in ELF Header (at offset 0x20):
orig_shoff = IO::ByteFormat::LittleEndian.decode(UInt32, orig_elf[0x20, 4])
new_shoff = orig_shoff + shift
IO::ByteFormat::LittleEndian.encode(new_shoff, out_bytes[0x20, 4])
puts "Updated e_shoff: 0x#{orig_shoff.to_s(16)} -> 0x#{new_shoff.to_s(16)}"

# 3. Update Section Headers:
e_shentsize = 40_u32
13.times do |i|
  hdr = new_shoff + i.to_u32 * e_shentsize
  sh_offset = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[hdr + 0x10, 4])
  if sh_offset >= orig_data_end
    IO::ByteFormat::LittleEndian.encode(sh_offset + shift, out_bytes[hdr + 0x10, 4])
  end
end

# 4. Patch instructions in .text (file offset 0x90):
text_off = 0x90_u32

# Patch PlaySound: point wavBuffer to 0x1900
out_bytes[text_off + 0x194, 4].copy_from(Bytes[0x00, 0x19, 0x42, 0x24]) # addiu v0, v0, 0x1900

# Patch 32-bit transfer size:
# 0x268: lui at, %hi(chunk_size)
# 0x26c: addiu v0, v1, 0x40
# 0x270: ori at, at, %lo(chunk_size)
# 0x274: sw at, 0x10(sp)
hi_size = (chunk_size >> 16).to_u16
lo_size = (chunk_size & 0xFFFF).to_u16

lui_at = (0x0F_u32 << 26) | (1_u32 << 16) | hi_size.to_u32
ori_at = (0x0D_u32 << 26) | (1_u32 << 21) | (1_u32 << 16) | lo_size.to_u32
sw_at = (0x2B_u32 << 26) | (29_u32 << 21) | (1_u32 << 16) | 0x10_u32

IO::ByteFormat::LittleEndian.encode(lui_at, out_bytes[text_off + 0x268, 4])
out_bytes[text_off + 0x26c, 4].copy_from(Bytes[0x40, 0x00, 0x62, 0x24]) # addiu v0, v1, 0x40
IO::ByteFormat::LittleEndian.encode(ori_at, out_bytes[text_off + 0x270, 4])
IO::ByteFormat::LittleEndian.encode(sw_at, out_bytes[text_off + 0x274, 4])
puts "Patched .text+0x268..0x274: 32-bit size #{chunk_size} bytes (lui at, 0x#{hi_size.to_s(16)}; addiu v0, v1, 0x40; ori at, at, 0x#{lo_size.to_s(16)}; sw at, 16(sp))"

# Patch pitch at .text+0x434: li a1, 0x0759 (22,050 Hz exact formula: floor(22050 * 4096 / 48000))
out_bytes[text_off + 0x434, 4].copy_from(Bytes[0x59, 0x07, 0x05, 0x24])
puts "Patched .text+0x434: li a1, 0x0759 (22050 Hz exact PS2Tek formula)"

# Patch TestThread PC-relative jumps
out_bytes[text_off + 0x4f0, 4].copy_from(Bytes[0x1F, 0x00, 0x00, 0x10])
out_bytes[text_off + 0x4f4, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop
out_bytes[text_off + 0x578, 4].copy_from(Bytes[0x97, 0x01, 0x00, 0x10])
out_bytes[text_off + 0x57C, 4].copy_from(Bytes[0x00, 0x00, 0x00, 0x00]) # nop

# Zero out relocations in .rel.text that we overwrote in TestThread
rel_hdr = new_shoff + 3_u32 * e_shentsize
rel_off = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[rel_hdr + 0x10, 4])
rel_size = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[rel_hdr + 0x14, 4])

zero_targets = [0x04f0_u32, 0x0578_u32, 0x0580_u32, 0x0588_u32]
zeroed = 0
(rel_size // 8).times do |i|
  r_off = IO::ByteFormat::LittleEndian.decode(UInt32, out_bytes[rel_off + i * 8, 4])
  if zero_targets.includes?(r_off)
    out_bytes[rel_off + i * 8 + 4, 4].copy_from(Bytes[0, 0, 0, 0])
    zeroed += 1
  end
end
puts "Relocations zeroed: #{zeroed}"

File.write("scratch/S.IRX", out_bytes)
puts "Successfully generated scratch/S.IRX (#{out_bytes.size} bytes) with #{duration_sec.round(2)}s music!"
