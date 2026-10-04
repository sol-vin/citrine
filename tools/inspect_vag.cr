bytes = File.read("examples/10_video_and_audio/theme.vag").to_slice
puts "Magic: #{String.new(bytes[0, 4])}"
puts "Version: #{IO::ByteFormat::BigEndian.decode(UInt32, bytes[4, 4])}"
puts "Data size: #{IO::ByteFormat::BigEndian.decode(UInt32, bytes[12, 4])}"
puts "Sample rate: #{IO::ByteFormat::BigEndian.decode(UInt32, bytes[16, 4])}"
puts "Name: #{String.new(bytes[32, 16]).rstrip('\0')}"
