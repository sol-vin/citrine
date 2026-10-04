# tools/create_sound_irx_payload.cr
# Encodes scratch/S.IRX into src/citrine/iso/sound_irx_payload.cr

require "base64"

s_irx_bytes = File.read("scratch/S.IRX").to_slice
b64 = Base64.strict_encode(s_irx_bytes)

content = <<-CR
require "base64"

module Citrine
  module ISO
    module SoundIrxPayload
      B64_DATA = "#{b64}"

      @@cached_bytes : Bytes? = nil

      def self.bytes : Bytes
        @@cached_bytes ||= Base64.decode(B64_DATA)
      end
    end
  end
end
CR

File.write("src/citrine/iso/sound_irx_payload.cr", content)
puts "Successfully created src/citrine/iso/sound_irx_payload.cr (#{b64.size} base64 chars, #{s_irx_bytes.size} bytes IRX)"
