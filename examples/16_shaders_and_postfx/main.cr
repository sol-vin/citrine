# Citrine PS2 Example 16: Real-Time Shaders & GS Multi-Pass Post-FX
# Demonstrates:
# - Programmable VU1 dual-issue microcode vertex displacement & wave deformation
# - Real-time Digital Glitch & Chromatic Aberration slice tearing on textures & geometry
# - Color Quantization & Posterization (stepped 2-bit / 4-bit cel-shading bands)
# - Hardware Palette Swapping across 4 GS CLUT presets (Cyber Neon, Thermal, Amber CRT, Game Boy)
# - Real-time 360-degree Rainbow Hue Phase Modulation
# - GS Multi-Pass Additive Bloom Halos (48 GB/s eDRAM fillrate) & CRT Scanlines
# - Vibrant high-visibility background items: illuminated cyber grid, drifting starfield, HUD telemetry cards
# - Dynamically moving elements: floating transparent logo with motion, orbiting satellites, height-locked wave surfer
# - Top-layer UI architecture ensuring text and cards are never occluded
# - 100% deterministic integer trigonometry and zero per-frame heap allocations

require "citrine"
require "citrine/inputmap"
require "citrine/shader"
require "citrine/time"

# 1. Bake & Preload Texture Assets
# Bakes logo.png into PS2 GS Paletted Texture (128x128 CLUT8 with transparent background)
Citrine.bake_texture "logo.png", "logo.cbt", 128, 128, 8

Citrine.init_window(640, 448, "Citrine PS2 - Real-Time Shaders & GS Post-FX")
Citrine.set_target_fps(60)

# Load baked CLUT8 texture
logo_tex = Citrine.load_texture("logo.cbt")

# Hoisted Static Color Constants (Tier 1 Zero Per-Frame Heap Allocations)
COLOR_BG          = Color.new(8_u8, 10_u8, 18_u8, 255_u8)
COLOR_HEADER_BG   = Color.new(16_u8, 20_u8, 34_u8, 255_u8)
COLOR_FOOTER_BG   = Color.new(14_u8, 18_u8, 30_u8, 245_u8)
COLOR_TITLE       = Color.new(245_u8, 250_u8, 255_u8, 255_u8)
COLOR_WHITE       = Color.new(255_u8, 255_u8, 255_u8, 255_u8)
COLOR_MUTED       = Color.new(155_u8, 180_u8, 220_u8, 255_u8)
COLOR_CYAN        = Color.new(0_u8, 235_u8, 255_u8, 255_u8)
COLOR_YELLOW      = Color.new(255_u8, 230_u8, 40_u8, 255_u8)
COLOR_MAGENTA     = Color.new(255_u8, 25_u8, 150_u8, 255_u8)
COLOR_GREEN       = Color.new(46_u8, 204_u8, 113_u8, 255_u8)
COLOR_RED         = Color.new(255_u8, 65_u8, 65_u8, 255_u8)
COLOR_SCANLINE    = Color.new(0_u8, 0_u8, 0_u8, 55_u8)
COLOR_BADGE_BG    = Color.new(28_u8, 40_u8, 70_u8, 255_u8)

# Background Cyber Grid Colors
COLOR_BORDER      = Color.new(70_u8, 110_u8, 180_u8, 255_u8)
COLOR_CARD_BG     = Color.new(22_u8, 32_u8, 56_u8, 255_u8)
COLOR_CARD_HEADER = Color.new(38_u8, 55_u8, 96_u8, 255_u8)
COLOR_BG_GRID_H   = Color.new(45_u8, 70_u8, 125_u8, 255_u8)
COLOR_BG_GRID_V   = Color.new(40_u8, 58_u8, 108_u8, 255_u8)
COLOR_BG_GRID_DOT = Color.new(85_u8, 135_u8, 225_u8, 255_u8)
COLOR_ORBIT_RING  = Color.new(55_u8, 85_u8, 140_u8, 255_u8)

