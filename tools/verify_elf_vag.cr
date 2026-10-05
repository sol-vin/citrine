bytes = File.read("examples/10_cd_player/game.iso").to_slice
# Extract CITRINE.ELF (sector 22, size 716516)
elf = bytes[22 * 2048, 716516]
# In elf_writer:
# seg_align = 0x1000
# text + rodata size ~ 0x1E1D5
# pad size ~ 0x3970
# data offset in file:
# Let's search for "VAGp" inside the ELF
vag_pos = (0..elf.size - 4).find { |i| elf[i, 4] == Bytes[86, 65, 71, 112] }
if vag_pos
  puts "Found VAGp in CITRINE.ELF at file offset 0x#{vag_pos.to_s(16)}"
  # Check block 0 at vag_pos + 48
  blk0 = elf[vag_pos + 48, 16]
  shift = blk0[0] & 0x0F
  filter = (blk0[0] >> 4) & 0x0F
  flags = blk0[1]
  puts "VAG block 0 in ELF: filter=#{filter}, shift=#{shift}, flags=#{flags}"
else
  puts "VAGp not found in CITRINE.ELF!"
end
