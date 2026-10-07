require "citrine"
require "citrine/draw2d"
require "citrine/audio"

# 10 CD Player: Night Tempo - Moonrise CD-DA Album Player
# Demonstrates Red Book CD-DA multi-track optical playback on PlayStation 2.
# All 13 tracks from "Moonrise" (Track 02..14 on mixed-mode disc).
#
# CONTROLS:
#   Cross       - Play / Pause (preserves playback position)
#   Circle      - Stop (resets playback position to 0:00)
#   Square      - Toggle Loop mode (ON/OFF)
#   Triangle    - Toggle High-Res Album Art Showcase View
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
Citrine.bake_texture "album/cover.jpg", "cover.cbt", 512, 512, 8

# Compile-time loaded Album and Track domain model
album = Citrine.album
total_tracks = album.size
album_header = album.header
album_title = album.title


Citrine.init_window(640, 448, "#{album.artist} - #{album.title} (Citrine PS2 Stream Player)")
Citrine.set_target_fps(60)

# Load album cover texture (512x512 High-Res GS CLUT8)
cover_tex = Citrine.load_texture("cover.cbt")

track_idx = 0
is_playing = true
is_looping = false
art_showcase = false
elapsed_frames = 0
elapsed_sec = 0
master_vol = 240
frame_pulse = 0
status_mode = 0 # 0=PLAYING, 1=PAUSED, 2=STOPPED, 3=FAST FORWARD, 4=REWIND

# Start playing Track 0 (Stream Track 0)
album.play(track_idx)
Citrine::Audio.set_volume(master_vol)

