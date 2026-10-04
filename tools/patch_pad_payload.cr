# tools/patch_pad_payload.cr
# Patches pad_runtime.bin to load cdrom0:\S.IRX;1 instead of rom0:TESTSPU

bytes = File.read("scratch/pad_runtime.bin").to_slice.dup

target_str = "rom0:TESTSPU".to_slice
found_idx = nil

(0..bytes.size - target_str.size).each do |i|
  match = true
  target_str.size.times do |j|
    if bytes[i + j] != target_str[j]
      match = false
      break
    end
  end
  if match
    found_idx = i
    break
  end
end

if found_idx.nil?
  puts "ERROR: rom0:TESTSPU not found in pad_runtime.bin!"
  exit(1)
end

puts "Found rom0:TESTSPU at offset 0x#{found_idx.to_s(16)}"

new_str = "cdrom0:\\S.IRX;1\0"
puts "Replacing with '#{new_str}' (length #{new_str.bytesize} bytes)..."

new_str.bytesize.times do |j|
  bytes[found_idx + j] = new_str.to_slice[j]
end

File.write("scratch/pad_runtime.bin", bytes)

b64 = Base64.strict_encode(bytes)
File.write("scratch/pad_runtime.b64", b64)

# Update src/citrine/iso/pad_runtime_payload.cr
content = <<-CR
require "base64"

module Citrine
  module ISO
    module PadRuntimePayload
      VADDR            = 0x00180000_u32
      INIT_ENTRY       = 0x00180000_u32
      POLL_ENTRY       = 0x00180010_u32
      SOUND_PLAY_ENTRY = 0x00180020_u32
      SOUND_STOP_ENTRY = 0x00180030_u32
      MEM_SIZE         = 0x00006000_u32

      B64_DATA = "#{b64}"

      @@cached_bytes : Bytes? = nil

      def self.bytes : Bytes
        @@cached_bytes ||= Base64.decode(B64_DATA)
      end
    end
  end
end
CR

File.write("src/citrine/iso/pad_runtime_payload.cr", content)
puts "Successfully updated src/citrine/iso/pad_runtime_payload.cr with #{b64.size} base64 chars"
