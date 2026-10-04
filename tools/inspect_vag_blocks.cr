bytes = File.read("examples/10_video_and_audio/theme.vag").to_slice
puts "If data starts at 44 (0x2c):"
5.times do |i|
  blk = bytes[44 + i * 16, 16]
  shift = blk[0] & 0x0F
  filter = (blk[0] >> 4) & 0x0F
  flags = blk[1]
  puts "  blk #{i}: filter=#{filter}, shift=#{shift}, flags=#{flags}"
end

puts "\nIf data starts at 48 (0x30):"
5.times do |i|
  blk = bytes[48 + i * 16, 16]
  shift = blk[0] & 0x0F
  filter = (blk[0] >> 4) & 0x0F
  flags = blk[1]
  puts "  blk #{i}: filter=#{filter}, shift=#{shift}, flags=#{flags}"
end
