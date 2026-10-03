# Citrine Standard Library: Regex and Pattern Matching Stubs
# PlayStation 2 EE Thompson NFA / Pike Matching Engine

{% unless @top_level.has_constant?("Regex") %}
struct MatchData
  getter string : String
  getter regex : Regex
  getter pos : Int32
  getter length : Int32

  def initialize(@string : String, @regex : Regex, @pos : Int32, @length : Int32)
  end

  def begin(n : Int32 = 0) : Int32
    @pos
  end

  def size : Int32
    1
  end

  def [](n : Int32) : String
    @string[@pos, @length] rescue ""
  end
end

class Regex
  getter pattern : String

  def initialize(@pattern : String)
    @source = @pattern
  end

  def matches?(str : String) : Bool
    # Compiler maps this to NativeId::RegexMatch (191)
    false
  end

  def match(str : String) : MatchData?
    # Compiler maps this to NativeId::RegexMatch (191)
    nil
  end

  def =~(str : String) : Int32?
    nil
  end

  def to_s(io : IO)
    io << "/" << @pattern << "/"
  end
end

class String
  def =~(regex : Regex) : Int32?
    nil
  end

  def strip : String
    self
  end

  def downcase : String
    self
  end

  def upcase : String
    self
  end

  def starts_with?(prefix : String) : Bool
    false
  end

  def ends_with?(suffix : String) : Bool
    false
  end

  def includes?(substr : String) : Bool
    false
  end

  def split(delimiter : String = " ") : Array(String)
    [] of String
  end
end
{% end %}
