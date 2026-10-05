orig = File.read("examples/10_cd_player/theme.vag").to_slice
mem = IO::Memory.new(567056)
mem.write(orig[0..43])
4.times { mem.write_byte(0_u8) } # pad header to 48 bytes (0x30)
mem.write(orig[44..-1])

fixed = mem.to_slice
puts "New size: #{fixed.size}"

# Verify block alignment
5.times do |i|
  blk = fixed[48 + i * 16, 16]
  shift = blk[0] & 0x0F
  filter = (blk[0] >> 4) & 0x0F
  flags = blk[1]
  puts "  blk #{i}: filter=#{filter}, shift=#{shift}, flags=#{flags}"
end

last_blk = fixed[-16..-1]
puts "  last blk: filter=#{(last_blk[0] >> 4) & 0x0F}, shift=#{last_blk[0] & 0x0F}, flags=#{last_blk[1]}"

File.write("examples/10_cd_player/theme.vag", fixed)
puts "Wrote corrected theme.vag (567056 bytes)"
