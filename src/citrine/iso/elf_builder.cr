require "../mips/mips_emitter"
require "./elf_writer"
require "./pad_runtime_payload"
require "./phase_extractor"
require "./rodata_segment_builder"
require "./text_segment_builder"
require "./runtime_subroutines"

module Citrine
  alias VirtualInput = Citrine::ISO::VirtualInput

  # Constructs standard ELF executables bootable on PlayStation 2 (Emotion Engine R5900).
  # Complies with ELF32 MIPS little-endian specification.
  #
  # Architecture:
  # - PhaseExtractor: Decoupled CBC bytecode simulator extracting draw commands and profile
  # - RodataSegmentBuilder: Generates GS packets, input schedules, and string tables at 0x00500000
  # - TextSegmentBuilder: Generates MIPS machine code startup, frame loop, and input polling
  # - RuntimeSubroutines: Standard PS2 hardware and SPU2 leaf subroutines and native stubs
  # - ElfWriter: Packages segments, ELF headers, and program headers
  class ElfBuilder
    alias MipsEmitter = Citrine::MIPS::MipsEmitter
    alias Phase = Citrine::GS::Phase
    alias VirtualInput = Citrine::ISO::VirtualInput
    include Citrine::MIPS
    include Citrine::ISO

    alias SymbolEntry = ElfWriter::SymbolDef
    STT_FUNC   = ElfWriter::STT_FUNC
    STB_GLOBAL = ElfWriter::STB_GLOBAL
    STT_OBJECT = ElfWriter::STT_OBJECT

    RODATA_VADDR = 0x00500000_u32

    getter is_controller_tester : Bool = false
    getter is_dvd_screensaver : Bool = false
    getter is_audio_player : Bool = false
    getter has_audio : Bool = false
    getter has_button_checks : Bool = false
    getter is_inline_assembly : Bool = false
    getter inline_asm_words : Array(UInt32) = [] of UInt32

    def self.build_default_runner_elf(
      cbc_bytes : Bytes? = nil,
      input_schedule : Array(VirtualInput) = [] of VirtualInput,
      vag_bytes : Bytes? = nil
    ) : Bytes
      builder = new
      builder.generate(cbc_bytes, input_schedule, vag_bytes)
    end

    def generate(
      cbc_bytes : Bytes? = nil,
      input_schedule : Array(VirtualInput) = [] of VirtualInput,
      vag_bytes : Bytes? = nil
    ) : Bytes
      profile = PhaseExtractor.extract(cbc_bytes)

      @has_audio = profile.has_audio || (vag_bytes.try(&.empty?) == false)
      profile.has_audio = @has_audio
      @has_button_checks = profile.has_button_checks
      @is_inline_assembly = profile.is_inline_assembly
      @inline_asm_words = profile.inline_asm_words
      @is_controller_tester = profile.has_button_checks

      # 1. Build .rodata Segment
      rodata = RodataSegmentBuilder.build(profile, input_schedule)

      # 2. Build .text Segment
      text_data, emitter = TextSegmentBuilder.build(profile, rodata)

      # 3. Build .data Segment
      data_bytes = IO::Memory.new
      data_bytes.write_bytes(0x70000000_u32, IO::ByteFormat::LittleEndian) # g_spram_base
      data_bytes.write_bytes(0x00000000_u32, IO::ByteFormat::LittleEndian) # g_citrine_vm

      vag_slice = vag_bytes
      vag_transfer_size = 0
      if @has_audio && vag_slice && !vag_slice.empty?
        # Align to 16 bytes: offset 8 + 8 bytes padding = offset 16 (0x00200010)
        data_bytes.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
        data_bytes.write(vag_slice)
        pad = (16 - (vag_slice.size % 16)) % 16
        pad.times { data_bytes.write_byte(0_u8) }
        vag_transfer_size = vag_slice.size + pad
      end
      data_data = data_bytes.to_slice

      # 4. Symbol Table Layout
      stub_names = RuntimeSubroutines::STUB_NAMES
      symbols = [
        SymbolEntry.new("_start", emitter.labels["_start"], (emitter.labels["main"] - emitter.labels["_start"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", emitter.labels["main"], (emitter.labels["dma02_wait"] - emitter.labels["main"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma02_wait", emitter.labels["dma02_wait"], (emitter.labels["dma_reset"] - emitter.labels["dma02_wait"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("dma_reset", emitter.labels["dma_reset"], (emitter.labels["debug_puts"] - emitter.labels["dma_reset"]), STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("debug_puts", emitter.labels["debug_puts"], (emitter.labels[stub_names.first] - emitter.labels["debug_puts"]), STT_FUNC, STB_GLOBAL, 1_u16),
      ]

      stub_names.each_with_index do |sname, i|
        next_addr = (i + 1 < stub_names.size) ? emitter.labels[stub_names[i + 1]] : (0x00100000_u32 + (emitter.words.size.to_u32 * 4))
        stub_len = next_addr - emitter.labels[sname]
        symbols << SymbolEntry.new(sname, emitter.labels[sname], stub_len, STT_FUNC, STB_GLOBAL, 1_u16)
      end

      symbols << SymbolEntry.new("citrine_pad_init", PadRuntimePayload::INIT_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("citrine_pad_poll", PadRuntimePayload::POLL_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("citrine_sound_play", PadRuntimePayload::SOUND_PLAY_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("citrine_sound_stop", PadRuntimePayload::SOUND_STOP_ENTRY, 8_u32, STT_FUNC, STB_GLOBAL, 3_u16)
      symbols << SymbolEntry.new("g_spram_base", 0x70000000_u32, 16384_u32, STT_OBJECT, STB_GLOBAL, 5_u16)
      symbols << SymbolEntry.new("g_citrine_vm", 0x00200004_u32, 512_u32, STT_OBJECT, STB_GLOBAL, 4_u16)

      if @has_audio && vag_slice && !vag_slice.empty?
        symbols << SymbolEntry.new("g_audio_theme_vag", 0x00200010_u32, vag_transfer_size.to_u32, STT_OBJECT, STB_GLOBAL, 4_u16)
      end

      if !@inline_asm_words.empty? && emitter.labels.has_key?("Citrine_InlineAsm_Block")
        symbols << SymbolEntry.new("Citrine_InlineAsm_Block", emitter.labels["Citrine_InlineAsm_Block"], (@inline_asm_words.size.to_u32 * 4) + 8, STT_FUNC, STB_GLOBAL, 1_u16)
      end

      ElfWriter.write(text_data, rodata.data, data_data, symbols, 0x00100000_u32, rodata_vaddr: RODATA_VADDR)
    end

    def build_headless_elf(boot_messages : Array(String) = [] of String) : Bytes
      emitter = MipsEmitter.new
      emitter.lui(SP, 0x01FF)
      emitter.ori(SP, SP, 0xFFF0)
      emitter.lui(T0, 0x1000)
      emitter.ori(T0, T0, 0xF180) # EE TTY data register

      emitter.label("headless_loop")
      emitter.jump("headless_loop")

      text_slice = emitter.to_slice
      symbols = [
        SymbolEntry.new("_start", 0x00100000_u32, 16_u32, STT_FUNC, STB_GLOBAL, 1_u16),
        SymbolEntry.new("main", 0x00100000_u32, text_slice.size.to_u32, STT_FUNC, STB_GLOBAL, 1_u16)
      ]
      ElfWriter.write(text_slice, Bytes.empty, Bytes.empty, symbols, 0x00100000_u32, nil, rodata_vaddr: RODATA_VADDR)
    end

    # Backward-compatible delegate to PhaseExtractor
    def parse_cbc(cbc_bytes : Bytes?) : Tuple(Array(Phase), Array(String), Int32, Bool)
      profile = PhaseExtractor.extract(cbc_bytes)
      @has_audio = profile.has_audio
      @has_button_checks = profile.has_button_checks
      @is_inline_assembly = profile.is_inline_assembly
      @inline_asm_words = profile.inline_asm_words
      @is_controller_tester = profile.has_button_checks
      {profile.phases, profile.boot_messages, profile.loop_start_phase, profile.is_animated}
    end
  end
end