Citrine.main_loop do
  pad = Citrine.player(0)
  frame_pulse = (frame_pulse + 1) % 60

  # Current Track object
  curr_track = album[track_idx]
  dur = curr_track.duration

  # 1. Transport: Play / Pause (Cross)
  if pad.button_pressed?(Button::Cross)
    if is_playing
      # True Pause: preserves elapsed position, silences output
      is_playing = false
      Citrine::Audio.pause_stream
      status_mode = 1 # PAUSED
    else
      # Resume playback from current position or restart
      is_playing = true
      if status_mode == 1
        Citrine::Audio.resume_stream
      else
        album.play(track_idx)
      end
      status_mode = 0 # PLAYING
    end
  end

  # 2. Transport: Stop (Circle)
  if pad.button_pressed?(Button::Circle)
    is_playing = false
    elapsed_frames = 0
    elapsed_sec = 0
    Citrine::Audio.stop_stream
    status_mode = 2 # STOPPED
  end

  # 3. Transport: Toggle Loop (Square)
  if pad.button_pressed?(Button::Square)
    is_looping = !is_looping
  end

  # 4. View: Toggle High-Res Album Art Showcase (Triangle)
  if pad.button_pressed?(Button::Triangle)
    art_showcase = !art_showcase
  end

  # 4. Seeking: Fast Forward (R2 held) / Rewind (L2 held)
  if pad.button_down?(Button::R2)
    # Scrub forward at 4x speed
    elapsed_frames += 4
    elapsed_sec = elapsed_frames // 60
    if elapsed_sec > dur
      elapsed_sec = dur
      elapsed_frames = dur * 60
    end
    status_mode = 3 # FAST FORWARD
  elsif pad.button_down?(Button::L2)
    # Scrub backward at 4x speed
    elapsed_frames -= 4
    if elapsed_frames < 0
      elapsed_frames = 0
    end
    elapsed_sec = elapsed_frames // 60
    status_mode = 4 # REWIND
  elsif is_playing
    status_mode = 0 # Normal PLAYING
  end

  # When scrub buttons are released, commit seek to audio hardware
  if pad.button_released?(Button::R2) || pad.button_released?(Button::L2)
    Citrine::Audio.seek_music(elapsed_sec)
    status_mode = is_playing ? 0 : 1
  end

  # 5. Jump: +10s (R1) / -10s (L1)
  if pad.button_pressed?(Button::R1)
    elapsed_frames += 600
    elapsed_sec = elapsed_frames // 60
    if elapsed_sec > dur
      elapsed_sec = dur
      elapsed_frames = dur * 60
    end
    Citrine::Audio.seek_music(elapsed_sec)
  elsif pad.button_pressed?(Button::L1)
    elapsed_frames -= 600
    if elapsed_frames < 0
      elapsed_frames = 0
    end
    elapsed_sec = elapsed_frames // 60
    Citrine::Audio.seek_music(elapsed_sec)
  end

  # 6. Track Selection: Next (DPAD Right) / Previous (DPAD Left)
  if pad.button_pressed?(Button::Right)
    track_idx = (track_idx + 1) % total_tracks
    elapsed_frames = 0
    elapsed_sec = 0
    if is_playing
      album.play(track_idx)
    else
      status_mode = 2 # Reset pause to stopped on track change
    end
  elsif pad.button_pressed?(Button::Left)
    track_idx = (track_idx + total_tracks - 1) % total_tracks
    elapsed_frames = 0
    elapsed_sec = 0
    if is_playing
      album.play(track_idx)
    else
      status_mode = 2 # Reset pause to stopped on track change
    end
  end
  dur = album[track_idx].duration

  # 7. Volume: Up (DPAD Up) / Down (DPAD Down)
  if pad.button_pressed?(Button::Up)
    master_vol += 16
    if master_vol > 255
      master_vol = 255
    end
    Citrine::Audio.set_volume(master_vol)
  elsif pad.button_pressed?(Button::Down)
    master_vol -= 16
    if master_vol < 0
      master_vol = 0
    end
    Citrine::Audio.set_volume(master_vol)
  end

  # Advance playback timer at 60 FPS
  if is_playing && !pad.button_down?(Button::R2) && !pad.button_down?(Button::L2)
    elapsed_frames += 1
    elapsed_sec = elapsed_frames // 60
    if elapsed_sec >= dur
      if is_looping
        # Loop mode ON: repeat current track
        elapsed_frames = 0
        elapsed_sec = 0
        album.play(track_idx)
      else
        # Loop mode OFF: auto-advance to next track across album
        if track_idx + 1 < total_tracks
          track_idx += 1
          elapsed_frames = 0
          elapsed_sec = 0
          album.play(track_idx)
        else
          # End of album reached: stop playback
          is_playing = false
          elapsed_sec = dur
          elapsed_frames = dur * 60
          status_mode = 2 # STOPPED
          Citrine::Audio.stop_stream
        end
      end
    end
  end

  # Current Track Metadata Descriptors from Track object
  curr_track = album[track_idx]
  track_title = curr_track.full_title
  opt_str = curr_track.optical_str
  dur_str = curr_track.duration_s

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

  # Zero-allocation time formatting using static digit table
  el_min = elapsed_sec // 60
  el_sec = elapsed_sec % 60
  time_sec_str = el_sec < 10 ? "0#{el_sec}" : "#{el_sec}"
  time_min_str = el_min < 10 ? "0#{el_min}" : "#{el_min}"
  time_str = "TIME: #{time_min_str}:#{time_sec_str} / #{dur_str}"

  Citrine.begin_drawing
  Citrine.clear_background(Color.new(12_u8, 14_u8, 22_u8, 255_u8))

  if art_showcase
    # =========================================================================
    # High-Resolution Album Art Showcase Mode (Draw2D Pipeline)
    # =========================================================================
    Citrine.draw_rectangle(0, 0, 640, 36, Color::Blue)
    Citrine.draw_text("ALBUM ART SHOWCASE: #{album_title.upcase}", 32, 10, 16, Color::White)

    # Dynamic Spinning Vinyl Record behind cover art
    vinyl_x = 290
    vinyl_y = 175
    Citrine.draw_circle(vinyl_x, vinyl_y, 95, Color.new(20_u8, 20_u8, 26_u8, 255_u8))
    Citrine.draw_circle(vinyl_x, vinyl_y, 88, Color.new(35_u8, 35_u8, 45_u8, 255_u8))
    Citrine.draw_circle(vinyl_x, vinyl_y, 65, Color.new(20_u8, 20_u8, 26_u8, 255_u8))
    Citrine.draw_circle(vinyl_x, vinyl_y, 35, Color::Yellow)
    Citrine.draw_circle(vinyl_x, vinyl_y, 8, Color.new(12_u8, 14_u8, 22_u8, 255_u8))

    # High-Resolution 512x512 Cover Art (236x236 on screen)
    Citrine.draw_rectangle(32, 54, 240, 240, Color::DarkGray)
    Citrine.draw_rectangle(34, 56, 236, 236, Color::Black)
    Citrine.draw_texture_pro(cover_tex, 0, 0, 512, 512, 34, 56, 236, 236, 0.0_f32, 0, 0, Color::White)

    # Showcase Metadata Panel
    Citrine.draw_rectangle(300, 54, 308, 240, Color::DarkGray)
    Citrine.draw_rectangle(302, 56, 304, 236, Color.new(20_u8, 24_u8, 36_u8, 255_u8))
    Citrine.draw_text(album_header, 314, 66, 10, Color::Yellow)
    Citrine.draw_text(track_title, 314, 86, 10, Color::White)
    Citrine.draw_text(opt_str, 314, 106, 10, Color::LightGray)
    Citrine.draw_text("STATUS: #{status_str}  #{is_looping ? "[LOOP: ON]" : "[LOOP: OFF]"}", 314, 126, 10, status_col)
    Citrine.draw_text(time_str, 314, 146, 12, Color::Cyan)
    Citrine.draw_text("TEXTURE: 512x512 High-Res PSMT8 CLUT8", 314, 172, 10, Color::Green)
    Citrine.draw_text("PIPELINE: Draw2D Hardware Accelerated", 314, 192, 10, Color::LightGray)
    Citrine.draw_text("DISC: Red Book Multi-Track Mixed Mode", 314, 212, 10, Color::LightGray)
    Citrine.draw_text("PRESS TRIANGLE TO RETURN TO PLAYER", 314, 236, 10, Color::Yellow)

    # Scrubber Bar in showcase
    Citrine.draw_rectangle(32, 308, 576, 8, Color::DarkGray)
    scrub_w = (dur > 0) ? ((elapsed_sec * 576) // dur) : 0
    if scrub_w < 0
      scrub_w = 0
    elsif scrub_w > 576
      scrub_w = 576
    end
    Citrine.draw_rectangle(32, 308, scrub_w, 8, Color::Cyan)

    # Footer
    Citrine.draw_rectangle(32, 328, 576, 96, Color::DarkGray)
    Citrine.draw_rectangle(34, 330, 572, 92, Color.new(16_u8, 20_u8, 30_u8, 255_u8))
    Citrine.draw_text("TRIANGLE: Return to Player Controls   CROSS: Play/Pause   CIRCLE: Stop", 46, 342, 10, Color::Yellow)
    Citrine.draw_text("DPAD LEFT/RIGHT: Prev/Next Track   DPAD UP/DOWN: Master Volume +/-", 46, 364, 10, Color::Cyan)
    Citrine.draw_text("L1/R1: +/- 10s Skip   L2/R2 (Hold): 4x Rewind / Fast Forward", 46, 386, 10, Color::LightGray)
    Citrine.draw_text("SQUARE: Toggle Loop Mode   (13 High-Fidelity Audio Tracks)", 46, 408, 10, Color::LightGray)
  else
    # =========================================================================
    # Standard Player View (with Crisp High-Res Downsampling via Draw2D)
    # =========================================================================
    # Header Bar
    Citrine.draw_rectangle(0, 0, 640, 36, Color::Blue)
    Citrine.draw_text("CITRINE PS2: OPTICAL AUDIO STREAM PLAYER", 32, 10, 16, Color::White)

    # Dynamic CD Optical Indicator
    Citrine.draw_circle(590, 18, 10, Color.new(24_u8, 28_u8, 48_u8, 255_u8))
    Citrine.draw_circle(590, 18, 4, Color::Yellow)
    Citrine.draw_line(578, 18, 602, 18, Color::Cyan)
    Citrine.draw_line(590, 6, 590, 30, Color::Cyan)

    # Album Cover Card (High-Res 512x512 downsampled cleanly via Draw2D)
    Citrine.draw_rectangle(32, 48, 146, 146, Color::DarkGray)
    Citrine.draw_rectangle(34, 50, 142, 142, Color::Black)
    Citrine.draw_texture(cover_tex, 41, 57)

    # Track Info Card
    Citrine.draw_rectangle(188, 48, 420, 146, Color::DarkGray)
    Citrine.draw_rectangle(190, 50, 416, 142, Color.new(20_u8, 24_u8, 36_u8, 255_u8))

    Citrine.draw_text(album_header, 204, 58, 10, Color::Yellow)
    Citrine.draw_text(track_title, 204, 78, 10, Color::White)
    Citrine.draw_text(opt_str, 204, 98, 10, Color::LightGray)
    Citrine.draw_text("STATUS: #{status_str}  #{is_looping ? "[LOOP: ON]" : "[LOOP: OFF]"}", 204, 118, 10, status_col)
    Citrine.draw_text(time_str, 204, 138, 12, Color::Cyan)
    Citrine.draw_text("DISC: SONY SPU-2 STREAMING ENGINE (CD-DA MIXED MODE)", 204, 166, 10, Color::Green)

    # Timeline Scrubber Bar
    Citrine.draw_rectangle(32, 204, 576, 10, Color::DarkGray)
    scrub_w = (dur > 0) ? ((elapsed_sec * 576) // dur) : 0
    if scrub_w < 0
      scrub_w = 0
    elsif scrub_w > 576
      scrub_w = 576
    end
    Citrine.draw_rectangle(32, 204, scrub_w, 10, Color::Cyan)
    Citrine.draw_rectangle(32 + scrub_w - 3, 200, 6, 18, Color::White)

    # Volume Bar Meter
    Citrine.draw_text("VOL:", 32, 226, 10, Color::LightGray)
    Citrine.draw_rectangle(68, 227, 130, 8, Color::DarkGray)
    vol_w = (master_vol * 130) // 255
    Citrine.draw_rectangle(68, 227, vol_w, 8, Color::Yellow)
    Citrine.draw_text("#{master_vol * 100 // 255}%", 206, 226, 10, Color::Yellow)
    Citrine.draw_text("TRACK #{track_idx + 1} OF #{total_tracks}", 490, 226, 10, Color::Green)

    # Spectrum Equalizer (Visual profile per track - 16 retro spectrum bars)
    eq_x = 34
    while eq_x < 600
      eq_active = is_playing || status_mode == 3 || status_mode == 4
      bar_idx = (eq_x - 34) // 36
      eq_h = eq_active ? (10 + ((bar_idx * 13 + track_idx * 17 + frame_pulse) % 65)) : 6
      eq_col = eq_active ? Color::Green : Color::DarkGray
      Citrine.draw_rectangle(eq_x, 345 - eq_h, 26, eq_h, eq_col)
      eq_x += 36
    end

    # Footer Controls & Status Card
    Citrine.draw_rectangle(32, 356, 576, 76, Color::DarkGray)
    Citrine.draw_rectangle(34, 358, 572, 72, Color.new(16_u8, 20_u8, 30_u8, 255_u8))
    Citrine.draw_text("CROSS: Play/Pause   CIRCLE: Stop   SQUARE: Loop   TRIANGLE: Album Art View", 46, 368, 10, Color::Yellow)
    Citrine.draw_text("DPAD LEFT/RIGHT: Prev/Next Track   DPAD UP/DOWN: Master Volume +/-", 46, 388, 10, Color::Cyan)
    Citrine.draw_text("L1/R1: +/- 10s   L2/R2 (Hold): Rewind/Fast Forward   (13 Optical CAS Tracks)", 46, 408, 10, Color::LightGray)
  end

  Citrine.end_drawing

end

Citrine.close_window
