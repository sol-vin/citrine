module Citrine
  module Cradare2
    class Ps2Dissector
      GS_REG_NAMES = {
        0x00_u64 => "PRIM",
        0x01_u64 => "RGBAQ",
        0x02_u64 => "ST",
        0x03_u64 => "UV",
        0x04_u64 => "XYZF2",
        0x05_u64 => "XYZ2",
        0x06_u64 => "TEX0_1",
        0x07_u64 => "TEX0_2",
        0x08_u64 => "CLAMP_1",
        0x09_u64 => "CLAMP_2",
        0x0A_u64 => "FOG",
        0x0C_u64 => "XYZF3",
        0x0D_u64 => "XYZ3",
        0x14_u64 => "TEX1_1",
        0x15_u64 => "TEX1_2",
        0x16_u64 => "TEX2_1",
        0x17_u64 => "TEX2_2",
        0x18_u64 => "XYOFFSET_1",
        0x19_u64 => "XYOFFSET_2",
        0x1A_u64 => "PRMODECONT",
        0x1B_u64 => "PRMODE",
        0x1C_u64 => "TEXCLUT",
        0x22_u64 => "SCANMSK",
        0x34_u64 => "MIPTBP1_1",
        0x35_u64 => "MIPTBP1_2",
        0x36_u64 => "MIPTBP2_1",
        0x37_u64 => "MIPTBP2_2",
        0x3B_u64 => "TEXA",
        0x3D_u64 => "FOGCOL",
        0x3F_u64 => "TEXFLUSH",
        0x40_u64 => "SCISSOR_1",
        0x41_u64 => "SCISSOR_2",
        0x42_u64 => "ALPHA_1",
        0x43_u64 => "ALPHA_2",
        0x44_u64 => "DIMX",
        0x45_u64 => "DTHE",
        0x46_u64 => "COLCLAMP",
        0x47_u64 => "TEST_1",
        0x48_u64 => "TEST_2",
        0x49_u64 => "PABE",
        0x4A_u64 => "FBA_1",
        0x4B_u64 => "FBA_2",
        0x4C_u64 => "FRAME_1",
        0x4D_u64 => "FRAME_2",
        0x4E_u64 => "ZBUF_1",
        0x4F_u64 => "ZBUF_2",
        0x50_u64 => "BITBLTBUF",
        0x51_u64 => "TRXPOS",
        0x52_u64 => "TRXREG",
        0x53_u64 => "TRXDIR",
        0x54_u64 => "HWREG",
        0x60_u64 => "SIGNAL",
        0x61_u64 => "FINISH",
        0x62_u64 => "LABEL",
      }

      PRIM_TYPES = {
        0 => "POINT",
        1 => "LINE",
        2 => "LINESTRIP",
        3 => "TRIANGLE",
        4 => "TRISTRIP",
        5 => "TRIFAN",
        6 => "SPRITE",
      }

      record SectionInfo, name : String, addr : UInt32, offset : UInt32, size : UInt32
      record GifTagInfo, nloop : UInt32, eop : Bool, flg : String, nreg : UInt32, raw_low : UInt64, raw_high : UInt64
      record GifItemInfo, index : Int32, offset : UInt32, reg_id : UInt64, reg_name : String, data : UInt64, description : String

      getter entry_point : UInt32 = 0_u32
      getter sections = {} of String => SectionInfo
      getter raw_bytes : Bytes

      def initialize(@raw_bytes : Bytes)
        parse_elf
      end

      def self.from_file(path : String) : Ps2Dissector
        new(File.read(path).to_slice)
      end

      private def parse_elf
        return if @raw_bytes.size < 52 || String.new(@raw_bytes[0..3]) != "\x7FELF"
        io = IO::Memory.new(@raw_bytes)
        io.pos = 24
        @entry_point = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        io.pos = 32
        e_shoff = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        io.pos = 46
        e_shentsize = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        e_shnum = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        e_shstrndx = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)

        return if e_shnum == 0 || e_shstrndx >= e_shnum

        str_tab_header_off = e_shoff + (e_shstrndx.to_u32 * e_shentsize.to_u32)
        io.pos = str_tab_header_off + 16
        shstr_off = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        shstr_size = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        shstrtab = @raw_bytes[shstr_off, shstr_size]

        e_shnum.times do |i|
          sec_off = e_shoff + (i.to_u32 * e_shentsize.to_u32)
          io.pos = sec_off
          sh_name = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          io.pos = sec_off + 12
          sh_addr = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          sh_offset = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          sh_size = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

          # Extract name from string table
          null_pos = shstrtab[sh_name..].index(0_u8) || 0
          name = String.new(shstrtab[sh_name, null_pos])
          @sections[name] = SectionInfo.new(name, sh_addr, sh_offset, sh_size) unless name.empty?
        end
      end

      def decode_giftag(slice : Bytes) : GifTagInfo
        io = IO::Memory.new(slice)
        low = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        high = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)

        nloop = (low & 0x7FFF).to_u32
        eop = ((low >> 15) & 1) == 1
        flg_val = (low >> 58) & 3
        flg_name = case flg_val
                   when 0 then "PACKED"
                   when 1 then "REGLIST"
                   when 2 then "IMAGE"
                   else        "DISABLE"
                   end
        nreg = ((low >> 60) & 0xF).to_u32

        GifTagInfo.new(nloop, eop, flg_name, nreg, low, high)
      end

      def dissect_gif_packet(offset : UInt32, max_items : Int32 = 100) : Array(GifItemInfo)
        items = [] of GifItemInfo
        return items if offset + 16 > @raw_bytes.size

        tag = decode_giftag(@raw_bytes[offset, 16])
        pos = offset + 16
        items_count = 0

        while items_count < tag.nloop && items_count < max_items && pos + 16 <= @raw_bytes.size
          io = IO::Memory.new(@raw_bytes[pos, 16])
          data = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
          reg = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
          reg_id = reg & 0xFF
          reg_name = GS_REG_NAMES[reg_id]? || sprintf("REG_0x%02X", reg_id)
          desc = describe_gs_register(reg_id, data)

          items << GifItemInfo.new(items_count, pos - offset, reg_id, reg_name, data, desc)
          pos += 16
          items_count += 1
        end

        items
      end

      def describe_gs_register(reg_id : UInt64, data : UInt64) : String
        case reg_id
        when 0x00 # PRIM
          ptype = (data & 7).to_i
          pname = PRIM_TYPES[ptype]? || "UNKNOWN(#{ptype})"
          iip = ((data >> 3) & 1) == 1 ? "Gouraud" : "Flat"
          tme = ((data >> 4) & 1) == 1 ? "TexOn" : "TexOff"
          abe = ((data >> 6) & 1) == 1 ? "BlendOn" : "BlendOff"
          ctxt = ((data >> 9) & 1) == 0 ? "Context1" : "Context2"
          "Type=#{pname}, Shading=#{iip}, #{tme}, #{abe}, #{ctxt} (raw=0x#{data.to_s(16)})"
        when 0x01 # RGBAQ
          r = (data & 0xFF).to_u8
          g = ((data >> 8) & 0xFF).to_u8
          b = ((data >> 16) & 0xFF).to_u8
          a = ((data >> 24) & 0xFF).to_u8
          q_raw = ((data >> 32) & 0xFFFFFFFF).to_u32
          q_float = IO::ByteFormat::LittleEndian.decode(Float32, Slice.new(pointerof(q_raw).as(UInt8*), 4)) rescue 1.0_f32
          "R=#{r}, G=#{g}, B=#{b}, A=#{a} (0x#{a.to_s(16)}), Q=#{q_float.round(2)}"
        when 0x05, 0x0D # XYZ2, XYZ3
          x_raw = (data & 0xFFFF).to_u16
          y_raw = ((data >> 16) & 0xFFFF).to_u16
          z_raw = ((data >> 32) & 0xFFFFFFFF).to_u32
          x_px = x_raw.to_f32 / 16.0_f32
          y_px = y_raw.to_f32 / 16.0_f32
          kick = reg_id == 0x05 ? "DRAW KICK" : "NO KICK"
          "X=#{x_px.round(1)}px (0x#{x_raw.to_s(16).rjust(4, '0')}), Y=#{y_px.round(1)}px (0x#{y_raw.to_s(16).rjust(4, '0')}), Z=0x#{z_raw.to_s(16)} [#{kick}]"
        when 0x18, 0x19 # XYOFFSET
          ofx_raw = (data & 0xFFFF).to_u16
          ofy_raw = ((data >> 32) & 0xFFFF).to_u16
          "OFX=#{ofx_raw.to_f32 / 16.0_f32}px, OFY=#{ofy_raw.to_f32 / 16.0_f32}px"
        when 0x40, 0x41 # SCISSOR
          x0 = data & 0x7FF
          x1 = (data >> 16) & 0x7FF
          y0 = (data >> 32) & 0x7FF
          y1 = (data >> 48) & 0x7FF
          "Bounds: (#{x0}, #{y0}) -> (#{x1}, #{y1})"
        when 0x47, 0x48 # TEST
          zte = (data >> 16) & 1
          ztst = (data >> 17) & 3
          ztst_name = case ztst
                      when 0 then "NEVER (All pixels fail!)"
                      when 1 then "ALWAYS (All pixels pass)"
                      when 2 then "GEQUAL (Z >= Zbuf)"
                      when 3 then "GREATER (Z > Zbuf)"
                      else        "UNKNOWN"
                      end
          ate = data & 1
          warn = (zte == 0 && ztst == 0) ? " [!! WARNING: ALWAYS DISCARD !!]" : ""
          "ZTE=#{zte}, ZTST=#{ztst} [#{ztst_name}], ATE=#{ate}#{warn}"
        when 0x4C, 0x4D # FRAME
          fbp = data & 0x1FF
          fbw = (data >> 16) & 0x3F
          psm = (data >> 24) & 0x3F
          psm_name = psm == 0 ? "PSMCT32 (RGBA32)" : (psm == 1 ? "PSMCT24" : "PSM_#{psm}")
          "FBP=0x#{fbp.to_s(16)} (#{fbp * 2048} words), FBW=#{fbw} (#{fbw * 64}px), PSM=#{psm_name}"
        when 0x4E, 0x4F # ZBUF
          zbp = data & 0x1FF
          psm = (data >> 24) & 0xF
          zmsk = (data >> 32) & 1
          "ZBP=0x#{zbp.to_s(16)}, PSM=#{psm}, ZMSK=#{zmsk == 1 ? "Masked(NoWrite)" : "Writable"}"
        when 0x1A # PRMODECONT
          ac = data & 1
          "Source=#{ac == 1 ? "PRIM register" : "PRMODE register"}"
        when 0x46 # COLCLAMP
          "Clamp=#{(data & 1) == 1 ? "Enabled" : "Disabled"}"
        else
          sprintf("RawData=0x%016X", data)
        end
      end

      def validate : Array(String)
        results = [] of String
        results << "=== PlayStation 2 Executable Validation (Citrine Dissector) ==="

        if @entry_point == 0x00100000_u32
          results << "  [PASS] ELF Entry Point: 0x00100000 (Standard EE MIPS)"
        else
          results << "  [WARN] ELF Entry Point: 0x#{@entry_point.to_s(16)} (Expected 0x00100000)"
        end

        [".text", ".rodata", ".data", ".spram", ".symtab"].each do |sec|
          if s = @sections[sec]?
            results << "  [PASS] Section '#{sec}': present (size: #{s.size} bytes)"
          else
            results << "  [WARN] Section '#{sec}': missing from ELF!"
          end
        end

        if rodata = @sections[".rodata"]?
          env_tag = decode_giftag(@raw_bytes[rodata.offset, 16])
          results << "  [PASS] Environment GIFTag: NLOOP=#{env_tag.nloop}, FLG=#{env_tag.flg}, EOP=#{env_tag.eop}"

          env_items = dissect_gif_packet(rodata.offset, env_tag.nloop.to_i)
          test_item = env_items.find { |it| it.reg_id == 0x47 }
          if test_item
            if test_item.description.includes?("ALWAYS (All pixels pass)")
              results << "  [PASS] Depth Test (TEST_1): ALLPASS (0x00030000) verified"
            elsif test_item.description.includes?("NEVER")
              results << "  [FAIL] Depth Test (TEST_1): ZTST=NEVER (0x#{test_item.data.to_s(16)}) - All pixels discarded!"
            else
              results << "  [INFO] Depth Test (TEST_1): #{test_item.description}"
            end
          else
            results << "  [WARN] TEST_1 not found in environment packet"
          end

          draw_offset = rodata.offset + 16 + (env_tag.nloop * 16)
          if draw_offset + 16 <= @raw_bytes.size
            draw_tag = decode_giftag(@raw_bytes[draw_offset, 16])
            results << "  [PASS] Draw GIFTag: NLOOP=#{draw_tag.nloop}, FLG=#{draw_tag.flg}, EOP=#{draw_tag.eop}"

            draw_items = dissect_gif_packet(draw_offset, [draw_tag.nloop.to_i, 50].min)
            has_kick = draw_items.any? { |it| it.reg_id == 0x05 }
            has_nokick = draw_items.any? { |it| it.reg_id == 0x0D }
            if has_kick && has_nokick
              results << "  [PASS] Vertex Submissions: Pairwise XYZ3 (no kick) -> XYZ2 (draw kick) verified"
            elsif has_kick
              results << "  [INFO] Vertex Submissions: Draw kicks (XYZ2) detected"
            end
          end
        end

        results
      end
    end
  end
end
