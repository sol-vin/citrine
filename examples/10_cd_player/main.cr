require "citrine"

# 10 CD Player: Night Tempo - Moonrise CD-DA Album Player
# Demonstrates Red Book CD-DA multi-track optical playback on PlayStation 2.
# All 13 tracks from "Moonrise" (Track 02..14 on mixed-mode disc).
#
# CONTROLS:
#   Cross       - Play / Pause (preserves playback position)
#   Circle      - Stop (resets playback position to 0:00)
#   Square      - Toggle Loop mode (ON/OFF)
#   R2 (held)   - Fast Forward (4x scrub)
#   L2 (held)   - Rewind (4x scrub)
#   R1          - Jump forward 10 seconds (+10s)
#   L1          - Jump back 10 seconds (-10s)
#   DPAD Right  - Next Track
#   DPAD Left   - Previous Track
#   DPAD Up     - Volume +
#   DPAD Down   - Volume -

# Code-first Disc Asset Baking DSL
Citrine.bake_stream_album "album/", bitrate: 96.kbps
Citrine.bake_texture "album/cover.png", "cover.cbt", 128, 128, 8

# Code-first album metadata loading (Album Agnostic)
TRACK_TITLES = Citrine.album_track_titles
TRACK_DURATIONS = Citrine.album_track_durations
ALBUM_TITLE = Citrine.album_title
ALBUM_ARTIST = Citrine.album_artist
TOTAL_TRACKS = Citrine.album_track_count
ALBUM_HEADER = "#{ALBUM_ARTIST.upcase} - #{ALBUM_TITLE.upcase}"

Citrine.init_window(640, 448, "#{ALBUM_ARTIST} - #{ALBUM_TITLE} (Citrine PS2 Stream Player)")
Citrine.set_target_fps(60)

# Load album cover texture (128x128 GS CLUT8)
cover_tex = Citrine.load_texture("cover.cbt")

track_idx = 0
is_playing = true
is_looping = true
elapsed_sec = 0.0_f32
master_vol = 240
frame_pulse = 0
status_mode = 0 # 0=PLAYING, 1=PAUSED, 2=STOPPED, 3=FAST FORWARD, 4=REWIND

# Start playing Track 0 (Stream Track 0)
Citrine.play_stream(track_idx)
Citrine.set_volume(master_vol)

