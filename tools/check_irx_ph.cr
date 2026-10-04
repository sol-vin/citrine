bytes = File.read("scratch/TESTSPU.irx").to_slice
phoff = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[28, 4])
phnum = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[44, 2])
phentsize = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[42, 2])
phnum.times do |i|
  hdr = phoff + i * phentsize
  p_type = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[hdr, 4])
  p_offset = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[hdr + 4, 4])
  p_vaddr = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[hdr + 8, 4])
  p_filesz = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[hdr + 16, 4])
  p_memsz = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[hdr + 20, 4])
  puts "PH#{i}: type=0x#{p_type.to_s(16)}, off=0x#{p_offset.to_s(16)}, vaddr=0x#{p_vaddr.to_s(16)}, filesz=#{p_filesz}, memsz=#{p_memsz}"
end
