module Citrine
  module ISO
    enum TrackType
      Data
      CdAudio
      DvdVideo
    end

    class DiscAsset
      property source_path : String
      property target_name : String
      property track_type : TrackType
      property track_number : Int32?
      property metadata : Hash(String, String)

      def initialize(
        @source_path : String,
        @target_name : String,
        @track_type : TrackType = TrackType::Data,
        @track_number : Int32? = nil,
        @metadata : Hash(String, String) = {} of String => String
      )
      end
    end

    class DiscManifest
      property assets : Array(DiscAsset) = [] of DiscAsset
      property media_type : Symbol = :cd # :cd or :dvd

      # Global singleton manifest for current compilation session
      @@current : DiscManifest? = nil

      def self.current : DiscManifest
        @@current ||= new
      end

      def self.reset!
        @@current = new
      end

      def clear
        @assets.clear
      end

      def has_file?(name : String) : Bool
        @assets.any? { |a| a.target_name == name }
      end

      def add_file(source : String, target : String? = nil) : DiscAsset
        tname = target || File.basename(source)
        asset = DiscAsset.new(source, tname, TrackType::Data)
        @assets << asset
        asset
      end

      def add_texture(source : String, target : String? = nil, width : Int32 = 128, height : Int32 = 128, clut : Int32 = 8) : DiscAsset
        tname = target || File.basename(source).sub(/\.(png|jpg|jpeg|bmp)$/i, ".cbt")
        meta = {
          "width" => width.to_s,
          "height" => height.to_s,
          "clut" => clut.to_s,
          "kind" => "texture"
        }
        asset = DiscAsset.new(source, tname, TrackType::Data, metadata: meta)
        @assets << asset
        asset
      end

      def add_cd_track(source : String, track_num : Int32? = nil) : DiscAsset
        tname = File.basename(source)
        t_num = track_num || (next_cd_track_number)
        meta = {
          "kind" => "cdda_track"
        }
        asset = DiscAsset.new(source, tname, TrackType::CdAudio, track_number: t_num, metadata: meta)
        @assets << asset
        asset
      end

      def add_dvd_video(source : String, target : String? = nil) : DiscAsset
        tname = target || File.basename(source).sub(/\.(mp4|avi|mov|mkv)$/i, ".m2v")
        meta = {
          "kind" => "dvd_video"
        }
        asset = DiscAsset.new(source, tname, TrackType::DvdVideo, metadata: meta)
        @assets << asset
        asset
      end

      def add_spu2_sound(source : String, target : String? = nil) : DiscAsset
        tname = target || File.basename(source).sub(/\.(wav|ogg|mp3|flac)$/i, ".vag")
        meta = {
          "kind" => "spu2_sound"
        }
        asset = DiscAsset.new(source, tname, TrackType::Data, metadata: meta)
        @assets << asset
        asset
      end

      def next_cd_track_number : Int32
        cd_tracks = @assets.select { |a| a.track_type == TrackType::CdAudio }
        if cd_tracks.empty?
          2 # Track 1 is always ISO9660 Data
        else
          (cd_tracks.compact_map(&.track_number).max? || 1) + 1
        end
      end

      def data_files : Array(DiscAsset)
        @assets.select { |a| a.track_type == TrackType::Data }
      end

      def cd_audio_tracks : Array(DiscAsset)
        @assets.select { |a| a.track_type == TrackType::CdAudio }.sort_by { |a| a.track_number || 999 }
      end

      def has_cd_audio? : Bool
        @assets.any? { |a| a.track_type == TrackType::CdAudio }
      end
    end
  end
end
