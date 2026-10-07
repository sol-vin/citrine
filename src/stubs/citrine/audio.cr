# Citrine PS2 Audio Subsystem & SPU2 Memory Budgeting Architecture
# Modular engine abstraction - require "citrine/audio"

require "../citrine"

module Citrine
  # SPU2 Hardware Audio Subsystem with 2MB sound memory auditing,
  # multi-channel audio mixing buses (Master, Music, SFX, Voice),
  # first-class Album / Track / Playlist domain models,
  # declarative sound banks, tiered sample lifecycles (:pinned, :cached, :transient),
  # LRU sound memory eviction, and dedicated optical disc streaming.
  module Audio
    # SPU2 Sound Memory Capacity: 2 MB (2,097,152 bytes)
    SPU2_RAM_TOTAL = 2 * 1024 * 1024 # 2,097,152 bytes

    # Audio Mixing Buses
    enum Bus
      Master
      Music
      SFX
      Voice
    end

    # Playlist repeat modes
    enum RepeatMode
      All
      One
      Off
    end

    # Lifecycle policy for audio samples in SPU2 sound RAM.
    enum Policy
      # Permanently resident in SPU2 RAM (UI sounds, player weapons, core SFX). Never evicted.
      Pinned
      # Loaded on demand; subject to Least-Recently-Used (LRU) eviction when SPU2 RAM is constrained.
      Cached
      # Transient one-shot (e.g. cutscene voice line); scheduled for unloading immediately after playback.
      Transient
    end

    # Playback voice channel priority for SPU2 hardware voice allocation.
    enum Priority
      Ambient  = 0
      Normal   = 1
      High     = 2
      Critical = 3
    end

    # -----------------------------------------------------------------------
    # Domain Model: Track & Album
    # -----------------------------------------------------------------------

    struct Track
      property index : Int32
      property number : Int32
      property title : String
      property artist : String
      property album : String
      property duration : Float32
      property duration_s : String
      property stream_file : String
      property optical_str : String

      def initialize(
        @index : Int32 = 0,
        @number : Int32 = 1,
        @title : String = "",
        @artist : String = "",
        @album : String = "",
        duration : Number = 0,
        @duration_s : String = "00:00",
        @stream_file : String = "",
        @optical_str : String = ""
      )
        @duration = duration.to_f32
      end

      # Formatted track title with zero-padded number (e.g. "01 Overture")
      def full_title : String
        prefix = @number < 10 ? "0#{@number}" : "#{@number}"
        "#{prefix} #{@title}"
      end

      # Plays this track through the streaming music engine
      def play : Bool
        Citrine.play_stream(@index)
      end

      # Stops playback of this track
      def stop : Bool
        Audio.stop_music
      end
    end

    struct Album
      property title : String
      property artist : String
      property tracks : Array(Track)

      def initialize(
        @title : String = "",
        @artist : String = "",
        @tracks : Array(Track) = [] of Track
      )
      end

      # Formatted uppercase album display header (e.g. "NIGHT TEMPO - MOONRISE")
      def header : String
        "#{@artist.upcase} - #{@title.upcase}"
      end

      # Number of tracks on this album
      def size : Int32
        @tracks.size
      end

      # Number of tracks on this album
      def track_count : Int32
        @tracks.size
      end

      # Indexed track lookup
      def [](idx : Int32) : Track
        @tracks[idx]
      end

      # Safe indexed track lookup
      def []?(idx : Int32) : Track?
        @tracks[idx]?
      end

      # Total duration of all tracks in seconds
      def total_duration : Int32
        @tracks.sum(&.duration.to_i)
      end

      # Total duration formatted as MM:SS
      def total_duration_s : String
        tot = total_duration
        m = tot // 60
        s = tot % 60
        m_str = m < 10 ? "0#{m}" : "#{m}"
        s_str = s < 10 ? "0#{s}" : "#{s}"
        "#{m_str}:#{s_str}"
      end

      # Iterates across all tracks on this album
      def each(&block : Track -> Nil)
        @tracks.each(&block)
      end

      # Plays specified track by index
      def play(track_idx : Int32) : Bool
        Citrine.play_stream(track_idx)
      end

      # Pre-formatted array of track titles
      def track_titles : Array(String)
        @tracks.map(&.full_title)
      end

      # Array of track durations in seconds
      def track_durations : Array(Float32)
        @tracks.map(&.duration)
      end

      # Pre-formatted optical track lookup strings
      def optical_tracks : Array(String)
        @tracks.map(&.optical_str)
      end

      # Pre-formatted duration strings (MM:SS)
      def track_dur_strings : Array(String)
        @tracks.map(&.duration_s)
      end
    end

    # Dynamic playlist queue with repeat modes and shuffle support
    class Playlist
      property album : Album
      property current_index : Int32
      property repeat_mode : RepeatMode
      property shuffle : Bool
      property is_playing : Bool

      def initialize(
        @album : Album,
        @repeat_mode : RepeatMode = RepeatMode::All,
        @shuffle : Bool = false
      )
        @current_index = 0
        @is_playing = false
      end

      def current_track : Track
        @album[@current_index]
      end

      def play : Bool
        @is_playing = true
        current_track.play
      end

      def stop : Bool
        @is_playing = false
        Audio.stop_music
      end

      def next_track : Track
        case @repeat_mode
        when RepeatMode::One
          # Repeat active track
        when RepeatMode::All
          @current_index = (@current_index + 1) % @album.size
        when RepeatMode::Off
          if @current_index + 1 < @album.size
            @current_index += 1
          else
            @is_playing = false
          end
        end
        play if @is_playing
        current_track
      end

      def prev_track : Track
        @current_index = (@current_index - 1 + @album.size) % @album.size
        play if @is_playing
        current_track
      end
    end

    # -----------------------------------------------------------------------
    # First-Class Sound Effect Primitive
    # -----------------------------------------------------------------------

    struct Sound
      property handle : UInt32
      property path : String

      def initialize(@handle : UInt32, @path : String = "")
      end

      # Plays this sound effect with volume, pitch, and stereo panning (-1.0 to 1.0)
      def play(volume : Number = 1.0, pitch : Number = 1.0, pan : Number = 0.0) : Nil
        eff_vol = Audio.compute_effective_volume(Bus::SFX, volume)
        return if eff_vol <= 0
        Citrine.set_sound_volume(@handle, eff_vol)
        Citrine.set_sound_pitch(@handle, pitch.to_f32)
        Citrine.play_sound(@handle)
      end

      # Plays with subtle randomized pitch variation (+/- pitch_variance)
      def play_varied(pitch_variance : Number = 0.1, volume : Number = 1.0) : Nil
        r = ((Audio.sound_clock * 1000.0_f32).to_i % 100).to_f32 / 100.0_f32
        pitch = 1.0_f32 + (r - 0.5_f32) * 2.0_f32 * pitch_variance.to_f32
        play(volume: volume, pitch: pitch)
      end

      # 2D Positional audio: calculates stereo panning (-1.0 to 1.0) and distance attenuation
      def play_at(
        source_x : Number, source_y : Number,
        listener_x : Number, listener_y : Number,
        max_dist : Number = 300.0
      ) : Nil
        dx = source_x.to_f32 - listener_x.to_f32
        dy = source_y.to_f32 - listener_y.to_f32
        dist = Math.sqrt(dx * dx + dy * dy).to_f32
        return if dist >= max_dist.to_f32

        pan = (dx / max_dist.to_f32).clamp(-1.0_f32, 1.0_f32)
        atten = (1.0_f32 - (dist / max_dist.to_f32)).clamp(0.0_f32, 1.0_f32)
        play(volume: atten, pan: pan)
      end

      def stop : Nil
        Citrine.stop_sound(@handle)
      end

      def unload : Nil
        Citrine.unload_sound(@handle)
      end

      def playing? : Bool
        true
      end
    end

    # -----------------------------------------------------------------------
    # Metadata and Memory State for an SPU2 Audio Sample
    # -----------------------------------------------------------------------

    class SoundClip
      property name : Symbol
      property path : String
      property size_bytes : Int32
      property policy : Policy
      property priority : Priority
      property handle : UInt32
      property is_loaded : Bool
      property last_played : Float32

      def initialize(
        @name : Symbol,
        @path : String,
        @size_bytes : Int32 = 32_768,
        @policy : Policy = Policy::Cached,
        @priority : Priority = Priority::Normal
      )
        @handle = 0_u32
        @is_loaded = false
        @last_played = 0.0_f32
      end

      def load! : UInt32
        return @handle if @is_loaded
        Audio.ensure_memory(@size_bytes)
        @handle = Citrine.load_sound(@path)
        @is_loaded = true
        Audio.track_allocation(@size_bytes)
        @handle
      end

      def unload!
        return unless @is_loaded
        Citrine.stop_sound(@handle)
        @is_loaded = false
        Audio.track_deallocation(@size_bytes)
        @handle = 0_u32
      end
    end

    # Declarative Sound Bank grouping related sound effects with a strict memory budget.
    class Bank
      property name : Symbol
      property budget_bytes : Int32
      property clips : Hash(Symbol, SoundClip)
      property streams : Hash(Symbol, String)

      def initialize(@name : Symbol, @budget_bytes : Int32 = 512 * 1024)
        @clips = Hash(Symbol, SoundClip).new
        @streams = Hash(Symbol, String).new
      end

      def sound(
        name : Symbol,
        path : String,
        size_bytes : Int32 = 32_768,
        pinned : Bool = false,
        cached : Bool = false,
        transient : Bool = false,
        priority : Priority = Priority::Normal
      )
        pol = if pinned
                Policy::Pinned
              elsif transient
                Policy::Transient
              else
                Policy::Cached
              end

        clip = SoundClip.new(name, path, size_bytes, pol, priority)
        @clips[name] = clip
        Audio.register_clip(clip)
      end

      def stream(name : Symbol, path : String)
        @streams[name] = path
      end

      def load_all(include_cached : Bool = false)
        @clips.each_value do |clip|
          if clip.policy == Policy::Pinned || include_cached
            clip.load!
          end
        end
      end

      def unload_all
        @clips.each_value(&.unload!)
      end

      def total_size_bytes : Int32
        @clips.values.sum(&.size_bytes)
      end
    end

    # -----------------------------------------------------------------------
    # Audio State & Bus Mixer Storage
    # -----------------------------------------------------------------------

    @@active_banks = Hash(Symbol, Bank).new
    @@all_clips = Hash(Symbol, SoundClip).new
    @@used_spu2_bytes : Int32 = 0
    @@sound_clock : Float32 = 0.0_f32

    # Audio Bus Volumes (0.0 .. 1.0)
    @@master_volume : Float32 = 1.0_f32
    @@music_volume : Float32 = 1.0_f32
    @@sfx_volume : Float32 = 1.0_f32
    @@voice_volume : Float32 = 1.0_f32
    @@muted_buses_mask : UInt32 = 0_u32

    # Music Engine State
    @@music_playing : Bool = false
    @@music_paused : Bool = false
    @@music_time : Float32 = 0.0_f32
    @@music_duration : Float32 = 0.0_f32
    @@current_music_track : Int32 = 0

    # -----------------------------------------------------------------------
    # Audio Bus Mixer Controls
    # -----------------------------------------------------------------------

    def self.sound_clock : Float32
      @@sound_clock
    end

    def self.master_volume : Float32
      @@master_volume
    end

    def self.master_volume=(vol : Number)
      norm = (vol > 1.0 ? vol / 255.0 : vol).to_f32.clamp(0.0_f32, 1.0_f32)
      @@master_volume = norm
      update_hardware_stream_volume
    end

    def self.music_volume : Float32
      @@music_volume
    end

    def self.music_volume=(vol : Number)
      norm = (vol > 1.0 ? vol / 255.0 : vol).to_f32.clamp(0.0_f32, 1.0_f32)
      @@music_volume = norm
      update_hardware_stream_volume
    end

    def self.sfx_volume : Float32
      @@sfx_volume
    end

    def self.sfx_volume=(vol : Number)
      norm = (vol > 1.0 ? vol / 255.0 : vol).to_f32.clamp(0.0_f32, 1.0_f32)
      @@sfx_volume = norm
    end

    def self.voice_volume : Float32
      @@voice_volume
    end

    def self.voice_volume=(vol : Number)
      norm = (vol > 1.0 ? vol / 255.0 : vol).to_f32.clamp(0.0_f32, 1.0_f32)
      @@voice_volume = norm
    end

    private def self.resolve_bus(bus : Symbol | Bus) : Bus
      case bus
      when Bus then bus
      when :master then Bus::Master
      when :music then Bus::Music
      when :sfx then Bus::SFX
      when :voice then Bus::Voice
      else Bus::Master
      end
    end

    def self.reset_buses
      @@master_volume = 1.0_f32
      @@music_volume = 1.0_f32
      @@sfx_volume = 1.0_f32
      @@voice_volume = 1.0_f32
      @@muted_buses_mask = 0_u32
    end

    def self.set_bus_volume(bus : Symbol | Bus, vol : Number)
      norm = (vol > 1.0 ? vol / 255.0 : vol).to_f32.clamp(0.0_f32, 1.0_f32)
      case resolve_bus(bus)
      when Bus::Master then self.master_volume = norm
      when Bus::Music  then self.music_volume = norm
      when Bus::SFX    then self.sfx_volume = norm
      when Bus::Voice  then self.voice_volume = norm
      end
    end

    def self.bus_volume(bus : Symbol | Bus) : Float32
      case resolve_bus(bus)
      when Bus::Master then @@master_volume
      when Bus::Music  then @@music_volume
      when Bus::SFX    then @@sfx_volume
      when Bus::Voice  then @@voice_volume
      else @@master_volume
      end
    end

    def self.mute_bus(bus : Symbol | Bus)
      mute(bus)
    end

    def self.unmute_bus(bus : Symbol | Bus)
      unmute(bus)
    end

    def self.bus_muted?(bus : Symbol | Bus) : Bool
      muted?(bus)
    end

    def self.effective_volume(bus : Symbol | Bus, volume : Number = 1.0) : Float32
      b = resolve_bus(bus)
      return 0.0_f32 if muted?(b) || muted?(Bus::Master)
      bus_gain = case b
                 when Bus::Master then 1.0_f32
                 when Bus::Music  then @@music_volume
                 when Bus::SFX    then @@sfx_volume
                 when Bus::Voice  then @@voice_volume
                 else 1.0_f32
                 end
      clip_gain = (volume > 1.0 ? volume / 255.0 : volume).to_f32.clamp(0.0_f32, 1.0_f32)
      @@master_volume * bus_gain * clip_gain
    end

    def self.effective_hw_volume(bus : Symbol | Bus, volume : Number = 1.0) : Int32
      compute_effective_volume(resolve_bus(bus), volume)
    end

    def self.calculate_positional(source_x : Float32, source_y : Float32, listener_x : Float32, listener_y : Float32, max_dist : Float32 = 400.0_f32) : Tuple(Float32, Float32, Float32)
      dx = source_x - listener_x
      dy = source_y - listener_y
      dist = Math.sqrt(dx * dx + dy * dy).to_f32

      att = (1.0_f32 - (dist / max_dist)).clamp(0.0_f32, 1.0_f32)
      pan = (dx / max_dist).clamp(-1.0_f32, 1.0_f32)
      pitch = 1.0_f32
      {att, pitch, pan}
    end

    def self.mute(bus : Symbol | Bus)
      b = resolve_bus(bus)
      @@muted_buses_mask |= (1_u32 << b.value)
      update_hardware_stream_volume if b == Bus::Music || b == Bus::Master
    end

    def self.unmute(bus : Symbol | Bus)
      b = resolve_bus(bus)
      @@muted_buses_mask &= ~(1_u32 << b.value)
      update_hardware_stream_volume if b == Bus::Music || b == Bus::Master
    end

    def self.muted?(bus : Symbol | Bus) : Bool
      b = resolve_bus(bus)
      ((@@muted_buses_mask & (1_u32 << b.value)) != 0_u32) || ((@@muted_buses_mask & (1_u32 << Bus::Master.value)) != 0_u32)
    end

    # Computes hardware volume (0..255) after bus attenuation and mute mask
    def self.compute_effective_volume(bus : Bus, volume : Number = 1.0) : Int32
      return 0 if muted?(bus) || muted?(Bus::Master)
      bus_gain = case bus
                 when Bus::Master then 1.0_f32
                 when Bus::Music  then @@music_volume
                 when Bus::SFX    then @@sfx_volume
                 when Bus::Voice  then @@voice_volume
                 else 1.0_f32
                 end
      clip_gain = (volume > 1.0 ? volume / 255.0 : volume).to_f32.clamp(0.0_f32, 1.0_f32)
      eff = (@@master_volume * bus_gain * clip_gain * 255.0_f32).round.to_i
      eff.clamp(0, 255)
    end

    private def self.update_hardware_stream_volume
      eff = compute_effective_volume(Bus::Music, 1.0)
      Citrine.set_stream_volume(eff)
    end

    # -----------------------------------------------------------------------
    # Direct Sound Effects & SPU2 Allocation
    # -----------------------------------------------------------------------

    # Loads SPU2 sound effect sample from disc into sound memory and returns Sound object
    def self.load_sound(path : String) : Sound
      handle = Citrine.load_sound(path)
      Sound.new(handle, path)
    end

    # Fires a one-shot sound effect by path or handle
    def self.play_sound(path_or_handle : String | UInt32, volume : Number = 1.0, pitch : Number = 1.0, pan : Number = 0.0) : Nil
      handle = path_or_handle.is_a?(String) ? Citrine.load_sound(path_or_handle) : path_or_handle
      snd = Sound.new(handle, path_or_handle.is_a?(String) ? path_or_handle : "")
      snd.play(volume: volume, pitch: pitch, pan: pan)
    end

    # Fires a one-shot sound effect with randomized pitch variance
    def self.play_sound_varied(path_or_handle : String | UInt32, pitch_variance : Number = 0.1, volume : Number = 1.0) : Nil
      handle = path_or_handle.is_a?(String) ? Citrine.load_sound(path_or_handle) : path_or_handle
      snd = Sound.new(handle, path_or_handle.is_a?(String) ? path_or_handle : "")
      snd.play_varied(pitch_variance: pitch_variance, volume: volume)
    end

    # Fires a 2D positional sound effect with stereo panning and distance falloff
    def self.play_sound_at(
      path_or_handle : String | UInt32,
      source_x : Number, source_y : Number,
      listener_x : Number, listener_y : Number,
      max_dist : Number = 300.0
    ) : Nil
      handle = path_or_handle.is_a?(String) ? Citrine.load_sound(path_or_handle) : path_or_handle
      snd = Sound.new(handle, path_or_handle.is_a?(String) ? path_or_handle : "")
      snd.play_at(source_x, source_y, listener_x, listener_y, max_dist)
    end

    # -----------------------------------------------------------------------
    # SPU2 Memory Tracking & Eviction
    # -----------------------------------------------------------------------

    def self.used_memory : Int32
      @@used_spu2_bytes
    end

    def self.free_memory : Int32
      SPU2_RAM_TOTAL - @@used_spu2_bytes
    end

    def self.track_allocation(bytes : Int32)
      @@used_spu2_bytes += bytes
    end

    def self.track_deallocation(bytes : Int32)
      @@used_spu2_bytes -= bytes
      @@used_spu2_bytes = 0 if @@used_spu2_bytes < 0
    end

    def self.register_clip(clip : SoundClip)
      @@all_clips[clip.name] = clip
    end

    def self.ensure_memory(required_bytes : Int32)
      return if free_memory >= required_bytes
      candidates = @@all_clips.values.select { |c| c.is_loaded && c.policy == Policy::Cached }
      candidates.sort_by!(&.last_played)
      candidates.each do |clip|
        break if free_memory >= required_bytes
        clip.unload!
      end
      if free_memory < required_bytes
        Citrine.puts("[CITRINE AUDIO WARNING] SPU2 RAM budget constrained: #{free_memory} bytes free, requested #{required_bytes} bytes")
      end
    end

    def self.bank(name : Symbol, budget : Int32 = 512 * 1024, &block : Bank -> Nil) : Bank
      b = Bank.new(name, budget)
      yield b
      @@active_banks[name] = b
      b.load_all(include_cached: false)
      b
    end

    def self.get_bank(name : Symbol) : Bank?
      @@active_banks[name]?
    end

    def self.with_bank(name : Symbol, &block : Bank -> Nil)
      if b = @@active_banks[name]?
        b.load_all(include_cached: false)
        begin
          yield b
        ensure
          b.unload_all
        end
      end
    end

    def self.play(
      name : Symbol,
      volume : Number = 1.0,
      pitch : Number = 1.0,
      pan : Number = 0.0,
      priority : Priority? = nil
    )
      @@sound_clock += 0.016667_f32
      if clip = @@all_clips[name]?
        handle = clip.load!
        clip.last_played = @@sound_clock
        eff = compute_effective_volume(Bus::SFX, volume)
        Citrine.set_sound_volume(handle, eff)
        Citrine.set_sound_pitch(handle, pitch.to_f32)
        Citrine.play_sound(handle)
        clip.unload! if clip.policy == Policy::Transient
      end
    end

    def self.stop(name : Symbol)
      if clip = @@all_clips[name]?
        Citrine.stop_sound(clip.handle) if clip.is_loaded
      end
    end

    # -----------------------------------------------------------------------
    # Unified Streaming Music Engine (0 SPU2 RAM - Optical IOP DMA Ring Buffer)
    # -----------------------------------------------------------------------

    def self.play_music(track_or_path : Track | String | Int32, loop : Bool = true, volume : Number = 1.0) : Bool
      update_hardware_stream_volume
      case track_or_path
      when Track
        @@current_music_track = track_or_path.index
        @@music_duration = track_or_path.duration
        @@music_time = 0.0_f32
        @@music_playing = true
        @@music_paused = false
        Citrine.play_stream(track_or_path.index)
      when String
        @@music_time = 0.0_f32
        @@music_playing = true
        @@music_paused = false
        Citrine.play_stream(track_or_path)
      when Int32
        @@current_music_track = track_or_path
        @@music_time = 0.0_f32
        @@music_playing = true
        @@music_paused = false
        Citrine.play_stream(track_or_path)
      else
        false
      end
    end

    def self.pause_music : Bool
      if @@music_playing && !@@music_paused
        @@music_paused = true
        Citrine.pause_stream
      else
        false
      end
    end

    def self.resume_music : Bool
      if @@music_playing && @@music_paused
        @@music_paused = false
        Citrine.resume_stream
      else
        false
      end
    end

    def self.stop_music : Bool
      @@music_playing = false
      @@music_paused = false
      @@music_time = 0.0_f32
      Citrine.stop_stream
    end

    def self.seek_music(seconds : Number) : Bool
      @@music_time = seconds.to_f32
      Citrine.seek_stream(seconds.to_f32)
    end

    def self.music_playing? : Bool
      @@music_playing && !@@music_paused
    end

    def self.music_paused? : Bool
      @@music_paused
    end

    def self.music_stopped? : Bool
      !@@music_playing
    end

    def self.music_time : Float32
      @@music_time
    end

    def self.music_duration : Float32
      @@music_duration
    end

    def self.current_music_track : Int32
      @@current_music_track
    end

    # Legacy Stream forwarding
    def self.play_stream(track_or_name : Symbol | String | Int32) : Bool
      if track_or_name.is_a?(Symbol)
        @@active_banks.each_value do |b|
          if path = b.streams[track_or_name]?
            return play_music(path)
          end
        end
      else
        return play_music(track_or_name)
      end
      false
    end

    def self.stop_stream : Bool
      stop_music
    end

    def self.pause_stream : Bool
      pause_music
    end

    def self.resume_stream : Bool
      resume_music
    end

    def self.set_volume(vol : Int32) : Int32
      self.master_volume = vol
      vol
    end

    def self.play_cdda(track : Int32) : Bool
      Citrine.play_cdda_track(track)
    end

    def self.stop_cdda : Bool
      Citrine.stop_cdda
    end

    # Code-first album loader stub (expanded at compile-time by MacroExpander)
    def self.album(dir : String = "album/") : Album
      Album.new
    end

    def self.load_album(dir : String = "album/") : Album
      Album.new
    end
  end

  # Module-level aliases
  alias Track = Audio::Track
  alias Album = Audio::Album
  alias Playlist = Audio::Playlist
  alias Sound = Audio::Sound
  alias AudioBus = Audio::Bus
  alias RepeatMode = Audio::RepeatMode

  # Code-first album loader stub on Citrine module
  def self.album(dir : String = "album/") : Audio::Album
    Audio.album(dir)
  end

  def self.load_album(dir : String = "album/") : Audio::Album
    Audio.load_album(dir)
  end
end

# Top-level convenience aliases
alias Track = Citrine::Audio::Track
alias Album = Citrine::Audio::Album
alias Playlist = Citrine::Audio::Playlist
alias Sound = Citrine::Audio::Sound
alias AudioBus = Citrine::Audio::Bus
alias RepeatMode = Citrine::Audio::RepeatMode

# Top-level helper methods
def album(dir : String = "album/") : Citrine::Audio::Album
  Citrine::Audio.album(dir)
end

def load_album(dir : String = "album/") : Citrine::Audio::Album
  Citrine::Audio.load_album(dir)
end

