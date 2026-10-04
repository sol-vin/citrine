bytes = File.read("scratch/TESTSPU.irx").to_slice
rel_offset = 0x571C_u32
rel_size = 0x950_u32
(rel_size // 8).times do |i|
  off = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[rel_offset + i * 8, 4])
  info = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[rel_offset + i * 8 + 4, 4])
  if off >= 0x170_u32 && off <= 0x480_u32
    sym_idx = info >> 8
    rel_type = info & 0xFF
    puts "reloc at .text+0x#{off.to_s(16)}: sym=#{sym_idx}, type=#{rel_type}"
  end
end
