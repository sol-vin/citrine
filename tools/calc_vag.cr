vag = File.read("examples/10_video_and_audio/theme.vag").to_slice
puts "size: #{vag.size}"
num_blocks = (vag.size - 48) // 16
puts "num_blocks: #{num_blocks}"
num_samples = num_blocks * 28
puts "num_samples: #{num_samples}"
puts "duration: #{num_samples / 22050.0} sec"
puts "first block: #{vag[48..63].to_a}"
puts "last block: #{vag[-16..-1].to_a}"
