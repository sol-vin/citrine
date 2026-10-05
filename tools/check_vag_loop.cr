bytes = File.read("examples/10_cd_player/theme.vag").to_slice
puts "Total size: #{bytes.size}"

(1..4).each do |b|
  offset = bytes.size - (5 - b) * 16
  blk = bytes[offset, 16]
  hex = blk.map { |x| sprintf("%02X", x) }.join(" ")
  puts sprintf("Block %d (at 0x%X): %s (flag: 0x%02X)", b, offset, hex, blk[1])
end
