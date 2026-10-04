bytes = File.read("scratch/TESTSPU.irx").to_slice
# Print instructions from .text+0x240 to .text+0x2a0
offset = 0x90_u32 + 0x240_u32
16.times do |i|
  w = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[offset + i*4, 4])
  puts ".text+0x#{(0x240 + i*4).to_s(16)}: 0x#{w.to_s(16).rjust(8, '0')}"
end
