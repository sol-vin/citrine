module Citrine
  # Sony PlayStation 2 Memory Card Subsystem (MCMAN / MCDEV)
  # Provides compliant paths and icon.sys structures for saving to mc0: / mc1:
  module MemoryCard
    # Memory card slot identifiers
    enum Port : UInt8
      Slot1 = 0 # mc0:
      Slot2 = 1 # mc1:
    end

    # Standard PS2 icon.sys structure header (964 bytes)
    # Required by Sony BIOS browser to display 3D icons and save titles
    struct IconSys
      property title_japanese_or_english : String
      property line_break_position : UInt16
      property background_transparency : UInt32
      property bg_color_top_left : UInt32
      property bg_color_top_right : UInt32
      property bg_color_bottom_left : UInt32
      property bg_color_bottom_right : UInt32

      def initialize(
        @title_japanese_or_english : String = "Citrine Save Data",
        @line_break_position : UInt16 = 16_u16,
        @background_transparency : UInt32 = 0x80_u32,
        @bg_color_top_left : UInt32 = 0x00000000_u32,
        @bg_color_top_right : UInt32 = 0x00000000_u32,
        @bg_color_bottom_left : UInt32 = 0x00000000_u32,
        @bg_color_bottom_right : UInt32 = 0x00000000_u32
      )
      end

      # Serializes a valid 964-byte binary icon.sys file
      def to_slice : Bytes
        io = IO::Memory.new(964)
        io.write("PS2SYS\0".to_slice)
        io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
        io.write_bytes(@line_break_position, IO::ByteFormat::LittleEndian)
        io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
        io.write_bytes(@background_transparency, IO::ByteFormat::LittleEndian)
        io.write_bytes(@bg_color_top_left, IO::ByteFormat::LittleEndian)
        io.write_bytes(@bg_color_top_right, IO::ByteFormat::LittleEndian)
        io.write_bytes(@bg_color_bottom_left, IO::ByteFormat::LittleEndian)
        io.write_bytes(@bg_color_bottom_right, IO::ByteFormat::LittleEndian)

        # Light sources & ambient
        16.times { io.write_bytes(0_u32, IO::ByteFormat::LittleEndian) }

        # Title text (up to 32 characters in Shift-JIS or ASCII, null padded)
        title_bytes = @title_japanese_or_english.to_slice[0...64]
        io.write(title_bytes)
        (64 - title_bytes.size).times { io.write_byte(0_u8) }

        # Icon filenames
        io.write("icon.icn\0".to_slice) # Normal icon
        (32 - 9).times { io.write_byte(0_u8) }
        io.write("copy.icn\0".to_slice) # Copying icon
        (32 - 9).times { io.write_byte(0_u8) }
        io.write("del.icn\0".to_slice)  # Deleting icon
        (32 - 8).times { io.write_byte(0_u8) }

        # Pad to exactly 964 bytes
        while io.size < 964
          io.write_byte(0_u8)
        end

        io.to_slice
      end
    end

    def self.save_path(title_id : String, filename : String, port : Port = Port::Slot1) : String
      slot = port == Port::Slot1 ? "mc0" : "mc1"
      "#{slot}:/#{title_id}/#{filename}"
    end
  end
end
