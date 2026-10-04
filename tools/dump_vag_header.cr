bytes = File.read("examples/10_video_and_audio/track01.vag").to_slice
64.times do |i|
  puts "byte #{i} (0x#{i.to_s(16)}): #{bytes[i]} (0x#{bytes[i].to_s(16)})"
end
