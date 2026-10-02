# Citrine String Utilities & Slice Views
# Modular engine abstraction - require "citrine/string"

struct StringSlice
  property base : String
  property offset : Int32
  property length : Int32

  def initialize(@base : String, @offset : Int32 = 0, @length : Int32 = -1)
    if @length < 0
      @length = @base.size - @offset
    end
  end

  def size : Int32
    @length
  end

  def empty? : Bool
    @length <= 0
  end

  def to_s : String
    @base[@offset, @length]
  end

  def starts_with?(prefix : String) : Bool
    return false if prefix.size > @length
    @base[@offset, prefix.size] == prefix
  end

  def ends_with?(suffix : String) : Bool
    return false if suffix.size > @length
    start = @offset + @length - suffix.size
    @base[start, suffix.size] == suffix
  end

  def includes?(substring : String) : Bool
    to_s.includes?(substring)
  end
end

module Citrine
  module StringUtil
    def self.starts_with?(str : String, prefix : String) : Bool
      str.starts_with?(prefix)
    end

    def self.ends_with?(str : String, suffix : String) : Bool
      str.ends_with?(suffix)
    end

    def self.includes?(str : String, sub : String) : Bool
      str.includes?(sub)
    end

    def self.upcase(str : String) : String
      str.upcase
    end

    def self.downcase(str : String) : String
      str.downcase
    end

    def self.join(pieces : Array(String), delimiter : String = "") : String
      String.build do |io|
        pieces.each_with_index do |p, i|
          io << delimiter if i > 0
          io << p
        end
      end
    end
  end
end
