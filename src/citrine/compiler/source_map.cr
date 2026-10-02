require "json"

module Citrine
  class SourceLocation
    include JSON::Serializable

    getter file : String
    getter line : Int32
    getter column : Int32
    getter function : String?

    def initialize(@file : String, @line : Int32, @column : Int32, @function : String? = nil)
    end
  end

  class SourceMap
    include JSON::Serializable

    getter locations : Hash(Int32, SourceLocation)
    getter register_names : Hash(String, Hash(Int32, String))

    def initialize
      @locations = {} of Int32 => SourceLocation
      @register_names = {} of String => Hash(Int32, String)
    end

    def add(offset : Int32, file : String, line : Int32, column : Int32, function : String? = nil)
      @locations[offset] = SourceLocation.new(file, line, column, function)
    end

    def resolve(offset : Int32) : SourceLocation?
      # Find the closest preceding offset
      return @locations[offset] if @locations.has_key?(offset)

      closest_offset = -1
      @locations.keys.each do |k|
        if k <= offset && k > closest_offset
          closest_offset = k
        end
      end

      if closest_offset >= 0
        @locations[closest_offset]
      else
        nil
      end
    end

    def find(offset : Int32) : SourceLocation?
      resolve(offset)
    end

    def record_register(func : String, reg : Int32, name : String)
      @register_names[func] ||= {} of Int32 => String
      @register_names[func][reg] = name
    end

    def to_file(path : String)
      File.write(path, self.to_json)
    end

    def save(path : String)
      to_file(path)
    end

    def self.from_file(path : String) : SourceMap
      SourceMap.from_json(File.read(path))
    end
  end
end
