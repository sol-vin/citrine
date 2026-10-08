require "./types"
require "../../compiler/opcode"

module Citrine
  module ISO
    class PhaseExtractor
      class CbcDecoder
        struct DecodedCbc
          property magic : String
          property is_cbc2 : Bool
          property strings : Array(String)
          property constants : Array(CVal)
          property fns : Array(FnEntry)
          property instructions_start_pos : Int64
          property has_button_checks : Bool
          property has_drawing : Bool
          property is_inline_assembly : Bool
          property inline_asm_words : Array(UInt32)
          property has_audio : Bool
          property boot_screen : Bool

          def initialize(
            @magic : String,
            @is_cbc2 : Bool,
            @strings : Array(String),
            @constants : Array(CVal),
            @fns : Array(FnEntry),
            @instructions_start_pos : Int64,
            @has_button_checks : Bool,
            @has_drawing : Bool,
            @is_inline_assembly : Bool,
            @inline_asm_words : Array(UInt32),
            @has_audio : Bool,
            @boot_screen : Bool
          )
          end
        end

        def self.decode(cbc_bytes : Bytes?) : DecodedCbc?
          return nil unless cbc_bytes && cbc_bytes.size > 20

          magic = cbc_bytes.size >= 4 ? String.new(cbc_bytes[0..3]) : ""
          is_cbc2 = (magic == "CBC2")
          return nil unless magic == "CBC1" || is_cbc2

          io = IO::Memory.new(cbc_bytes)
          io.read_string(4) # "CBC1" or "CBC2"
          io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
          num_fns = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          num_consts = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          num_strings = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)

          strings = [] of String
          num_strings.times do
            len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            strings << io.read_string(len)
          end

          constants = [] of CVal
          num_consts.times do
            ctype = io.read_byte.not_nil!
            case ctype
            when 2 # Int32
              v = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, (v.to_i64 & 0xFFFFFFFF_u64).to_u32)
            when 5 # Color
              v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, v)
            when 6 # StringRef
              s_idx = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32, strings[s_idx]? || "")
            when 3 # Float32
              f = io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, PhaseExtractor.encode_f32(f).to_u32, f32_val: f)
            when 4 # Vec2
              io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32)
            when 1 # Bool
              b = io.read_byte.not_nil!
              constants << CVal.new(ctype, b.to_u32)
            else
              io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              constants << CVal.new(ctype, 0_u32)
            end
          end

          fns = [] of FnEntry
          num_fns.times do
            n_idx = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            argc = io.read_byte.not_nil!
            num_regs = io.read_byte.not_nil!
            off = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            cnt = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            fns << FnEntry.new(n_idx, argc, num_regs, off, cnt)
          end

          instructions_start_pos = io.pos

          has_button_checks = false
          has_drawing = false
          has_audio = false
          inline_asm_words = [] of UInt32

          fns.each do |fn|
            io.pos = instructions_start_pos + (fn.offset.to_i64 * 4)
            fn.count.times do
              instr = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              if is_cbc2
                instr_obj = Instruction.new(instr)
                is_call_native = (instr_obj.opcode == Opcode::CallNative)
                is_inline_asm = (instr_obj.opcode == Opcode::InlineAsm)
              else
                op = ((instr >> 24) & 0xFF_u32).to_i
                is_call_native = (op == 52)
                is_inline_asm = (op == 72)
              end
              nat = (instr & 0xFF_u32).to_i
              if is_call_native
                if (nat >= 40 && nat <= 43) || (nat >= 45 && nat <= 48)
                  has_button_checks = true
                end
                if nat == 10 || nat == 11 || (nat >= 20 && nat <= 34) || (nat >= 100 && nat <= 111)
                  has_drawing = true
                end
                if (nat >= 35 && nat <= 37) || (nat >= 220 && nat <= 224) || nat == 233 || nat == 234
                  has_audio = true
                end
              elsif is_inline_asm
                imm = (instr & 0xFFFF_u32).to_i
                if imm < constants.size
                  inline_asm_words << constants[imm].u32_val
                end
              end
            end
          end

          is_inline_assembly = !inline_asm_words.empty?
          has_audio ||= strings.any? do |s|
            down = s.downcase
            down.ends_with?(".vag") || down.ends_with?(".wav") || down.ends_with?(".cas") ||
              down.includes?("cdda") || down.includes?("cd-da") || s.includes?("SPU2")
          end
          boot_screen = !strings.includes?("citrine:boot_screen:false")

          DecodedCbc.new(
            magic: magic,
            is_cbc2: is_cbc2,
            strings: strings,
            constants: constants,
            fns: fns,
            instructions_start_pos: instructions_start_pos,
            has_button_checks: has_button_checks,
            has_drawing: has_drawing,
            is_inline_assembly: is_inline_assembly,
            inline_asm_words: inline_asm_words,
            has_audio: has_audio,
            boot_screen: boot_screen
          )
        rescue
          nil
        end
      end
    end
  end
end
