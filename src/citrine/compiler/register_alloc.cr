module Citrine
  class RegisterAllocator
    MAX_SPRAM_REGISTERS = 1024
    WARN_FRAME_REGISTERS = 128

    getter local_map : Hash(String, UInt8)
    getter max_registers : UInt8
    getter next_reg : Int32
    getter free_temps : Array(UInt8)

    def initialize(initial_args : Array(String) = [] of String)
      @local_map = {} of String => UInt8
      @next_reg = 0
      @max_registers = 0_u8
      @free_temps = [] of UInt8

      initial_args.each do |arg|
        allocate_local(arg)
      end
    end

    def allocate_local(name : String) : UInt8
      if reg = @local_map[name]?
        return reg
      end

      reg = alloc_raw
      @local_map[name] = reg
      reg
    end

    def get_local(name : String) : UInt8?
      @local_map[name]?
    end

    def alloc_temp : UInt8
      if @free_temps.size > 0
        @free_temps.pop
      else
        alloc_raw
      end
    end

    def free_temp(reg : UInt8)
      # Do not free if it's a declared local variable
      unless @local_map.values.includes?(reg)
        @free_temps << reg unless @free_temps.includes?(reg)
      end
    end

    private def alloc_raw : UInt8
      if @next_reg >= 250
        raise "Register Limit Exceeded: function exceeded 250 registers in frame"
      end

      reg = @next_reg.to_u8
      @next_reg += 1
      if @next_reg > @max_registers
        @max_registers = @next_reg.to_u8
      end

      reg
    end
  end
end
