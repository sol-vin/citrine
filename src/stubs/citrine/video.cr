# Citrine Hardware IPU Video Streaming Subsystem
# Modular engine abstraction - require "citrine/video"

require "../citrine"

module Citrine
  # Streaming MPEG-2 / PSS Full-Motion Video (FMV) playback via the PS2 Image Processing Unit (IPU)
  module Video
    # Loads an MPEG-2 / PSS video stream from disc and returns a video handle.
    def self.load(path : String) : UInt32
      Citrine.load_video(path)
    end

    # Starts video playback via the hardware IPU DMA pipeline.
    def self.play(video_id : UInt32, loop : Bool = false) : Bool
      Citrine.play_video(video_id, loop)
    end

    # Renders the current IPU video frame as a textured rectangle on screen.
    def self.draw_frame(video_id : UInt32, x : Number, y : Number, width : Number, height : Number)
      Citrine.draw_video_frame(video_id, x, y, width, height)
    end

    # Returns true if video stream playback has reached the end of stream.
    def self.finished?(video_id : UInt32) : Bool
      Citrine.video_finished?(video_id)
    end

    # Pauses video stream decoding and playback.
    def self.pause(video_id : UInt32)
      Citrine.pause_video(video_id)
    end

    # Stops video stream playback and resets decoder position.
    def self.stop(video_id : UInt32)
      Citrine.stop_video(video_id)
    end

    # Convenience method to stream a full-motion video cutscene until finished or skipped.
    def self.stream(path : String, x : Number = 0, y : Number = 0, width : Number = 640, height : Number = 448, skip_button : Button? = :start)
      id = load(path)
      return if id == 0
      play(id, loop: false)
      while !finished?(id) && Citrine.window_open?
        if sb = skip_button
          break if Citrine.button_pressed?(0, sb)
        end
        Citrine.begin_drawing
        draw_frame(id, x, y, width, height)
        Citrine.end_drawing
      end
      stop(id)
    end
  end
end

# Top-level DSL alias for Video
Video = Citrine::Video
