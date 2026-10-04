bytes = File.read("scratch/TESTSPU.irx").to_slice

e_entry = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[24, 4])
e_phoff = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[28, 4])
e_shoff = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[32, 4])
e_shnum = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[48, 2])
e_shstrndx = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[50, 2])

puts "entry=0x#{e_entry.to_s(16)}, shoff=0x#{e_shoff.to_s(16)}, shnum=#{e_shnum}, shstrndx=#{e_shstrndx}"

# Read section string table
shstr_sh = bytes[e_shoff + e_shstrndx * 40, 40]
shstr_offset = IO::ByteFormat::LittleEndian.decode(UInt32, shstr_sh[16, 4])
shstr_size = IO::ByteFormat::LittleEndian.decode(UInt32, shstr_sh[20, 4])

e_shnum.times do |i|
  sh = bytes[e_shoff + i * 40, 40]
  sh_name_idx = IO::ByteFormat::LittleEndian.decode(UInt32, sh[0, 4])
  sh_type = IO::ByteFormat::LittleEndian.decode(UInt32, sh[4, 4])
  sh_flags = IO::ByteFormat::LittleEndian.decode(UInt32, sh[8, 4])
  sh_addr = IO::ByteFormat::LittleEndian.decode(UInt32, sh[12, 4])
  sh_offset = IO::ByteFormat::LittleEndian.decode(UInt32, sh[16, 4])
  sh_size = IO::ByteFormat::LittleEndian.decode(UInt32, sh[20, 4])

  # Extract name from shstr
  name_bytes = bytes[shstr_offset + sh_name_idx, 32]
  zero = name_bytes.index(0_u8) || 32
  name = String.new(name_bytes[0, zero])

  puts sprintf("[%2d] %-16s type=0x%02X flags=0x%02X addr=0x%08X offset=0x%08X size=0x%06X (%d)",
               i, name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_size)
end
