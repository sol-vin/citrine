bytes = File.read("examples/10_video_and_audio/game.iso").to_slice
# Extract S.IRX (sector 376, size 26943)
s_irx = bytes[376 * 2048, 26943]
# Check .text+0x260 (offset 0x90 + 0x260 = 0x2F0)
# Should be: lui v0, 0x0010 (10 00 02 3C), ori v0, v0, 0x0030 (30 00 42 34)
w0 = IO::ByteFormat::LittleEndian.decode(UInt32, s_irx[0x2F0, 4])
w1 = IO::ByteFormat::LittleEndian.decode(UInt32, s_irx[0x2F4, 4])
w2 = IO::ByteFormat::LittleEndian.decode(UInt32, s_irx[0x2F8, 4])
w3 = IO::ByteFormat::LittleEndian.decode(UInt32, s_irx[0x2FC, 4])
puts "S.IRX at 0x2F0: 0x#{w0.to_s(16)} (lui v0, 0x10)"
puts "S.IRX at 0x2F4: 0x#{w1.to_s(16)} (ori v0, v0, 0x30)"
puts "S.IRX at 0x2F8: 0x#{w2.to_s(16)} (lui v1, 0x8)"
puts "S.IRX at 0x2FC: 0x#{w3.to_s(16)} (ori v1, v1, 0xa6e0)"

# Check relocations at 0x571C
rel_offset = 0x571C_u32
rel_size = 0x950_u32
check_relocs = [0x190_u32, 0x194_u32, 0x260_u32, 0x264_u32]
found_relocs = [] of UInt32
(rel_size // 8).times do |i|
  off = IO::ByteFormat::LittleEndian.decode(UInt32, s_irx[rel_offset + i * 8, 4])
  info = IO::ByteFormat::LittleEndian.decode(UInt32, s_irx[rel_offset + i * 8 + 4, 4])
  if check_relocs.includes?(off) && info != 0
    found_relocs << off
  end
end
puts "Non-zero relocations found at patched sites: #{found_relocs.inspect}"
