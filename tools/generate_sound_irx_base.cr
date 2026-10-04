require "base64"

bytes = File.read("scratch/TESTSPU.irx").to_slice
b64 = Base64.strict_encode(bytes)

code = <<-CR
require "base64"

module Citrine
  module ISO
    module SoundIrxBase
      B64_DATA = "#{b64}"

      @@cached_bytes : Bytes? = nil

      def self.bytes : Bytes
        @@cached_bytes ||= Base64.decode(B64_DATA)
      end
    end
  end
end
CR

File.write("src/citrine/iso/sound_irx_base.cr", code)
puts "Generated src/citrine/iso/sound_irx_base.cr (#{bytes.size} bytes IRX, #{b64.size} b64 chars)"
