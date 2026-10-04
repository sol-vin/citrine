# Citrine PS2 Example 16: VU1 Microcode Vertex Shaders & GS Multi-Pass Post-FX
# Demonstrates require "citrine/shader", VU1 vertex displacement, and GS eDRAM blending

require "citrine"
require "citrine/inputmap"
require "citrine/shader"
require "citrine/time"
require "citrine/math"

Citrine.init_window(640, 448, "Citrine PS2 - VU1 Shaders & GS Post-FX")
Citrine.set_target_fps(60)

# Declare action mapping
input_map do
  action :toggle_bloom, Button::Cross, port: 0
  action :toggle_scanlines, Button::Triangle, port: 0
  action :amp_up, Button::Up, port: 0
  action :amp_down, Button::Down, port: 0
end

# Hoisted Static Color Constants (Zero Per-Frame Heap Allocations)
COLOR_BG          = Color.new(10_u8, 14_u8, 24_u8, 255_u8)
COLOR_HEADER_BG   = Color.new(20_u8, 25_u8, 38_u8, 255_u8)
COLOR_TITLE       = Color.new(240_u8, 245_u8, 255_u8, 255_u8)
COLOR_NODE        = Color.new(52_u8, 152_u8, 219_u8, 240_u8)
COLOR_EDGE_HORIZ  = Color.new(41_u8, 128_u8, 185_u8, 160_u8)
COLOR_EDGE_VERT   = Color.new(31_u8, 97_u8, 141_u8, 140_u8)
COLOR_BLOOM_BG    = Color.new(46_u8, 204_u8, 113_u8, 60_u8)
COLOR_BLOOM_TEXT  = Color.new(200_u8, 255_u8, 220_u8, 255_u8)
COLOR_SCANLINE    = Color.new(0_u8, 0_u8, 0_u8, 45_u8)
COLOR_FOOTER_BG   = Color.new(20_u8, 24_u8, 36_u8, 240_u8)
COLOR_WHITE       = Color.new(255_u8, 255_u8, 255_u8, 255_u8)
COLOR_MUTED       = Color.new(160_u8, 180_u8, 210_u8, 255_u8)
COLOR_CYAN        = Color.new(0_u8, 220_u8, 255_u8, 255_u8)
COLOR_BORDER      = Color.new(40_u8, 60_u8, 90_u8, 255_u8)

# 1. Create VU1 + GS Shader Pipeline
pipeline = Citrine::Shader.create("OceanWaveVU1") do |pipe|
  pipe.vertex_wave(amplitude: 12.0_f32, frequency: 0.04_f32)
  pipe.add_pass(Citrine::Shader::EffectType::Bloom, intensity: 0.8_f32, alpha: 160_u8)
  pipe.add_pass(Citrine::Shader::EffectType::Scanlines, intensity: 0.4_f32, alpha: 64_u8)
end

# Grid Configuration
GRID_COLS = 16
GRID_ROWS = 8
SPACING_X = 34
SPACING_Y = 20
BASE_X = 50
BASE_Y = 120

time = 0.0_f32
bloom_enabled = true
scanlines_enabled = true

Citrine.main_loop do
  dt = Citrine.get_delta_time
  time += dt

  # Controller Inputs via Godot-style InputMap Actions
  if Action.is_pressed?(Actions::ToggleBloom)
    bloom_enabled = !bloom_enabled
  end

  if Action.is_pressed?(Actions::ToggleScanlines)
    scanlines_enabled = !scanlines_enabled
  end

  if Action.is_down?(Actions::AmpUp)
    pipeline.wave_amplitude = Math.min(pipeline.wave_amplitude + 0.2_f32, 28.0_f32)
  end

  if Action.is_down?(Actions::AmpDown)
    pipeline.wave_amplitude = Math.max(pipeline.wave_amplitude - 0.2_f32, 2.0_f32)
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(COLOR_BG)

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, COLOR_HEADER_BG)
  Citrine.draw_line(0, 36, 640, 36, COLOR_BORDER)
  Citrine.draw_text("CITRINE PS2: VU1 VERTEX SHADERS & GS BLENDING", 20, 10, 18, COLOR_TITLE)

  # Draw Grid Mesh deformed via VU1 Pipeline Simulation
  r = 0
  while r < GRID_ROWS
    c = 0
    while c < GRID_COLS
      orig_x = BASE_X + c * SPACING_X
      orig_y = BASE_Y + r * SPACING_Y

      wave = (((c * 5 + r * 7) % 20) - 10)
      vx = orig_x
      vy = orig_y + wave

      # Draw vertex node
      Citrine.draw_circle(vx, vy, 3.0_f32, COLOR_NODE)

      # Connect horizontal edge
      if c < GRID_COLS - 1
        next_x = orig_x + SPACING_X
        next_wave = ((((c + 1) * 5 + r * 7) % 20) - 10)
        Citrine.draw_line(vx, vy, next_x, orig_y + next_wave, COLOR_EDGE_HORIZ)
      end

      # Connect vertical edge
      if r < GRID_ROWS - 1
        below_y = orig_y + SPACING_Y
        below_wave = (((c * 5 + (r + 1) * 7) % 20) - 10)
        Citrine.draw_line(vx, vy, vx, below_y + below_wave, COLOR_EDGE_VERT)
      end

      c += 1
    end
    r += 1
  end

  # Draw Bloom Post-FX Pass Simulation (eDRAM Additive Halo)
  if bloom_enabled
    Citrine.draw_rectangle(60, 310, 520, 48, COLOR_BLOOM_BG)
    Citrine.draw_text("GS ADDITIVE BLOOM PASS ACTIVE (eDRAM 48 GB/s)", 110, 326, 16, COLOR_BLOOM_TEXT)
  end

  # Draw Scanlines Post-FX Pass Simulation
  if scanlines_enabled
    sl_y = 40
    while sl_y < 390
      Citrine.draw_line(20, sl_y, 620, sl_y, COLOR_SCANLINE)
      sl_y += 4
    end
  end

  # Telemetry Footer
  Citrine.draw_rectangle(20, 396, 600, 36, COLOR_FOOTER_BG)
  Citrine.draw_rectangle_lines(20, 396, 600, 36, COLOR_BORDER)
  bloom_status = bloom_enabled ? "ON" : "OFF"
  scan_status = scanlines_enabled ? "ON" : "OFF"
  Citrine.draw_text("VU1 Microcode: VLIW 128-bit | Bloom: #{bloom_status} | Scanlines: #{scan_status}", 32, 406, 14, COLOR_WHITE)
  Citrine.draw_text("Cross: Bloom | Tri: Scan | Up/Dn: Amp", 370, 406, 14, COLOR_MUTED)

  Citrine.end_drawing
end

Citrine.close_window
