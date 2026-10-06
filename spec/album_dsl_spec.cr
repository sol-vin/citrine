require "./spec_helper"
require "../src/citrine/parser/dsl_parser"
require "../src/citrine/compiler/macro_expander"
require "../src/citrine/compiler/bytecode_compiler"
require "../src/stubs/citrine/audio"

describe "Citrine Audio Subsystem & Album Domain DSL" do
  describe "Audio Bus Mixer" do
    it "manages independent volume levels per mixing bus" do
      Citrine::Audio.reset_buses
      Citrine::Audio.set_bus_volume(Citrine::Audio::Bus::Master, 1.0_f32)
      Citrine::Audio.set_bus_volume(Citrine::Audio::Bus::Music, 0.75_f32)
      Citrine::Audio.set_bus_volume(Citrine::Audio::Bus::SFX, 0.5_f32)
      Citrine::Audio.set_bus_volume(Citrine::Audio::Bus::Voice, 0.9_f32)

      Citrine::Audio.bus_volume(Citrine::Audio::Bus::Music).should eq(0.75_f32)
      Citrine::Audio.bus_volume(Citrine::Audio::Bus::SFX).should eq(0.5_f32)
      Citrine::Audio.effective_volume(Citrine::Audio::Bus::Music).should eq(0.75_f32)
      Citrine::Audio.effective_volume(Citrine::Audio::Bus::SFX).should eq(0.5_f32)

      # Master volume scaling
      Citrine::Audio.set_bus_volume(Citrine::Audio::Bus::Master, 0.5_f32)
      Citrine::Audio.effective_volume(Citrine::Audio::Bus::Music).should eq(0.375_f32)
      Citrine::Audio.effective_hw_volume(Citrine::Audio::Bus::Music).should eq((0.375_f32 * 255).round.to_i)
    end

    it "supports muting and unmuting individual audio buses" do
      Citrine::Audio.reset_buses
      Citrine::Audio.bus_muted?(Citrine::Audio::Bus::SFX).should be_false

      Citrine::Audio.mute_bus(Citrine::Audio::Bus::SFX)
      Citrine::Audio.bus_muted?(Citrine::Audio::Bus::SFX).should be_true
      Citrine::Audio.effective_volume(Citrine::Audio::Bus::SFX).should eq(0.0_f32)
      Citrine::Audio.effective_hw_volume(Citrine::Audio::Bus::SFX).should eq(0)

      Citrine::Audio.unmute_bus(Citrine::Audio::Bus::SFX)
      Citrine::Audio.bus_muted?(Citrine::Audio::Bus::SFX).should be_false
      Citrine::Audio.effective_volume(Citrine::Audio::Bus::SFX).should eq(1.0_f32)
    end
  end

  describe "Sound Domain Model & Positional Audio" do
    it "calculates 2D spatial attenuation and panning for Sound" do
      sound = Citrine::Audio::Sound.new(1_u16, "sfx/laser.cas")
      sound.handle.should eq(1_u16)
      sound.path.should eq("sfx/laser.cas")

      # Sound directly at listener position (max volume, center pan)
      vol, pitch, pan = Citrine::Audio.calculate_positional(100.0_f32, 100.0_f32, 100.0_f32, 100.0_f32, 200.0_f32)
      vol.should eq(1.0_f32)
      pitch.should eq(1.0_f32)
      pan.should eq(0.0_f32)

      # Sound to the far right (listener at 0, sound at 100)
      vol2, pitch2, pan2 = Citrine::Audio.calculate_positional(100.0_f32, 0.0_f32, 0.0_f32, 0.0_f32, 200.0_f32)
      vol2.should be < 1.0_f32
      pan2.should be > 0.0_f32

      # Sound to the far left (listener at 100, sound at 0)
      vol3, pitch3, pan3 = Citrine::Audio.calculate_positional(0.0_f32, 0.0_f32, 100.0_f32, 0.0_f32, 200.0_f32)
      pan3.should be < 0.0_f32
    end
  end

  describe "Streaming Music Engine" do
    it "manages playback state and transport commands" do
      Citrine::Audio.stop_music
      Citrine::Audio.music_playing?.should be_false

      Citrine::Audio.play_music(2)
      Citrine::Audio.music_playing?.should be_true
      Citrine::Audio.current_music_track.should eq(2)

      Citrine::Audio.pause_music
      Citrine::Audio.music_playing?.should be_false

      Citrine::Audio.resume_music
      Citrine::Audio.music_playing?.should be_true

      Citrine::Audio.seek_music(45.5_f32)
      Citrine::Audio.music_time.should eq(45.5_f32)

      Citrine::Audio.stop_music
      Citrine::Audio.music_playing?.should be_false
      Citrine::Audio.music_time.should eq(0.0_f32)
    end
  end

  describe "Album & Track Domain Model" do
    it "instantiates and formats Album and Track metadata correctly" do
      track1 = Citrine::Audio::Track.new(
        index: 0,
        number: 1,
        title: "Overture",
        artist: "Night Tempo",
        album: "Moonrise",
        duration: 132.0_f32,
        duration_s: "02:12",
        stream_file: "track01.cas",
        optical_str: "Track 01: TRACK01.CAS (96 kbps SPU2 Stream)"
      )
      track2 = Citrine::Audio::Track.new(
        index: 1,
        number: 2,
        title: "Come On!",
        artist: "Night Tempo",
        album: "Moonrise",
        duration: 209.4_f32,
        duration_s: "03:29",
        stream_file: "track02.cas",
        optical_str: "Track 02: TRACK02.CAS (96 kbps SPU2 Stream)"
      )

      track1.full_title.should eq("01 Overture")
      track2.full_title.should eq("02 Come On!")

      album = Citrine::Audio::Album.new(
        title: "Moonrise",
        artist: "Night Tempo",
        tracks: [track1, track2]
      )

      album.header.should eq("NIGHT TEMPO - MOONRISE")
      album.size.should eq(2)
      album.track_count.should eq(2)
      album[0].title.should eq("Overture")
      album[1].title.should eq("Come On!")
      album.total_duration_s.should eq("05:41")
      album.track_titles.should eq(["01 Overture", "02 Come On!"])
    end
  end

  describe "MacroExpander Citrine.album Integration" do
    it "expands Citrine.album into typed Album AST" do
      source = <<-CR
        require "citrine"
        require "citrine/audio"
        album = Citrine.album
      CR

      expander = Citrine::MacroExpander.new("examples/10_cd_player/main.cr")
      parser = Crystal::Parser.new(source)
      ast = parser.parse
      expanded = expander.expand(ast)

      # Expanded AST should contain Album.new and Track.new calls
      ast_str = expanded.to_s
      ast_str.should contain("Citrine::Audio::Album.new")
      ast_str.should contain("Citrine::Audio::Track.new")
      ast_str.should contain("Moonrise")
      ast_str.should contain("Night Tempo")
    end

    it "compiles example 10 with new Album DSL into valid bytecode" do
      parser = Citrine::DslParser.new("examples/10_cd_player/main.cr")
      source = File.read("examples/10_cd_player/main.cr")
      program = parser.parse(source)

      compiler = Citrine::BytecodeCompiler.new("examples/10_cd_player/main.cr")
      cbc_bytes = compiler.compile(program)
      cbc_bytes.size.should be > 16

      # Verify compiled functions include Track and Album member methods
      fn_names = compiler.functions.map(&.name)
      fn_names.should contain("Citrine::Audio::Track#full_title")
      fn_names.should contain("Citrine::Audio::Album#header")
    end
  end
end
