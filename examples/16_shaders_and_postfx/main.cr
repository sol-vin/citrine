# Citrine PS2 Example 16: VU1 Microcode Vertex Shaders & GS Multi-Pass Post-FX
# Demonstrates require "citrine/shader", VU1 vertex displacement, and GS eDRAM blending

require "citrine"
require "citrine/shader"
require "citrine/time"
require "citrine/math"

Citrine.init_window(640, 448, "Citrine PS2 - VU1 Shaders & GS Post-FX")
Citrine.set_target_fps(60)

# 1. Create VU1 + GS Shader Pipeline
pipeline = Citrine::Shader.create("OceanWaveVU1") do |pipe|
  pipe.vertex_wave(amplitude: 12.0_f32, frequency: 0.04_f32)
  pipe.add_pass(Citrine::Shader::EffectType::Bloom, intensity: 0.8_f32, alpha: 160_u8)
  pipe.add_pass(Citrine::Shader::EffectType::Scanlines, intensity: 0.4_f32, alpha: 64_u8)
end

time = 0.0_f32
bloom_enabled = true
scanlines_enabled = true

Citrine.main_loop do
  dt = Citrine.get_delta_time
  time += dt

  # Controller Inputs
  if Citrine.button_pressed?(Button::Cross)
    bloom_enabled = !bloom_enabled
  end

  if Citrine.button_pressed?(Button::Triangle)
    scanlines_enabled = !scanlines_enabled
  end

  if Citrine.button_down?(Button::Up)
    pipeline.wave_amplitude = Math.min(pipeline.wave_amplitude + 0.2_f32, 28.0_f32)
  end

  if Citrine.button_down?(Button::Down)
    pipeline.wave_amplitude = Math.max(pipeline.wave_amplitude - 0.2_f32, 2.0_f32)
  end

  # Render Pass
  Citrine.begin_drawing
  Citrine.clear_background(Color.new(10_u8, 14_u8, 24_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color.new(20_u8, 25_u8, 38_u8, 255_u8))
  Citrine.draw_text("CITRINE PS2: VU1 VERTEX SHADERS & GS BLENDING", 20, 10, 18, Color.new(240_u8, 245_u8, 255_u8, 255_u8))

  # Draw Grid Mesh deformed via VU1 Pipeline Simulation
  grid_cols = 16
  grid_rows = 8
  spacing_x = 34.0_f32
  spacing_y = 20.0_f32
  base_x = 50.0_f32
  base_y = 120.0_f32

  r = 0
  while r < grid_rows
    c = 0
    while c < grid_cols
      orig_x = base_x + c.to_f32 * spacing_x
      orig_y = base_y + r.to_f32 * spacing_y

      v = pipeline.transform_vertex(orig_x, orig_y, 0.0_f32, time)
      vx = v[0].to_i32
      vy = v[1].to_i32

      # Draw vertex node
      node_col = Color.new(52_u8, 152_u8, 219_u8, 240_u8)
      Citrine.draw_circle(vx, vy, 3.0_f32, node_col)

      # Connect horizontal edge
      if c < grid_cols - 1
        next_v = pipeline.transform_vertex(base_x + (c + 1).to_f32 * spacing_x, orig_y, 0.0_f32, time)
        Citrine.draw_line(vx, vy, next_v[0].to_i32, next_v[1].to_i32, Color.new(41_u8, 128_u8, 185_u8, 160_u8))
      end

      # Connect vertical edge
      if r < grid_rows - 1
        below_v = pipeline.transform_vertex(orig_x, base_y + (r + 1).to_f32 * spacing_y, 0.0_f32, time)
        Citrine.draw_line(vx, vy, below_v[0].to_i32, below_v[1].to_i32, Color.new(31_u8, 97_u8, 141_u8, 140_u8))
      end

      c += 1
    end
    r += 1
  end

  # Draw Bloom Post-FX Pass Simulation (eDRAM Additive Halo)
  if bloom_enabled
    Citrine.draw_rectangle(60, 310, 520, 48, Color.new(46_u8, 204_u8, 113_u8, 60_u8))
    Citrine.draw_text("GS ADDITIVE BLOOM PASS ACTIVE (eDRAM 48 GB/s)", 110, 326, 16, Color.new(200_u8, 255_u8, 220_u8, 255_u8))
  end

  # Draw Scanlines Post-FX Pass Simulation
  if scanlines_enabled
    sl_y = 80
    while sl_y < 380
      Citrine.draw_line(40, sl_y, 600, sl_y, Color.new(0_u8, 0_u8, 0_u8, 45_u8))
      sl_y += 4
    end
  end

  # Telemetry Footer
  Citrine.draw_rectangle(20, 396, 600, 36, Color.new(20_u8, 24_u8, 36_u8, 240_u8))
  bloom_status = bloom_enabled ? "ON" : "OFF"
  scan_status = scanlines_enabled ? "ON" : "OFF"
  Citrine.draw_text("VU1 Microcode: VLIW 128-bit | Bloom: #{bloom_status} | Scanlines: #{scan_status}", 32, 406, 14, Color.new(255_u8, 255_u8, 255_u8, 255_u8))
  Citrine.draw_text("Cross: Bloom | Tri: Scan | Up/Dn: Amp", 370, 406, 14, Color.new(160_u8, 180_u8, 210_u8, 255_u8))

  Citrine.end_drawing
end

Citrine.close_window
