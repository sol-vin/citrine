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

    class SimulationState
      property regs : Array(Int64) = Array(Int64).new(1024, 0_i64)
      property reg_base : Int32 = 0
      property call_stack : Array(CallFrame) = [] of CallFrame
      property objects : Hash(Int64, Array(Int64)) = Hash(Int64, Array(Int64)).new
      property object_types : Hash(Int64, Array(UInt8)) = Hash(Int64, Array(UInt8)).new
      property next_obj_id : Int64 = 1_i64
      property arrays : Hash(Int64, Array(Int64)) = Hash(Int64, Array(Int64)).new
      property array_types : Hash(Int64, Array(UInt8)) = Hash(Int64, Array(UInt8)).new
      property next_arr_id : Int64 = 1000_i64
      property io_streams : Hash(Int64, IO::Memory) = Hash(Int64, IO::Memory).new
      property next_io_id : Int64 = 2000_i64
      property memory : Hash(Int64, Int64) = Hash(Int64, Int64).new
      property next_heap_addr : Int64 = 0x00200000_i64
      property object_classes : Hash(Int64, UInt32) = Hash(Int64, UInt32).new
      property active_context_name : String = ""
      property scratch_pool_base : Int64 = 0x00400000_i64
      property scratch_pool_ptr : Int64 = 0x00400000_i64
      property allocations : Hash(Int64, AllocationRecord) = Hash(Int64, AllocationRecord).new
      property free_list : Array(Tuple(Int64, Int32)) = [] of Tuple(Int64, Int32)
      property compiled_regexes : Hash(Int64, SimpleRegex) = Hash(Int64, SimpleRegex).new
      property next_regex_id : Int64 = 5000_i64
      property vec2_store : Hash(Int64, Tuple(Int64, Int64)) = Hash(Int64, Tuple(Int64, Int64)).new
      property next_vec2_id : Int64 = 10000_i64
      property loaded_textures : Hash(Int64, String) = Hash(Int64, String).new
      property channels : Hash(Int64, ChannelInstance) = Hash(Int64, ChannelInstance).new
      property next_chan_id : Int64 = 7000_i64
      property active_fibers : Array(FiberContext) = [] of FiberContext
      property is_float_reg : Array(Bool) = Array(Bool).new(1024, false)
      property reg_types : Array(UInt8) = Array(UInt8).new(1024, 2_u8)
      property active_camera : Tuple(Tuple(Float32, Float32, Float32), Tuple(Float32, Float32, Float32), Tuple(Float32, Float32, Float32))? = nil
      property rand_state : UInt64 = 0x517cc1b727220a95_u64
      property current_commands : Array(Citrine::GS::DrawCommand) = [] of Citrine::GS::DrawCommand
      property phases : Array(Citrine::GS::Phase) = [] of Citrine::GS::Phase
      property pc : Int32 = 0
      property max_steps : Int32 = 2_000_000
      property steps : Int32 = 0
      property first_frame_done : Bool = false
      property in_main_loop : Bool = false
      property current_loop_message : String? = nil
      property cycle_counter : UInt64 = 147_456_000_u64
      property simulated_button_press : Bool = false
      property button_phase_count : Int32 = 0
      property is_animated : Bool = false
      property has_dynamic_frame_text : Bool = false
      property animation_checked : Bool = false
      property prev_frame_cmds : Array(Citrine::GS::DrawCommand) = [] of Citrine::GS::DrawCommand
      property max_anim_frames : Int32 = 60
      property anim_frame_count : Int32 = 0
      property frames_per_bank : Int32 = 16
      property max_banks : Int32 = 3
      property simulated_btn_id : Int32 = 0
      property has_button_checks : Bool = false
      property has_audio : Bool = false
      property boot_messages : Array(String) = [] of String

      def initialize
        @memory[0x700000E0_i64] = 0x517cc1b7_i64
        @memory[0x70000034_i64] = 0x517cc1b7_i64
      end
    end
  end
end
