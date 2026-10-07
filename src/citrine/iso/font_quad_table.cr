require "../gs/gif_packet_builder"

module Citrine
  module ISO
    # Precomputed quad primitives for 5x7 ASCII font glyphs (ASCII 0x20..0x7E, 95 characters).
    # Each character occupies 16 quad slots (32 UInt32 words = 128 bytes).
    # Unused quad slots in each character are padded with {0_u32, 0_u32}.
    # Total table size: 95 * 128 bytes = 12,160 bytes.
    module FontQuadTable
      DATA = begin
        font = Citrine::GS::GifPacketBuilder::FONT_5X7
        words = Array(UInt32).new(95 * 32, 0_u32)
        (0x20..0x7E).each_with_index do |ascii_code, char_idx|
          ch = ascii_code.chr
          glyph = font[ch.upcase]? || font['?']? || [0x00, 0x00, 0x00, 0x00, 0x00]
          quads = [] of Tuple(UInt32, UInt32)
          5.times do |col|
            in_run = false
            run_start = 0
            7.times do |row|
              pixel = ((glyph[col] >> row) & 1) == 1
              if pixel && !in_run
                in_run = true
                run_start = row
              elsif !pixel && in_run
                in_run = false
                x1 = col
                x2 = col + 1
                y1 = run_start
                y2 = row
                xyz3 = ((y1.to_u32 << 4) << 16) | (x1.to_u32 << 4)
                xyz2 = ((y2.to_u32 << 4) << 16) | (x2.to_u32 << 4)
                quads << {xyz3, xyz2}
              end
            end
            if in_run
              x1 = col
              x2 = col + 1
              y1 = run_start
              y2 = 7
              xyz3 = ((y1.to_u32 << 4) << 16) | (x1.to_u32 << 4)
              xyz2 = ((y2.to_u32 << 4) << 16) | (x2.to_u32 << 4)
              quads << {xyz3, xyz2}
            end
          end
          # Fill up to 16 quads
          base_word = char_idx * 32
          quads.each_with_index do |q, qi|
            break if qi >= 16
            words[base_word + qi * 2] = q[0]
            words[base_word + qi * 2 + 1] = q[1]
          end
        end
        words
      end
    end
  end
end
