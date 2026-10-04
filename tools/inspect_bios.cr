bytes = File.read("C:/Users/Ian/Documents/PCSX2/bios/scph39001.bin").to_slice

# In PS2 BIOS, ROMDIR starts at the end of RESET.
# Let's search for "RESET\0"
pos = 0
found_romdir = 0
while pos < 0x20000
  if String.new(bytes[pos, 5]) == "RESET" && bytes[pos + 5] == 0
    found_romdir = pos
    break
  end
  pos += 16
end

puts "ROMDIR found at offset: 0x#{found_romdir.to_s(16)}"

curr = found_romdir
while curr < bytes.size - 16
  name_bytes = bytes[curr, 10]
  # null terminate
  zero_idx = name_bytes.index(0_u8) || 10
  name = String.new(name_bytes[0, zero_idx])
  break if name.empty?
  ext_info = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[curr + 10, 2])
  size = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[curr + 12, 4])
  puts sprintf("%-12s ext: 0x%04X size: %8d (0x%X)", name, ext_info, size, size)
  curr += 16
end
