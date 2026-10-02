module Citrine
  class BudgetReport
    property total_bytecode_bytes : Int32 = 0
    property total_functions : Int32 = 0
    property max_frame_registers : UInt8 = 0_u8
    property max_frame_func_name : String = ""
    property estimated_vram_bytes : Int32 = 0
    property concurrency_memory_bytes : Int32 = 0
    property max_fibers : Int32 = 64
    property max_channels : Int32 = 32
    property warnings : Array(String) = [] of String
    property errors : Array(String) = [] of String

    def passed? : Bool
      @errors.empty?
    end
  end

  class BudgetChecker
    MAX_VRAM_BYTES = 4 * 1024 * 1024       # 4 MB GS eDRAM
    FRAMEBUFFER_BYTES = 2 * 640 * 448 * 4  # ~2.3 MB (Double buffered 32-bit RGBA)
    ZBUFFER_BYTES = 640 * 448 * 4          # ~1.15 MB (32-bit Z-buffer)
    AVAILABLE_TEXTURE_VRAM = MAX_VRAM_BYTES - FRAMEBUFFER_BYTES - ZBUFFER_BYTES # ~550 KB

    def self.check(
      functions : Hash(String, UInt8),
      bytecode_size : Int32,
      texture_dimensions : Array(Tuple(Int32, Int32, Int32)) = [] of Tuple(Int32, Int32, Int32),
      max_fibers : Int32 = 64,
      max_channels : Int32 = 32,
      channel_capacity : Int32 = 32
    ) : BudgetReport
      report = BudgetReport.new
      report.total_bytecode_bytes = bytecode_size
      report.total_functions = functions.size
      report.max_fibers = max_fibers
      report.max_channels = max_channels

      # 1. SPRAM Frame Register Checks
      functions.each do |name, reg_count|
        if reg_count > report.max_frame_registers
          report.max_frame_registers = reg_count
          report.max_frame_func_name = name
        end

        if reg_count > RegisterAllocator::MAX_SPRAM_REGISTERS
          report.errors << "Function '#{name}' requires #{reg_count} registers, exceeding total PS2 SPRAM capacity (1024 registers)."
        elsif reg_count > RegisterAllocator::WARN_FRAME_REGISTERS
          report.warnings << "Function '#{name}' requires #{reg_count} registers (> 128 threshold). Deep recursion may risk SPRAM overflow."
        end
      end

      # 2. VRAM Budget Estimation
      # texture_dimensions: Array of (width, height, bytes_per_pixel)
      total_tex_vram = 0
      texture_dimensions.each do |(w, h, bpp)|
        total_tex_vram += w * h * bpp
      end
      report.estimated_vram_bytes = total_tex_vram

      if total_tex_vram > AVAILABLE_TEXTURE_VRAM
        report.warnings << "Estimated resident texture memory (#{total_tex_vram / 1024} KB) exceeds standard GS VRAM texture pool (#{AVAILABLE_TEXTURE_VRAM / 1024} KB). Textures will need dynamic streaming via DMA."
      end

      # 3. Concurrency Safety & Memory Footprint Checks
      fiber_struct_bytes = 1088 # 64 saved regs * 16 bytes + 64 bytes metadata/call_stack
      channel_struct_bytes = 32 + (channel_capacity * 16) # Header + Ring buffer
      concurrency_ram = (max_fibers * fiber_struct_bytes) + (max_channels * channel_struct_bytes)
      report.concurrency_memory_bytes = concurrency_ram

      if max_fibers > 256
        report.errors << "Configured max_fibers (#{max_fibers}) exceeds safe PS2 limit (256). Excessive fibers will cause scheduler thrashing."
      elsif max_fibers > 128
        report.warnings << "Configured max_fibers (#{max_fibers}) is high (> 128). Consider tuning fiber lifecycle for 60 FPS determinism."
      end

      if max_channels > 128
        report.errors << "Configured max_channels (#{max_channels}) exceeds safe PS2 limit (128)."
      end

      if max_fibers.to_i64 * report.max_frame_registers.to_i64 * 16 > (256 * 1024)
        report.warnings << "Worst-case fiber register footprint (#{max_fibers * report.max_frame_registers * 16 / 1024} KB) is high. Ensure fibers yield with minimal live temporary registers."
      end

      # 4. Bytecode Size Check
      if bytecode_size > 4 * 1024 * 1024
        report.warnings << "Bytecode size (#{bytecode_size / 1024} KB) exceeds 4 MB. Ensure PS2 32MB main RAM has enough space for game assets."
      end

      report
    end
  end
end
