require "yaml"
require "json"

module Citrine
  module Config
    # Loads YAML configuration files
    def self.load_yaml(path : String) : YAML::Any
      content = File.read(path)
      YAML.parse(content)
    end

    # Saves data structure to YAML
    def self.save_yaml(path : String, data)
      File.write(path, data.to_yaml)
    end

    # Loads JSON configuration or level data
    def self.load_json(path : String) : JSON::Any
      content = File.read(path)
      JSON.parse(content)
    end

    # Saves data structure to JSON
    def self.save_json(path : String, data)
      File.write(path, data.to_pretty_json)
    end
  end

  module Importers
    module DataHelpers
      def self.parse_yaml(text : String) : YAML::Any
        YAML.parse(text)
      end

      def self.parse_json(text : String) : JSON::Any
        JSON.parse(text)
      end

      def self.parse_manifest(text : String) : AssetManifest
        AssetManifest.from_json(text)
      end
    end
  end

  class AssetManifest
    include JSON::Serializable
    include YAML::Serializable

    property name : String = "game_assets"
    property version : String = "1.0.0"
    property assets : Hash(String, String) = {} of String => String
    property meshes : Array(String) = [] of String
    property fonts : Array(String) = [] of String
    property textures : Array(String) = [] of String
    property sounds : Array(String) = [] of String

    def initialize(@name = "game_assets", @version = "1.0.0")
    end

    def self.load(path : String) : AssetManifest
      content = File.read(path)
      if path.ends_with?(".yaml") || path.ends_with?(".yml")
        from_yaml(content)
      else
        from_json(content)
      end
    end

    def save(path : String)
      if path.ends_with?(".yaml") || path.ends_with?(".yml")
        File.write(path, to_yaml)
      else
        File.write(path, to_pretty_json)
      end
    end
  end
end
