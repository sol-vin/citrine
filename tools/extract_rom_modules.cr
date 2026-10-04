bytes = File.read("C:/Users/Ian/Documents/PCSX2/bios/scph39001.bin").to_slice

pos = 0
found_romdir = 0
while pos < 0x20000
  if String.new(bytes[pos, 5]) == "RESET" && bytes[pos + 5] == 0
    found_romdir = pos
    break
  end
  pos += 16
end

curr = found_romdir
offset = 0_u32

while curr < bytes.size - 16
  name_bytes = bytes[curr, 10]
  zero_idx = name_bytes.index(0_u8) || 10
  name = String.new(name_bytes[0, zero_idx])
  break if name.empty?
  ext_info = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[curr + 10, 2])
  size = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[curr + 12, 4])

  # In PS2 ROM, files are packed consecutively aligned to 16 bytes.
  # But RESET is at the very beginning (offset 0).
  if ["TESTSPU", "LIBSD", "CLEARSPU", "PADMAN", "SIO2MAN", "CDVDMAN", "IOPBTCONF", "IOPBTCON2"].includes?(name)
    puts "Found #{name}: offset=0x#{offset.to_s(16)}, size=#{size}"
    File.write("scratch/#{name}.txt", bytes[offset, size])
  end

  aligned_size = (size + 15) & ~15_u32
  offset += aligned_size
  curr += 16
end