Citrine.main_loop do
  pad = Citrine.player(0)
  frame_pulse = (frame_pulse + 1) % 60

  # Track duration from data array
  dur = TRACK_DURATIONS[track_idx]

  # 1. Transport: Play / Pause (Cross)
  if pad.button_pressed?(Button::Cross)
    if is_playing
      # True Pause: preserves elapsed position, silences output
      is_playing = false
      Citrine.stop_stream
      status_mode = 1 # PAUSED
    else
      # Resume playback from current position
      is_playing = true
      Citrine.play_stream(track_idx)
      status_mode = 0 # PLAYING
    end
  end

  # 2. Transport: Stop (Circle)
  if pad.button_pressed?(Button::Circle)
    is_playing = false
    elapsed_sec = 0.0_f32
    Citrine.stop_stream
    status_mode = 2 # STOPPED
  end

  # 3. Transport: Toggle Loop (Square)
  if pad.button_pressed?(Button::Square)
    is_looping = !is_looping
  end

  # 4. Seeking: Fast Forward (R2 held) / Rewind (L2 held)
  if pad.button_down?(Button::R2)
    # Scrub forward at 4x speed
    elapsed_sec += (4.0_f32 / 60.0_f32)
    if elapsed_sec > dur
      elapsed_sec = dur
    end
    status_mode = 3 # FAST FORWARD
  elsif pad.button_down?(Button::L2)
    # Scrub backward at 4x speed
    elapsed_sec -= (4.0_f32 / 60.0_f32)
    if elapsed_sec < 0.0_f32
      elapsed_sec = 0.0_f32
    end
    status_mode = 4 # REWIND
  elsif is_playing
    status_mode = 0 # Normal PLAYING
  end

  # 5. Jump: +10s (R1) / -10s (L1)
  if pad.button_pressed?(Button::R1)
    elapsed_sec += 10.0_f32
    if elapsed_sec > dur
      elapsed_sec = dur
    end
  elsif pad.button_pressed?(Button::L1)
    elapsed_sec -= 10.0_f32
    if elapsed_sec < 0.0_f32
      elapsed_sec = 0.0_f32
    end
  end

  # 6. Track Selection: Next (DPAD Right) / Previous (DPAD Left)
  if pad.button_pressed?(Button::Right)
    track_idx = (track_idx + 1) % TOTAL_TRACKS
    elapsed_sec = 0.0_f32
    if is_playing
      Citrine.play_stream(track_idx)
    end
  elsif pad.button_pressed?(Button::Left)
    track_idx = (track_idx + TOTAL_TRACKS - 1) % TOTAL_TRACKS
    elapsed_sec = 0.0_f32
    if is_playing
      Citrine.play_stream(track_idx)
    end
  end
  dur = TRACK_DURATIONS[track_idx]

  # 7. Volume: Up (DPAD Up) / Down (DPAD Down)
  if pad.button_pressed?(Button::Up)
    master_vol += 16
    if master_vol > 255
      master_vol = 255
    end
    Citrine.set_volume(master_vol)
  elsif pad.button_pressed?(Button::Down)
    master_vol -= 16
    if master_vol < 0
      master_vol = 0
    end
    Citrine.set_volume(master_vol)
  end

  # Advance playback timer at 60 FPS
  if is_playing && !pad.button_down?(Button::R2) && !pad.button_down?(Button::L2)
    elapsed_sec += (1.0_f32 / 60.0_f32)
    if elapsed_sec >= dur
      if is_looping
        # Auto-advance to next track
        track_idx = (track_idx + 1) % TOTAL_TRACKS
        elapsed_sec = 0.0_f32
        Citrine.play_stream(track_idx)
      else
        is_playing = false
        elapsed_sec = dur
        status_mode = 2 # STOPPED
        Citrine.stop_stream
      end
    end
  end

  # Current Track Metadata Descriptors from data arrays
  track_title = TRACK_TITLES[track_idx]

  # Dynamic optical track string
  opt_num = track_idx + 1
  opt_str = opt_num < 10 ? "Track 0#{opt_num}: TRACK0#{opt_num}.CAS (96 kbps SPU2 Stream)" : "Track #{opt_num}: TRACK#{opt_num}.CAS (96 kbps SPU2 Stream)"

  # Duration formatting
  dur_i = dur.to_i
  dur_m = dur_i // 60
  dur_s = dur_i % 60
  dur_sec_str = dur_s < 10 ? "0#{dur_s}" : "#{dur_s}"
  dur_min_str = dur_m < 10 ? "0#{dur_m}" : "#{dur_m}"
  dur_str = "#{dur_min_str}:#{dur_sec_str}"

  status_str = case status_mode
               when 0 then "PLAYING"
               when 1 then "PAUSED"
               when 2 then "STOPPED"
               when 3 then "FAST FORWARD >>"
               when 4 then "REWIND <<"
               else "STANDBY"
               end

  status_col = case status_mode
               when 0 then Color::Green
               when 1 then Color::Yellow
               when 2 then Color::Red
               when 3 then Color::Cyan
               when 4 then Color::Orange
               else Color::White
               end

  # Time formatting
  el_i = elapsed_sec.to_i
  el_m = el_i // 60
  el_s = el_i % 60
  time_sec_str = el_s < 10 ? "0#{el_s}" : "#{el_s}"
  time_min_str = el_m < 10 ? "0#{el_m}" : "#{el_m}"
  time_str = "TIME: #{time_min_str}:#{time_sec_str} / #{dur_str}"

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12_u8, 14_u8, 22_u8, 255_u8))

  # Header Bar
  Citrine.draw_rectangle(0, 0, 640, 36, Color::Blue)
  Citrine.draw_text("CITRINE PS2: OPTICAL AUDIO STREAM PLAYER", 40, 8, 18, Color::White)

  # Dynamic CD Optical Indicator
  Citrine.draw_circle(590, 18, 10, Color.new(24_u8, 28_u8, 48_u8, 255_u8))
  Citrine.draw_circle(590, 18, 4, Color::Yellow)
  Citrine.draw_line(578, 18, 602, 18, Color::Cyan)
  Citrine.draw_line(590, 6, 590, 30, Color::Cyan)

  # Album Cover Card (128x128)
  Citrine.draw_rectangle(62, 52, 134, 134, Color::DarkGray)
  Citrine.draw_rectangle(64, 54, 130, 130, Color::Black)
  Citrine.draw_circle(129, 119, 56, Color.new(30_u8, 32_u8, 44_u8, 255_u8))
  Citrine.draw_circle(129, 119, 42, Color.new(42_u8, 46_u8, 60_u8, 255_u8))
  Citrine.draw_circle(129, 119, 24, Color::Yellow)
  Citrine.draw_circle(129, 119, 7, Color::Black)
  Citrine.draw_text("CAS", 120, 115, 9, Color::Black)
  Citrine.draw_texture(cover_tex, 65, 55)

  # Track Info Card
  Citrine.draw_rectangle(206, 52, 372, 134, Color::DarkGray)
  Citrine.draw_rectangle(208, 54, 368, 130, Color.new(20_u8, 24_u8, 36_u8, 255_u8))

  Citrine.draw_text(ALBUM_HEADER, 220, 62, 13, Color::Yellow)
  Citrine.draw_text(track_title, 220, 84, 12, Color::White)
  Citrine.draw_text(opt_str, 220, 106, 11, Color::LightGray)
  Citrine.draw_text(status_str, 220, 128, 13, status_col)
  Citrine.draw_text(time_str, 220, 150, 12, Color::Cyan)

  # Timeline Scrubber Bar
  Citrine.draw_rectangle(62, 204, 516, 10, Color::DarkGray)
  scrub_w = (dur > 0.0_f32) ? ((elapsed_sec / dur) * 516.0_f32).to_i : 0
  scrub_w = scrub_w.clamp(0, 516)
  Citrine.draw_rectangle(62, 204, scrub_w, 10, Color::Cyan)
  Citrine.draw_rectangle(62 + scrub_w - 3, 200, 6, 18, Color::White)

  # Volume Bar Meter
  Citrine.draw_text("VOL:", 62, 226, 11, Color::LightGray)
  Citrine.draw_rectangle(100, 228, 120, 8, Color::DarkGray)
  vol_w = (master_vol * 120) // 255
  Citrine.draw_rectangle(100, 228, vol_w, 8, Color::Yellow)

  # Spectrum Equalizer (Visual profile per track)
  eq_x = 62
  while eq_x < 578
    eq_active = is_playing || status_mode == 3 || status_mode == 4
    eq_h = eq_active ? (12 + ((eq_x * 11 + track_idx * 17) % 40)) : 6
    eq_col = eq_active ? Color::Green : Color::DarkGray
    Citrine.draw_rectangle(eq_x, 345 - eq_h, 14, eq_h, eq_col)
    eq_x += 18
  end

  # Footer Controls & Status Card
  Citrine.draw_rectangle(40, 360, 560, 72, Color::DarkGray)
  loop_str = is_looping ? "ON" : "OFF"
  Citrine.draw_text("CROSS: Play/Pause - CIRCLE: Stop - SQUARE: Loop (#{loop_str})", 55, 370, 11, Color::Yellow)
  Citrine.draw_text("DPAD L/R: Prev/Next Track - R1/L1: +/-10s Jump - R2/L2: Fast Fwd/Rewind", 55, 388, 11, Color::Cyan)
  Citrine.draw_text("DPAD U/D: Volume (#{master_vol}/255) - #{TOTAL_TRACKS} Streamed CAS Tracks on Disc", 55, 406, 11, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