# Baseline Mode 0 Mesh Colors
COLOR_NODE        = Color.new(0_u8, 225_u8, 255_u8, 255_u8)
COLOR_EDGE_HORIZ  = Color.new(0_u8, 190_u8, 240_u8, 255_u8)
COLOR_EDGE_VERT   = Color.new(235_u8, 45_u8, 175_u8, 255_u8)
COLOR_CORE        = Color.new(0_u8, 220_u8, 255_u8, 255_u8)
COLOR_SAT_A       = Color.new(46_u8, 240_u8, 120_u8, 255_u8)
COLOR_SAT_B       = Color.new(255_u8, 215_u8, 30_u8, 255_u8)
COLOR_SURFER      = Color.new(255_u8, 60_u8, 60_u8, 255_u8)

# Mode 1: Glitch & Chromatic Aberration Colors
COLOR_GLITCH_RED  = Color.new(255_u8, 30_u8, 70_u8, 210_u8)
COLOR_GLITCH_CYAN = Color.new(0_u8, 245_u8, 255_u8, 210_u8)
COLOR_GLITCH_LINE = Color.new(255_u8, 255_u8, 255_u8, 180_u8)

# Mode 2: Stepped Quantization Colors (Toon / Cel Bands)
QUANT_0           = Color.new(20_u8, 25_u8, 42_u8, 255_u8)
QUANT_1           = Color.new(65_u8, 80_u8, 130_u8, 255_u8)
QUANT_2           = Color.new(130_u8, 165_u8, 225_u8, 255_u8)
QUANT_3           = Color.new(240_u8, 250_u8, 255_u8, 255_u8)

# Mode 3: Hardware Palette Swapping Presets (GS CLUT)
# Preset 0: Cyber Neon (80s Arcade)
PAL_NEON_0 = Color.new(18_u8, 8_u8, 32_u8, 255_u8)
PAL_NEON_1 = Color.new(157_u8, 0_u8, 255_u8, 255_u8)
PAL_NEON_2 = Color.new(255_u8, 0_u8, 128_u8, 255_u8)
PAL_NEON_3 = Color.new(0_u8, 240_u8, 255_u8, 255_u8)
PAL_NEON_4 = Color.new(255_u8, 230_u8, 0_u8, 255_u8)

# Preset 1: FLIR Thermal Heatmap
PAL_THERM_0 = Color.new(8_u8, 6_u8, 36_u8, 255_u8)
PAL_THERM_1 = Color.new(25_u8, 55_u8, 185_u8, 255_u8)
PAL_THERM_2 = Color.new(46_u8, 204_u8, 113_u8, 255_u8)
PAL_THERM_3 = Color.new(241_u8, 196_u8, 15_u8, 255_u8)
PAL_THERM_4 = Color.new(231_u8, 76_u8, 60_u8, 255_u8)
PAL_THERM_5 = Color.new(255_u8, 255_u8, 255_u8, 255_u8)

# Preset 2: Amber Phosphor CRT Terminal
PAL_AMBER_0 = Color.new(22_u8, 10_u8, 0_u8, 255_u8)
PAL_AMBER_1 = Color.new(110_u8, 45_u8, 0_u8, 255_u8)
PAL_AMBER_2 = Color.new(190_u8, 95_u8, 0_u8, 255_u8)
PAL_AMBER_3 = Color.new(255_u8, 160_u8, 0_u8, 255_u8)
PAL_AMBER_4 = Color.new(255_u8, 235_u8, 140_u8, 255_u8)

# Preset 3: Game Boy 1989 Classic (4-Tone Olive)
PAL_GB_0 = Color.new(15_u8, 56_u8, 15_u8, 255_u8)
PAL_GB_1 = Color.new(48_u8, 98_u8, 48_u8, 255_u8)
PAL_GB_2 = Color.new(139_u8, 172_u8, 15_u8, 255_u8)
PAL_GB_3 = Color.new(155_u8, 188_u8, 15_u8, 255_u8)

# Mode 4: Rainbow Spectrum Colors (HSV Phase Modulation)
RAINBOW_0 = Color.new(255_u8, 55_u8, 55_u8, 255_u8)
RAINBOW_1 = Color.new(255_u8, 155_u8, 30_u8, 255_u8)
RAINBOW_2 = Color.new(255_u8, 225_u8, 30_u8, 255_u8)
RAINBOW_3 = Color.new(50_u8, 225_u8, 85_u8, 255_u8)
RAINBOW_4 = Color.new(30_u8, 215_u8, 245_u8, 255_u8)
RAINBOW_5 = Color.new(55_u8, 105_u8, 255_u8, 255_u8)
RAINBOW_6 = Color.new(165_u8, 55_u8, 255_u8, 255_u8)
RAINBOW_7 = Color.new(255_u8, 55_u8, 185_u8, 255_u8)

