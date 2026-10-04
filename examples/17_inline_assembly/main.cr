require "citrine"
require "citrine/inputmap"

# 17 Inline Assembly - Citrine PS2
# Direct Emotion Engine MIPS R5900, COP0 Cycle Counter, VU0 SIMD & CD-DA Audio Showcase
# Demonstrates:
# - asm(...) expression DSL for reading hardware cycle counters
# - Citrine.asm heredoc for Vector Unit 0 (VU0) Macro Mode SIMD co-processing
# - Memory synchronization (sync.l, sync.p) and 128-bit quadword operations
# - Hardware CD-DA optical audio track streaming & SPU2 volume control
# - High-precision sub-microsecond performance telemetry HUD

input_map do
  action :trigger_vu0, Button::Cross, port: 0
  action :toggle_audio, Button::Circle, port: 0
  action :force_sync, Button::Square, port: 0
  action :reset_bench, Button::Triangle, port: 0
end

struct AssemblyTelemetry
  property total_benchmarks : Int32
  property last_cycles : Int32
  property min_cycles : Int32
  property max_cycles : Int32
  property vu0_ops_executed : Int32
  property cdda_track : Int32
  property cdda_playing : Bool
  property volume : Int32
  property sync_count : Int32

  def initialize
    @total_benchmarks = 0
    @last_cycles = 0
    @min_cycles = 999999
    @max_cycles = 0
    @vu0_ops_executed = 0
    @cdda_track = 2
    @cdda_playing = true
    @volume = 128
    @sync_count = 0
  end

  def record_cycles(cycles : Int32)
    @last_cycles = cycles
    @total_benchmarks += 1
    @min_cycles = cycles if cycles < @min_cycles
    @max_cycles = cycles if cycles > @max_cycles
  end

  def add_vu0_burst(count : Int32)
    @vu0_ops_executed += count
  end

  def toggle_audio
    if @cdda_playing
      Citrine::Audio.stop_cdda
      @cdda_playing = false
    else
      @cdda_track = (@cdda_track % 5) + 1
      Citrine::Audio.play_cdda_track(@cdda_track)
      @cdda_playing = true
    end
  end

  def record_sync
    @sync_count += 1
  end

  def reset
    @total_benchmarks = 0
    @last_cycles = 0
    @min_cycles = 999999
    @max_cycles = 0
    @vu0_ops_executed = 0
    @sync_count = 0
  end
end

Citrine.init_window(640, 448, "17 Inline Assembly - Citrine PS2")
Citrine.set_target_fps(60)

# Start background CD-DA optical audio streaming on track 2
Citrine::Audio.play_cdda_track(2)
Citrine::Audio.set_volume(128)

telemetry = AssemblyTelemetry.new

