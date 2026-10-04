# Citrine String Utilities & Slice Views
# Modular engine abstraction - require "citrine/string"

# Zero-copy view into a contiguous substring to avoid heap allocations on PS2.
struct StringSlice
  # Backing source string.
  property base : String
  # Starting character offset in the base string.
  property offset : Int32
  # Character length of the view window.
  property length : Int32

  # Creates a slice window referencing `base` starting at `offset` with `length`.
  def initialize(@base : String, @offset : Int32 = 0, @length : Int32 = -1)
    if @length < 0
      @length = @base.size - @offset
    end
  end

  # Returns character count of this slice.
  def size : Int32
    @length
  end

  # Returns true if this slice spans 0 characters.
  def empty? : Bool
    @length <= 0
  end

  # Materializes slice window into an allocated Crystal/Citrine String.
  def to_s : String
    @base[@offset, @length]
  end

  # Returns true if this slice begins with `prefix`.
  def starts_with?(prefix : String) : Bool
    return false if prefix.size > @length
    @base[@offset, prefix.size] == prefix
  end

  # Returns true if this slice ends with `suffix`.
  def ends_with?(suffix : String) : Bool
    return false if suffix.size > @length
    start = @offset + @length - suffix.size
    @base[start, suffix.size] == suffix
  end

  # Returns true if this slice contains substring `substring`.
  def includes?(substring : String) : Bool
    to_s.includes?(substring)
  end
end

module Citrine
  # String manipulation utility functions.
  module StringUtil
    # Checks whether `str` begins with `prefix`.
    def self.starts_with?(str : String, prefix : String) : Bool
      str.starts_with?(prefix)
    end

    # Checks whether `str` ends with `suffix`.
    def self.ends_with?(str : String, suffix : String) : Bool
      str.ends_with?(suffix)
    end

    # Checks whether `str` contains substring `sub`.
    def self.includes?(str : String, sub : String) : Bool
      str.includes?(sub)
    end

    # Returns an uppercase copy of `str`.
    def self.upcase(str : String) : String
      str.upcase
    end

    # Returns a lowercase copy of `str`.
    def self.downcase(str : String) : String
      str.downcase
    end

    # Concatenates array of strings `pieces` separated by `delimiter`.
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
