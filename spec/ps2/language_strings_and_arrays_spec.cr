require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"
require "../../src/citrine/subsystems/controller"

describe "Citrine PS2 Language Parity: Strings, Arrays & Multi-Frame Transport" do
  it "verifies string interpolation, numeric expressions, and leading-zero formatting on PS2 hardware" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_string_formatting_test")
    tc.source(<<-CR
      track_name = "Overture"
      total_sec = 132
      min = total_sec // 60
      sec = total_sec % 60
      sec_str = sec < 10 ? "0\#{sec}" : "\#{sec}"
      time_display = "Time: 0\#{min}:\#{sec_str}"
      debug_puts time_display

      opt_track = 2
      opt_str = "Optical Track 0\#{opt_track} (CD-DA AUDIO/2352)"
      debug_puts opt_str

      vol = 240
      vol_str = "Volume: \#{vol}/255"
      debug_puts vol_str

      debug_puts "[CITRINE TEST] String formatting completed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("Time: 02:12")
    result.should_have_output("Optical Track 02 (CD-DA AUDIO/2352)")
    result.should_have_output("Volume: 240/255")
    result.should_have_output("[CITRINE TEST] String formatting completed: PASS")
  end

  it "verifies array indexing with string and float arrays on PS2 hardware" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_array_indexing_test")
    tc.source(<<-CR
      titles = ["Overture", "Come On!", "Level Off"]
      durations = [132.0_f32, 209.5_f32, 216.0_f32]

      idx = 1
      t1 = titles[idx]
      d1 = durations[idx]
      debug_puts "Array Title 1: \#{t1}"
      debug_puts "Array Dur 1: \#{d1.to_i}s"

      next_idx = (idx + 1) % 3
      t_next = titles[next_idx]
      debug_puts "Array Next: \#{t_next}"

      prev_idx = (idx + 2) % 3
      t_prev = titles[prev_idx]
      debug_puts "Array Prev: \#{t_prev}"

      debug_puts "[CITRINE TEST] Array indexing completed: PASS"
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("Array Title 1: Come On!")
    result.should_have_output("Array Dur 1: 209s")
    result.should_have_output("Array Next: Level Off")
    result.should_have_output("Array Prev: Overture")
    result.should_have_output("[CITRINE TEST] Array indexing completed: PASS")
  end

  it "executes multi-frame transport state machine with simulated Cross, Right, and Circle inputs on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_multiframe_transport_test")

    # Inject Cross at frame 15 (Play -> Pause)
    tc.inject_input(frame: 15, button: Citrine::PadButton::Cross, duration: 2)

    # Inject Cross at frame 35 (Pause -> Resume)
    tc.inject_input(frame: 35, button: Citrine::PadButton::Cross, duration: 2)

    # Inject Right at frame 55 (Next Track)
    tc.inject_input(frame: 55, button: Citrine::PadButton::Right, duration: 2)

    # Inject Circle at frame 75 (Stop)
    tc.inject_input(frame: 75, button: Citrine::PadButton::Circle, duration: 2)

    tc.source(<<-CR
      require "citrine"

      Citrine.init_window(640, 448, "Transport State Machine Test")

      track_idx = 0
      is_playing = true
      frames = 0

      Citrine.main_loop do
        pad = Citrine.player(0)
        frames += 1

        if pad.button_pressed?(Button::Cross)
          if is_playing
            is_playing = false
            debug_puts "[CITRINE TEST] State: PAUSED (Position preserved)"
          else
            is_playing = true
            debug_puts "[CITRINE TEST] State: RESUMED"
          end
        end

        if pad.button_pressed?(Button::Right)
          track_idx = (track_idx + 1) % 13
          is_playing = true
          debug_puts "[CITRINE TEST] State: NEXT TRACK (Track \#{track_idx + 1})"
        end

        if pad.button_pressed?(Button::Circle)
          is_playing = false
          debug_puts "[CITRINE TEST] State: STOPPED (Position reset)"
        end

        Citrine.begin_drawing
        Citrine.clear_background(Color::Black)
        Citrine.draw_rectangle(10, 10, 100, 20, is_playing ? Color::Green : Color::Yellow)
        Citrine.end_drawing

        if frames >= 90
          debug_puts "[CITRINE TEST] Multi-frame transport test completed: PASS"
          break
        end
      end

      Citrine.close_window
    CR
    )

    result = tc.boot_pcsx2(timeout: 10.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("[CITRINE] Button Cross (X) pressed!")
    result.should_have_output("[CITRINE] Button Right pressed!")
    result.should_have_output("[CITRINE] Button Circle pressed!")
  end

  it "verifies code-first album metadata loading, constant folding, and string upcase on PS2 hardware" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_album_metadata_test")
    tc.target("examples/10_video_and_audio/test_album_meta.cr")
    tc.source(<<-CR
      TRACK_TITLES = Citrine.album_track_titles
      TRACK_DURATIONS = Citrine.album_track_durations
      ALBUM_TITLE = Citrine.album_title
      ALBUM_ARTIST = Citrine.album_artist
      TOTAL_TRACKS = TRACK_TITLES.size
      ALBUM_HEADER = "\#{ALBUM_ARTIST.upcase} - \#{ALBUM_TITLE.upcase}"

      debug_puts "Album Header: \#{ALBUM_HEADER}"
      debug_puts "Total Tracks: \#{TOTAL_TRACKS}"
      debug_puts "First Track: \#{TRACK_TITLES[0]}"
      debug_puts "First Duration: \#{TRACK_DURATIONS[0].to_i}s"

      next_t = (0 + 1) % TOTAL_TRACKS
      debug_puts "Next Track: \#{TRACK_TITLES[next_t]}"

      debug_puts "[CITRINE TEST] Album metadata test completed: PASS"
    CR
    )

    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_no_memory_leaks
    result.should_preserve_spram
    result.should_have_output("Album Header: NIGHT TEMPO - MOONRISE")
    result.should_have_output("Total Tracks: 13")
    result.should_have_output("First Track: 01 Overture (feat. Neon Bunny, Super Brass)")
    result.should_have_output("First Duration: 132s")
    result.should_have_output("Next Track: 02 Come On! (feat. Super Brass, Tomggg)")
    result.should_have_output("[CITRINE TEST] Album metadata test completed: PASS")
  end
end
