require "../../gs/gif_packet_builder"

module Citrine
  module ISO
    class ProgramProfile
      property phases : Array(Citrine::GS::Phase)
      property boot_messages : Array(String)
      property loop_start_phase : Int32
      property is_animated : Bool
      property has_button_checks : Bool
      property is_inline_assembly : Bool
      property inline_asm_words : Array(UInt32)
      property has_audio : Bool
      property num_tracks : Int32
      property bank_dur_ms : UInt32
      property frames_per_bank : UInt32
      property boot_screen : Bool

      def initialize(
        @phases = [] of Citrine::GS::Phase,
        @boot_messages = [] of String,
        @loop_start_phase = 0,
        @is_animated = false,
        @has_button_checks = false,
        @is_inline_assembly = false,
        @inline_asm_words = [] of UInt32,
        @has_audio = false,
        @num_tracks = 1,
        @bank_dur_ms = 1195_u32,
        @frames_per_bank = 72_u32,
        @boot_screen = true,
      )
      end
    end

    class ChannelInstance
      property capacity : Int32
      property items : Array(Int64)

      def initialize(@capacity : Int32)
        @items = [] of Int64
      end
    end

    class FiberFrame
      property pc : Int32
      property instructions : Array(UInt32)
      property caller_dest : Int32
      property caller_reg_base : Int32

      def initialize(@pc : Int32, @instructions : Array(UInt32), @caller_dest : Int32, @caller_reg_base : Int32)
      end
    end

    class FiberContext
      property fn_idx : Int32
      property pc : Int32
      property regs : Array(Int64)
      property done : Bool = false
      property instructions : Array(UInt32)
      property call_stack : Array(FiberFrame)
      property reg_base : Int32

      def initialize(@fn_idx : Int32, @instructions : Array(UInt32), num_regs : Int32 = 64)
        @pc = 0
        @regs = Array(Int64).new(1024, 0_i64)
        @done = false
        @call_stack = [] of FiberFrame
        @reg_base = 0
      end
    end

    struct CVal
      property type : UInt8
      property u32_val : UInt32
      property str_val : String
      property f32_val : Float32

      def initialize(@type : UInt8, @u32_val : UInt32 = 0_u32, @str_val : String = "", @f32_val : Float32 = 0.0_f32)
      end
    end

    struct FnEntry
      property name_idx : UInt32
      property argc : UInt8
      property num_regs : UInt8
      property offset : UInt32
      property count : UInt32

      def initialize(@name_idx, @argc, @num_regs, @offset, @count)
      end
    end

    struct CallFrame
      property return_pc : Int32
      property caller_instructions : Array(UInt32)
      property caller_dest : Int32
      property caller_reg_base : Int32

      def initialize(@return_pc, @caller_instructions, @caller_dest, @caller_reg_base)
      end
    end

    struct AllocationRecord
      property base_addr : Int64
      property size_bytes : Int32
      property context_name : String
      property freed : Bool
      property is_object : Bool
      property is_struct : Bool
      property field_count : Int32

      def initialize(@base_addr, @size_bytes, @context_name, @freed = false, @is_object = false, @is_struct = false, @field_count = 0)
      end
    end
  end
end
