module Citrine
  # Action Replay & GameShark Cheat Engine for PlayStation 2 EE
  # Supports RAW / AR2 cheat codes, memory watches, and dynamic VBlank memory injection
  module ActionReplay
    enum CodeType : UInt8
      Write8Bit   = 0x0_u8 # 0xxxxxxx 000000yy
      Write16Bit  = 0x1_u8 # 1xxxxxxx 0000yyyy
      Write32Bit  = 0x2_u8 # 2xxxxxxx yyyyyyyy
      EqualCheck  = 0xD_u8 # Dxxxxxxx 0000yyyy (if equal, execute next)
      MasterCode  = 0x9_u8 # 9xxxxxxx yyyyyyyy
      HookHandler = 0xF_u8 # Fxxxxxxx yyyyyyyy (VBlank hook address)
    end

    struct CheatCode
      property type : CodeType
      property address : UInt32
      property value : UInt32

      def initialize(@type : CodeType, @address : UInt32, @value : UInt32)
      end

      # Parse a standard RAW cheat line: "20100020 00000000"
      def self.parse?(line : String) : CheatCode?
        cleaned = line.strip.gsub(/\s+/, " ")
        parts = cleaned.split(" ")
        return nil unless parts.size == 2

        addr_str = parts[0]
        val_str = parts[1]
        return nil unless addr_str.size == 8 && val_str.size == 8

        type_char = addr_str[0].upcase
        type_num = type_char.to_i?(16) || 0
        raw_addr = addr_str.to_u32?(16) || 0_u32
        target_addr = (raw_addr & 0x0FFFFFFF_u32)
        val = val_str.to_u32?(16) || 0_u32

        type = case type_num
               when 0 then CodeType::Write8Bit
               when 1 then CodeType::Write16Bit
               when 2 then CodeType::Write32Bit
               when 0xD then CodeType::EqualCheck
               when 0x9 then CodeType::MasterCode
               when 0xF then CodeType::HookHandler
               else CodeType::Write32Bit
               end

        CheatCode.new(type, target_addr, val)
      end
    end

    class CheatEngine
      property codes : Array(CheatCode) = [] of CheatCode

      def initialize
      end

      def add_code(line : String)
        if code = CheatCode.parse?(line)
          @codes << code
        end
      end

      # Generates MIPS R5900 assembly instructions to apply all active cheats on VBlank
      def emit_vblank_hook_asm(emitter : MIPS::MipsEmitter)
        @codes.each do |code|
          case code.type
          when CodeType::Write8Bit
            emitter.lui(MIPS::T0, (code.address >> 16).to_i32)
            emitter.ori(MIPS::T0, MIPS::T0, (code.address & 0xFFFF).to_i32)
            emitter.ori(MIPS::T1, MIPS::ZERO, (code.value & 0xFF).to_i32)
            emitter.sb(MIPS::T1, 0, MIPS::T0)
          when CodeType::Write16Bit
            emitter.lui(MIPS::T0, (code.address >> 16).to_i32)
            emitter.ori(MIPS::T0, MIPS::T0, (code.address & 0xFFFF).to_i32)
            emitter.ori(MIPS::T1, MIPS::ZERO, (code.value & 0xFFFF).to_i32)
            emitter.sh(MIPS::T1, 0, MIPS::T0)
          when CodeType::Write32Bit
            emitter.lui(MIPS::T0, (code.address >> 16).to_i32)
            emitter.ori(MIPS::T0, MIPS::T0, (code.address & 0xFFFF).to_i32)
            emitter.lui(MIPS::T1, (code.value >> 16).to_i32)
            emitter.ori(MIPS::T1, MIPS::T1, (code.value & 0xFFFF).to_i32)
            emitter.sw(MIPS::T1, 0, MIPS::T0)
          else
            # Other code types can be extended
          end
        end
      end
    end
  end
end
