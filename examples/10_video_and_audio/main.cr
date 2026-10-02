require "citrine"

Citrine.init_window(640, 448, "10 Video & Audio Showcase - Citrine PS2")
Citrine.set_target_fps(60)

# Load media handles
video_handle = Citrine.load_video("assets/intro.pss")
sound_handle = Citrine.load_sound("assets/theme.vag")

# Start playback
Citrine.play_video(video_handle, true)
Citrine.play_sound(sound_handle)

video_playing = true
loop_enabled = true

Citrine.main_loop do
  # Input controls
  if Citrine.button_pressed?(Button::Cross)
    if video_playing
      Citrine.pause_video(video_handle)
      video_playing = false
    else
      Citrine.play_video(video_handle, loop_enabled)
      video_playing = true
    end
  end

  if Citrine.button_pressed?(Button::Circle)
    Citrine.stop_video(video_handle)
    video_playing = false
  end

  Citrine.begin_drawing
  Citrine.clear_background(Color::Black)

  # Title
  Citrine.draw_text("Citrine PS2 IPU Video & SPU2 Audio Demo", 40, 30, 20, Color::White)
  Citrine.draw_text("15 FPS IPU Downsampling | 4-Bit ADPCM VAG Audio Streaming", 40, 60, 14, Color::Yellow)

  # Video Viewport (512x288 16:9 frame centered)
  Citrine.draw_video_frame(video_handle, 64, 100, 512, 256)

  # Status & Controls HUD
  Citrine.draw_rectangle(40, 380, 560, 45, Color::DarkGray)
  Citrine.draw_text("CROSS: Play/Pause | CIRCLE: Stop | SPU2 Audio: ACTIVE (22.05kHz)", 60, 395, 14, Color::White)

  Citrine.end_drawing
end

Citrine.close_window
