require "citrine"

# Simple Hello World print function for Sony PlayStation 2

puts "Hello, world! sol.vin here!"
puts "1234567890ABCDEF"
debug_puts "[CITRINE DEBUG] Hello World booted on PlayStation 2 EE!"

Citrine.main_loop do
	sleep 10
	puts "One more for the road! or not idk"
end