Citrine.main_loop do
  pad = Citrine.player(0)

  # Check interactive controls
  if Action.is_pressed?(Actions::TriggerVu0) || pad.button_pressed?(Button::Cross)
    # Execute VU0 Macro SIMD vector burst via heredoc inline assembly
    Citrine.asm <<-ASM
      vadd.xyzw vf1, vf2, vf3
      vmul.xyzw vf4, vf5, vf6
      vmula.xyzw vf1, vf4
      vmadd.xyzw vf7, vf2, vf5
      vmax.xyzw vf8, vf3, vf6
      vmin.xyzw vf9, vf1, vf7
      sync.p
    ASM
    telemetry.add_vu0_burst(6)
  end

  if Action.is_pressed?(Actions::ToggleAudio) || pad.button_pressed?(Button::Circle)
    telemetry.toggle_audio
  end

  if Action.is_pressed?(Actions::ForceSync) || pad.button_pressed?(Button::Square)
    # Memory pipeline barrier
    Citrine.asm "sync.l"
    telemetry.record_sync
  end

  if Action.is_pressed?(Actions::ResetBench) || pad.button_pressed?(Button::Triangle)
    telemetry.reset
  end

  # Benchmark Emotion Engine Silicon via COP0 Count Register ($9)
  # Reads cycle counter before and after vectorized memory block
  t_start = asm("mfc0 $v0, $9")

  Citrine.asm <<-ASM
    sync.l
    nop
    vadd.xyzw vf1, vf2, vf3
    vmul.xyzw vf4, vf5, vf6
    sync.p
  ASM

  t_end = asm("mfc0 $v0, $9")
  elapsed = t_end - t_start
  elapsed = 120 if elapsed <= 0 # Guard against counter wrap
  telemetry.record_cycles(elapsed)

  # Render Telemetry HUD
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12, 16, 24, 255))

  # Header panel
  Citrine.draw_rectangle(16, 12, 608, 48, Color.new(20, 28, 44, 255))
  Citrine.draw_rectangle(16, 60, 608, 2, Color.new(0, 168, 255, 255))
  Citrine.draw_text("CITRINE PS2: INLINE ASSEMBLY & HARDWARE COP0/COP2", 28, 22, 16, Color::White)
  Citrine.draw_text("Direct MIPS R5900 Machine Silicon Execution & CD-DA Streaming", 28, 40, 12, Color.new(0, 168, 255, 255))

  # Header live activity & frame processing spinner
  Citrine.draw_rectangle(480, 18, 136, 36, Color.new(14, 20, 32, 255))
  Citrine.draw_rectangle(480, 18, 136, 1, Color.new(35, 50, 75, 255))
  Citrine.draw_circle(492, 36, 4, Color::Green)
  Citrine.draw_text("60 FPS", 504, 24, 10, Color::Green)
  Citrine.draw_text("ONLINE", 504, 38, 8, Color.new(0, 220, 255, 255))
  Citrine.draw_circle(588, 36, 15, Color.new(35, 50, 75, 255))
  Citrine.draw_circle(588, 36, 13, Color.new(12, 16, 24, 255))
  Citrine.draw_line(578, 36, 598, 36, Color.new(0, 255, 255, 255))
  Citrine.draw_line(588, 26, 588, 46, Color.new(0, 255, 0, 255))
  Citrine.draw_circle(588, 36, 2, Color::White)

  # Left Card: Profiling & Cycles Telemetry
  Citrine.draw_rectangle(16, 72, 296, 260, Color.new(18, 24, 38, 255))
  Citrine.draw_rectangle(16, 72, 296, 24, Color.new(26, 36, 56, 255))
  Citrine.draw_text("COP0 CYCLE COUNTER (147.456 MHz)", 26, 78, 12, Color.new(0, 220, 255, 255))

  Citrine.draw_text("Last Execution Cycles:", 26, 110, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.last_cycles} cycles", 200, 110, 14, Color::Green)

  Citrine.draw_text("Fastest Burst (Min):", 26, 140, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.min_cycles} cycles", 200, 140, 14, Color::Yellow)

  Citrine.draw_text("Slowest Burst (Max):", 26, 170, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.max_cycles} cycles", 200, 170, 14, Color::Orange)

  Citrine.draw_text("Total Samples:", 26, 200, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.total_benchmarks}", 200, 200, 14, Color::White)

  Citrine.draw_text("Pipeline Barriers (sync.l):", 26, 230, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.sync_count}", 200, 230, 14, Color::Purple)

  # Microsecond latency visualization bar
  Citrine.draw_rectangle(26, 270, 276, 16, Color.new(30, 40, 60, 255))
  bar_width = (telemetry.last_cycles % 276).to_i
  Citrine.draw_rectangle(26, 270, bar_width, 16, Color.new(0, 168, 255, 255))
  Citrine.draw_text("Latency: #{(telemetry.last_cycles / 147.456).to_i} us", 26, 294, 12, Color::LightGray)

  # Right Card: VU0 Vector Unit & SPU2 CD-DA Audio
  Citrine.draw_rectangle(328, 72, 296, 260, Color.new(18, 24, 38, 255))
  Citrine.draw_rectangle(328, 72, 296, 24, Color.new(26, 36, 56, 255))
  Citrine.draw_text("VU0 MACRO SIMD & OPTICAL CD-DA AUDIO", 338, 78, 12, Color.new(0, 220, 255, 255))

  Citrine.draw_text("VU0 SIMD Operations:", 338, 110, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.vu0_ops_executed}", 520, 110, 14, Color::Green)

  Citrine.draw_text("Active Vector Regs:", 338, 140, 14, Color::LightGray)
  Citrine.draw_text("vf1..vf9 (128-bit)", 490, 140, 14, Color::Yellow)

  Citrine.draw_text("CD-DA Optical Track:", 338, 170, 14, Color::LightGray)
  Citrine.draw_text("Track #{telemetry.cdda_track}", 520, 170, 14, Color::White)

  Citrine.draw_text("SPU2 Playback Status:", 338, 200, 14, Color::LightGray)
  status_str = telemetry.cdda_playing ? "STREAMING" : "STOPPED"
  status_col = telemetry.cdda_playing ? Color::Green : Color::Red
  Citrine.draw_text(status_str, 510, 200, 14, status_col)

  Citrine.draw_text("Master Audio Volume:", 338, 230, 14, Color::LightGray)
  Citrine.draw_text("#{telemetry.volume} / 255", 520, 230, 14, Color::White)

  # Audio waveform indicator
  Citrine.draw_rectangle(338, 270, 276, 16, Color.new(30, 40, 60, 255))
  audio_bar = telemetry.cdda_playing ? 180 : 0
  Citrine.draw_rectangle(338, 270, audio_bar, 16, Color.new(46, 204, 113, 255))
  Citrine.draw_text("DMA Channel 4: CDVD -> SPU2 Direct Stream", 338, 294, 12, Color::LightGray)

  # Bottom Controls Panel
  Citrine.draw_rectangle(16, 344, 608, 88, Color.new(20, 28, 44, 255))
  Citrine.draw_rectangle(16, 344, 608, 2, Color.new(60, 80, 110, 255))
  Citrine.draw_text("DUALSHOCK 2 CONTROLLER INTERFACE:", 28, 354, 12, Color.new(0, 168, 255, 255))
  Citrine.draw_text("[CROSS]    Execute VU0 SIMD Macro Burst (vf1..vf9 parallel math)", 28, 374, 12, Color::White)
  Citrine.draw_text("[CIRCLE]   Cycle / Toggle CD-DA Audio Track", 28, 392, 12, Color::White)
  Citrine.draw_text("[SQUARE]   Trigger sync.l memory barrier   [TRIANGLE] Reset Benchmarks", 28, 410, 12, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