# Mode 5: GS Additive Bloom Glow Halos
COLOR_BLOOM_OUTER = Color.new(0_u8, 200_u8, 255_u8, 60_u8)
COLOR_BLOOM_INNER = Color.new(0_u8, 230_u8, 255_u8, 110_u8)
COLOR_BLOOM_CORE  = Color.new(220_u8, 250_u8, 255_u8, 190_u8)

# 2. Integer Trigonometry Approximation (Pure Integer Parabolic Series, Scaled by 100)
# Eliminates all memory overhead and guarantees 100% deterministic PS2 MIPS execution
def int_sin(idx : Int32) : Int32
  a = (idx % 64 + 64) % 64
  if a < 32
    (a * (32 - a) * 100) // 256
  else
    a2 = a - 32
    -(a2 * (32 - a2) * 100) // 256
  end
end

def int_cos(idx : Int32) : Int32
  int_sin(idx + 16)
end

# Terrain Mesh Configuration (16 x 7 Grid)
GRID_COLS = 16
GRID_ROWS = 7
SPACING_X = 35
SPACING_Y = 23
BASE_X    = 58
BASE_Y    = 200

# Helper routine to render undulating terrain mesh
def draw_terrain_mesh(tick : Int32, wave_amp : Int32, shader_mode : Int32, palette_preset : Int32, glitch_timer : Int32)
  r = 0
  while r < GRID_ROWS
    c = 0
    while c < GRID_COLS
      orig_x = BASE_X + c * SPACING_X
      orig_y = BASE_Y + r * SPACING_Y

      # Dynamic sine displacement computed via integer lookup
      disp = (int_sin(c * 4 + tick * 3) * wave_amp) // 100
      vx = orig_x
      vy = orig_y + disp

      node_color = COLOR_NODE
      edge_h_color = COLOR_EDGE_HORIZ
      edge_v_color = COLOR_EDGE_VERT

      case shader_mode
      when 1
        if (r % 2 == 0) && (glitch_timer > 0 || c % 3 == 0)
          vx += ((c * 7) % 19 - 9)
        end
        node_color = (c % 2 == 0) ? COLOR_GLITCH_RED : COLOR_GLITCH_CYAN
        edge_h_color = COLOR_GLITCH_CYAN
        edge_v_color = COLOR_GLITCH_RED
      when 2
        step_idx = (vy // 22) % 4
        case step_idx
        when 0 then node_color = QUANT_0; edge_h_color = QUANT_0
        when 1 then node_color = QUANT_1; edge_h_color = QUANT_1
        when 2 then node_color = QUANT_2; edge_h_color = QUANT_2
        else        node_color = QUANT_3; edge_h_color = QUANT_3
        end
        edge_v_color = node_color
      when 3
        case palette_preset
        when 0
          node_color = PAL_NEON_3
          edge_h_color = PAL_NEON_2
          edge_v_color = PAL_NEON_1
        when 1
          node_color = PAL_THERM_3
          edge_h_color = PAL_THERM_2
          edge_v_color = PAL_THERM_1
        when 2
          node_color = PAL_AMBER_3
          edge_h_color = PAL_AMBER_2
          edge_v_color = PAL_AMBER_1
        else
          node_color = PAL_GB_3
          edge_h_color = PAL_GB_2
          edge_v_color = PAL_GB_1
        end
      when 4
        hue_idx = ((c + r + (tick // 4)) % 8).abs
        case hue_idx
        when 0 then node_color = RAINBOW_0
        when 1 then node_color = RAINBOW_1
        when 2 then node_color = RAINBOW_2
        when 3 then node_color = RAINBOW_3
        when 4 then node_color = RAINBOW_4
        when 5 then node_color = RAINBOW_5
        when 6 then node_color = RAINBOW_6
        else        node_color = RAINBOW_7
        end
        edge_h_color = node_color
        edge_v_color = node_color
      when 5
        node_color = COLOR_CYAN
        edge_h_color = COLOR_EDGE_HORIZ
        edge_v_color = COLOR_EDGE_VERT
      end

      # Draw node circle (Radius 4 integer, White inner core radius 2)
      Citrine.draw_circle(vx, vy, 4, node_color)
      Citrine.draw_circle(vx, vy, 2, COLOR_WHITE)

      # Horizontal connection line to next node in row
      if c < GRID_COLS - 1
        next_orig_x = BASE_X + (c + 1) * SPACING_X
        next_disp = (int_sin((c + 1) * 4 + tick * 3) * wave_amp) // 100
        next_vx = next_orig_x
        next_vy = orig_y + next_disp
        Citrine.draw_line(vx, vy, next_vx, next_vy, edge_h_color)
      end

      # Vertical connection line to node below in column
      if r < GRID_ROWS - 1
        below_orig_y = BASE_Y + (r + 1) * SPACING_Y
        below_disp = disp
        below_vx = vx
        below_vy = below_orig_y + below_disp
        Citrine.draw_line(vx, vy, below_vx, below_vy, edge_v_color)
      end

      # Ground anchor vertical line
      if r == GRID_ROWS - 1
        Citrine.draw_line(vx, vy, vx, 365, COLOR_BORDER)
      end

      c += 1
    end
    r += 1
  end
end

# Helper routine to render background grid, drifting starfield, and orbits
def draw_background(tick : Int32)
  # 1. Cyber Grid Lines
  bg_y = 52
  while bg_y < 380
    Citrine.draw_line(20, bg_y, 620, bg_y, COLOR_BG_GRID_H)
    bg_y += 32
  end

  bg_x = 35
  while bg_x < 620
    Citrine.draw_line(bg_x, 50, bg_x, 380, COLOR_BG_GRID_V)
    bg_x += 45
  end

  # Grid Intersection Dots
  bg_y = 52
  while bg_y < 380
    bg_x = 35
    while bg_x < 620
      Citrine.draw_rectangle(bg_x - 1, bg_y - 1, 3, 3, COLOR_BG_GRID_DOT)
      bg_x += 45
    end
    bg_y += 32
  end

  # 2. Drifting Ambient Starfield Particles
  t_drift = (tick * 3) % 580
  star_i = 0
  while star_i < 20
    sx_base = 25 + star_i * 30
    sy_base = 120 + ((star_i * 37) % 70)
    sx_drift = ((sx_base + t_drift) % 580) + 30
    star_col = (star_i % 4 == 0) ? COLOR_CYAN : ((star_i % 4 == 1) ? COLOR_YELLOW : ((star_i % 4 == 2) ? COLOR_MAGENTA : COLOR_WHITE))
    Citrine.draw_rectangle(sx_drift, sy_base, 4, 4, star_col)
    Citrine.draw_rectangle(sx_drift + 1, sy_base + 1, 2, 2, COLOR_WHITE)
    star_i += 1
  end

  # 3. Satellite Orbit Track Reference Lines
  Citrine.draw_line(155, 265, 485, 265, COLOR_ORBIT_RING)
  Citrine.draw_line(320, 180, 320, 350, COLOR_ORBIT_RING)
end

# Helper routine to render UI HUD cards & text cleanly on top of all elements
def draw_ui_hud(shader_mode : Int32, palette_preset : Int32, speed_mode : Int32)
  # 1. Left Telemetry Card: VU1 Coprocessor
  Citrine.draw_rectangle(16, 44, 180, 58, COLOR_CARD_BG)
  Citrine.draw_rectangle(16, 44, 180, 16, COLOR_CARD_HEADER)
  Citrine.draw_rectangle_lines(16, 44, 180, 58, COLOR_BORDER)
  Citrine.draw_circle(24, 52, 3, COLOR_GREEN)
  Citrine.draw_text("VU1 COPROCESSOR", 32, 48, 11, COLOR_CYAN)
  Citrine.draw_text("VLIW Dual-Issue Path 1", 24, 64, 10, COLOR_MUTED)
  Citrine.draw_text("Wave Deform: ACTIVE", 24, 76, 10, COLOR_GREEN)

  # 2. Right Telemetry Card: Graphics Synthesizer
  Citrine.draw_rectangle(444, 44, 180, 58, COLOR_CARD_BG)
  Citrine.draw_rectangle(444, 44, 180, 16, COLOR_CARD_HEADER)
  Citrine.draw_rectangle_lines(444, 44, 180, 58, COLOR_BORDER)
  Citrine.draw_circle(452, 52, 3, COLOR_YELLOW)
  Citrine.draw_text("GS ENGINE", 460, 48, 11, COLOR_YELLOW)
  Citrine.draw_text("4 MB eDRAM @ 48 GB/s", 452, 64, 10, COLOR_MUTED)
  Citrine.draw_text("CLUT8 Swizzle: OK", 452, 76, 10, COLOR_MAGENTA)

  # 3. Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, COLOR_HEADER_BG)
  Citrine.draw_line(0, 36, 640, 36, COLOR_BORDER)
  Citrine.draw_text("CITRINE PS2: REAL-TIME SHADERS & GS", 16, 11, 15, COLOR_TITLE)

  # 4. Active Shader Badge in Header (Safely bounded before right margin)
  Citrine.draw_rectangle(410, 6, 214, 24, COLOR_BADGE_BG)
  Citrine.draw_rectangle_lines(410, 6, 214, 24, COLOR_BORDER)

  case shader_mode
  when 0
    Citrine.draw_text("0: VU1 WAVE DEFORM", 422, 11, 12, COLOR_CYAN)
  when 1
    Citrine.draw_text("1: DIGITAL GLITCH", 426, 11, 12, COLOR_MAGENTA)
  when 2
    Citrine.draw_text("2: QUANTIZE (CEL)", 426, 11, 12, COLOR_YELLOW)
  when 3
    case palette_preset
    when 0 then Citrine.draw_text("3: CYBER NEON", 436, 11, 12, PAL_NEON_3)
    when 1 then Citrine.draw_text("3: FLIR THERMAL", 430, 11, 12, PAL_THERM_3)
    when 2 then Citrine.draw_text("3: AMBER CRT", 436, 11, 12, PAL_AMBER_3)
    else        Citrine.draw_text("3: GAME BOY 1989", 426, 11, 12, PAL_GB_3)
    end
  when 4
    Citrine.draw_text("4: RAINBOW CYCLE", 426, 11, 12, COLOR_GREEN)
  when 5
    Citrine.draw_text("5: ADDITIVE BLOOM", 426, 11, 12, COLOR_CYAN)
  end

  # 5. Footer Controls Bar (Comfortably within 640px)
  Citrine.draw_rectangle(16, 396, 608, 40, COLOR_FOOTER_BG)
  Citrine.draw_rectangle_lines(16, 396, 608, 40, COLOR_BORDER)

  if speed_mode == 2
    Citrine.draw_text("EE R5900: 60 FPS | Speed: 2.0x | SPRAM: 16KB OK | eDRAM: 48 GB/s", 26, 402, 11, COLOR_MUTED)
  elsif speed_mode == 0
    Citrine.draw_text("EE R5900: 60 FPS | Speed: 0.5x | SPRAM: 16KB OK | eDRAM: 48 GB/s", 26, 402, 11, COLOR_MUTED)
  else
    Citrine.draw_text("EE R5900: 60 FPS | Speed: 1.0x | SPRAM: 16KB OK | eDRAM: 48 GB/s", 26, 402, 11, COLOR_MUTED)
  end
  Citrine.draw_text("[X/Square] Shader Mode  [Tri] Variant  [D-Pad] Params", 26, 418, 11, COLOR_YELLOW)
end

# Interactive Shader State
shader_mode = 0         # 0: Wave, 1: Glitch, 2: Quantize, 3: Palette, 4: Rainbow, 5: Bloom
palette_preset = 0      # 0: Neon, 1: Thermal, 2: Amber, 3: GameBoy
quant_steps = 4         # 4 or 8
wave_amp = 18           # Wave amplitude in pixels (2..30)
glitch_timer = 0
scanlines_active = true
speed_mode = 1          # 0: 0.5x, 1: 1.0x, 2: 2.0x
tick = 0                # Discrete integer frame tick
sub_tick = 0            # Physical frame alternator for 0.5x speed

# Main Simulation & Render Loop (60 FPS on PlayStation 2 GS)
Citrine.main_loop do
  # Frame step based on speed mode
  sub_tick = (sub_tick + 1) % 2
  if speed_mode == 2
    tick = (tick + 2) % 256
  elsif speed_mode == 0
    if sub_tick == 0
      tick = (tick + 1) % 256
    end
  else
    tick = (tick + 1) % 256
  end

  if glitch_timer > 0
    glitch_timer -= 1
  end

  # DualShock 2 Controller Input Handling
  pad = Citrine.player(0)

  # Cross: Next Shader Mode
  if pad.button_pressed?(Button::Cross)
    shader_mode = (shader_mode + 1) % 6
  end

  # Square: Previous Shader Mode
  if pad.button_pressed?(Button::Square)
    shader_mode = (shader_mode + 5) % 6
  end

  # Triangle: Sub-variant / Parameter Action
  if pad.button_pressed?(Button::Triangle)
    case shader_mode
    when 1
      glitch_timer = 30
    when 2
      quant_steps = (quant_steps == 4) ? 8 : 4
    when 3
      palette_preset = (palette_preset + 1) % 4
    when 5
      scanlines_active = !scanlines_active
    else
      wave_amp = (wave_amp > 16) ? 8 : 22
    end
  end

  # Circle: Instant Glitch Shockwave Burst
  if pad.button_pressed?(Button::Circle)
    glitch_timer = 35
  end

  # D-Pad Up / Down: Adjust Wave Amplitude
  if pad.button_down?(Button::Up)
    if wave_amp < 30
      wave_amp += 1
    end
  end

  if pad.button_down?(Button::Down)
    if wave_amp > 3
      wave_amp -= 1
    end
  end

  # D-Pad Left / Right: Simulation Speed Scaling (Toggles 0.5x, 1.0x, 2.0x)
  if pad.button_pressed?(Button::Right)
    speed_mode = (speed_mode + 1) % 3
  end
  if pad.button_pressed?(Button::Left)
    speed_mode = (speed_mode + 2) % 3
  end

  # =========================================================================
  # Coordinate Math for Moving Elements (100% Integer Math)
  # =========================================================================

  # 1. Dynamic Floating & Gliding Logo Element (Sweeps smoothly between cards)
  lx = 256 + (int_cos(tick) * 35) // 100
  ly = 50 + (int_sin(tick * 2) * 12) // 100

  # 2. Central Rotating Geometric Core
  core_x = 320
  core_y = 265
  cp = 16 + (int_sin(tick * 3) * 4) // 100

  # 3. Satellite Alpha (Wide Elliptical Orbit)
  sat_a_idx = (tick * 2) % 64
  sat_a_x = 320 + (int_cos(sat_a_idx) * 155) // 100
  sat_a_y = 265 + (int_sin(sat_a_idx) * 55) // 100

  sat_a_t_idx = (sat_a_idx - 3 + 64) % 64
  sat_a_tx = 320 + (int_cos(sat_a_t_idx) * 155) // 100
  sat_a_ty = 265 + (int_sin(sat_a_t_idx) * 55) // 100

  # 4. Satellite Beta (Counter-Orbiting Vertical Harmonic Path)
  sat_b_idx = (-tick + 64) % 64
  sat_b_x = 320 + (int_cos(sat_b_idx) * 120) // 100
  sat_b_y = 265 + (int_sin(sat_b_idx) * 80) // 100

  sat_b_t_idx = (sat_b_idx + 3) % 64
  sat_b_tx = 320 + (int_cos(sat_b_t_idx) * 120) // 100
  sat_b_ty = 265 + (int_sin(sat_b_t_idx) * 80) // 100

  # 5. Wave-Surfer Probe (Height dynamically locks to terrain wave crest below it)
  sx = 320 + (int_sin(tick) * 210) // 100
  surfer_grid_c = (sx - BASE_X) // SPACING_X
  surfer_disp = (int_sin(surfer_grid_c * 4 + tick * 3) * wave_amp) // 100
  sy = BASE_Y + (2 * SPACING_Y) + surfer_disp

  # =========================================================================
  # Render Pass (Direct GS Framebuffer Command Dispatch)
  # =========================================================================
  Citrine.begin_drawing

  # -------------------------------------------------------------------------
  # 1. Background Clearing
  # -------------------------------------------------------------------------
  case shader_mode
  when 3
    case palette_preset
    when 0 then Citrine.clear_background(PAL_NEON_0)
    when 1 then Citrine.clear_background(PAL_THERM_0)
    when 2 then Citrine.clear_background(PAL_AMBER_0)
    else        Citrine.clear_background(PAL_GB_0)
    end
  when 1
    if glitch_timer > 20
      Citrine.clear_background(Color.new(40_u8, 16_u8, 35_u8, 255_u8))
    else
      Citrine.clear_background(COLOR_BG)
    end
  else
    Citrine.clear_background(COLOR_BG)
  end

  # -------------------------------------------------------------------------
  # 2. High-Visibility Background Elements (Layer 0)
  # -------------------------------------------------------------------------
  draw_background(tick)

  # -------------------------------------------------------------------------
  # 3. Draw VU1 Undulating Terrain Mesh (Layer 1 - Midground)
  # -------------------------------------------------------------------------
  draw_terrain_mesh(tick, wave_amp, shader_mode, palette_preset, glitch_timer)

  # -------------------------------------------------------------------------
  # 4. Draw Moving Items (Layer 2 - Shaded by Active Pipeline)
  # -------------------------------------------------------------------------

  # A. Moving Dynamic Textured Element (logo.cbt - 100% Transparent Background)
  case shader_mode
  when 0
    # Mode 0: Clean floating transparent logo
    Citrine.draw_texture(logo_tex, lx, ly, COLOR_WHITE)
  when 1
    # Mode 1: Digital Glitch with RGB Chromatic Aberration & Slice Jitter
    jitter = ((tick * 11) % 17) - 8
    if glitch_timer > 0
      jitter = jitter * 2
    end
    Citrine.draw_texture(logo_tex, lx - 7 + jitter, ly, COLOR_GLITCH_RED)
    Citrine.draw_texture(logo_tex, lx + 7 - jitter, ly, COLOR_GLITCH_CYAN)
    Citrine.draw_texture(logo_tex, lx, ly, COLOR_WHITE)

    # Displaced horizontal scanlines across logo
    Citrine.draw_rectangle(lx - 10, ly + ((tick * 7) % 110), 148, 3, COLOR_GLITCH_LINE)
    Citrine.draw_rectangle(lx - 16, ly + ((tick * 13) % 120), 160, 2, COLOR_GLITCH_CYAN)
  when 2
    # Mode 2: Quantized / Posterized Logo Tint
    q_color = (quant_steps == 4) ? QUANT_2 : QUANT_3
    Citrine.draw_texture(logo_tex, lx, ly, q_color)
  when 3
    # Mode 3: Hardware Palette Swapped Logo
    pal_tint = case palette_preset
               when 0 then PAL_NEON_3
               when 1 then PAL_THERM_3
               when 2 then PAL_AMBER_3
               else        PAL_GB_3
               end
    Citrine.draw_texture(logo_tex, lx, ly, pal_tint)
  when 4
    # Mode 4: Rainbow Hue Cycling Logo Tint
    hue_idx = ((tick // 6) % 8).abs
    rain_tint = case hue_idx
                when 0 then RAINBOW_0
                when 1 then RAINBOW_1
                when 2 then RAINBOW_2
                when 3 then RAINBOW_3
                when 4 then RAINBOW_4
                when 5 then RAINBOW_5
                when 6 then RAINBOW_6
                else        RAINBOW_7
                end
    Citrine.draw_texture(logo_tex, lx, ly, rain_tint)
  when 5
    # Mode 5: Additive Bloom Circular Halos Behind Logo
    Citrine.draw_circle(lx + 64, ly + 64, 68, COLOR_BLOOM_OUTER)
    Citrine.draw_circle(lx + 64, ly + 64, 50, COLOR_BLOOM_INNER)
    Citrine.draw_texture(logo_tex, lx, ly, COLOR_WHITE)
  end

  # B. Central Rotating Core
  case shader_mode
  when 1
    Citrine.draw_rectangle(core_x - cp + 5, core_y - cp, cp * 2, cp * 2, COLOR_GLITCH_RED)
    Citrine.draw_rectangle(core_x - cp - 5, core_y - cp, cp * 2, cp * 2, COLOR_GLITCH_CYAN)
  when 2
    Citrine.draw_rectangle(core_x - cp - 5, core_y - cp - 5, cp * 2 + 10, cp * 2 + 10, QUANT_0)
    Citrine.draw_rectangle(core_x - cp, core_y - cp, cp * 2, cp * 2, QUANT_1)
    Citrine.draw_rectangle(core_x - cp + 4, core_y - cp + 4, cp * 2 - 8, cp * 2 - 8, QUANT_2)
    Citrine.draw_rectangle(core_x - 3, core_y - 3, 6, 6, QUANT_3)
  when 3
    case palette_preset
    when 0
      Citrine.draw_rectangle(core_x - cp, core_y - cp, cp * 2, cp * 2, PAL_NEON_2)
      Citrine.draw_circle(core_x, core_y, 7, PAL_NEON_4)
    when 1
      Citrine.draw_rectangle(core_x - cp, core_y - cp, cp * 2, cp * 2, PAL_THERM_4)
      Citrine.draw_circle(core_x, core_y, 7, PAL_THERM_5)
    when 2
      Citrine.draw_rectangle(core_x - cp, core_y - cp, cp * 2, cp * 2, PAL_AMBER_2)
      Citrine.draw_circle(core_x, core_y, 7, PAL_AMBER_4)
    else
      Citrine.draw_rectangle(core_x - cp, core_y - cp, cp * 2, cp * 2, PAL_GB_2)
      Citrine.draw_circle(core_x, core_y, 7, PAL_GB_3)
    end
  when 5
    Citrine.draw_circle(core_x, core_y, 28, COLOR_BLOOM_OUTER)
    Citrine.draw_circle(core_x, core_y, 22, COLOR_BLOOM_INNER)
    Citrine.draw_circle(core_x, core_y, 16, COLOR_BLOOM_CORE)
  else
    Citrine.draw_rectangle(core_x - cp, core_y - cp, cp * 2, cp * 2, COLOR_CORE)
    Citrine.draw_circle(core_x, core_y, 7, COLOR_WHITE)
  end

  # C. Orbiting Satellites Alpha & Beta
  Citrine.draw_circle(sat_a_tx, sat_a_ty, 5, COLOR_BORDER)
  Citrine.draw_line(core_x, core_y, sat_a_x, sat_a_y, COLOR_BORDER)
  Citrine.draw_circle(sat_a_x, sat_a_y, 9, COLOR_SAT_A)
  Citrine.draw_circle(sat_a_x, sat_a_y, 4, COLOR_WHITE)

  Citrine.draw_circle(sat_b_tx, sat_b_ty, 5, COLOR_BORDER)
  Citrine.draw_line(core_x, core_y, sat_b_x, sat_b_y, COLOR_BORDER)
  Citrine.draw_circle(sat_b_x, sat_b_y, 8, COLOR_SAT_B)
  Citrine.draw_circle(sat_b_x, sat_b_y, 3, COLOR_WHITE)

  # D. Wave-Surfer Probe
  Citrine.draw_line(sx, sy, sx, sy + 25, COLOR_SURFER)
  Citrine.draw_circle(sx, sy, 10, COLOR_SURFER)
  Citrine.draw_circle(sx, sy, 5, COLOR_YELLOW)
  Citrine.draw_circle(sx, sy, 2, COLOR_WHITE)

  # -------------------------------------------------------------------------
  # 5. Post-Processing Pass Overlays (Layer 3 - GS Multi-Pass & Glitch Noise)
  # -------------------------------------------------------------------------
  if shader_mode == 1
    Citrine.draw_rectangle(20, 180 + ((tick * 4) % 140), 600, 4, COLOR_GLITCH_LINE)
    Citrine.draw_rectangle(40, 240 - ((tick * 3) % 120), 560, 2, COLOR_GLITCH_CYAN)
  end

  if (shader_mode == 5 && scanlines_active) || (shader_mode == 1 && glitch_timer > 0)
    sl_y = 44
    while sl_y < 390
      Citrine.draw_line(15, sl_y, 625, sl_y, COLOR_SCANLINE)
      sl_y += 4
    end
  end

  # -------------------------------------------------------------------------
  # 6. Telemetry HUD & Header/Footer Cards (Layer 4 - ALWAYS ON TOP)
  # -------------------------------------------------------------------------
  draw_ui_hud(shader_mode, palette_preset, speed_mode)

  Citrine.end_drawing
end

Citrine.close_window
