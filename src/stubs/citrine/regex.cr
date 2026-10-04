# Citrine Standard Library: Regex and Pattern Matching Stubs
# PlayStation 2 EE Thompson NFA / Pike Matching Engine

{% unless @top_level.has_constant?("Regex") %}
# Encapsulates the results of a successful regular expression match against a string.
struct MatchData
  # The source string scanned by the regular expression.
  getter string : String
  # The regular expression pattern used for the match.
  getter regex : Regex
  # 0-based character start position of the match within `string`.
  getter pos : Int32
  # Total character length of the matched substring.
  getter length : Int32

  # Creates a new match data structure.
  def initialize(@string : String, @regex : Regex, @pos : Int32, @length : Int32)
  end

  # Returns the start index of the match (capture group `n`, default 0).
  def begin(n : Int32 = 0) : Int32
    @pos
  end

  # Returns the number of captured groups.
  def size : Int32
    1
  end

  # Retrieves the matched substring.
  def [](n : Int32) : String
    @string[@pos, @length] rescue ""
  end
end

# Regular expression compiler and matcher running on the EE MIPS Thompson NFA engine.
class Regex
  # Raw regular expression pattern string.
  getter pattern : String

  # Compiles regular expression `pattern`.
  def initialize(@pattern : String)
    @source = @pattern
  end

  # Returns true if `str` matches the regular expression.
  def matches?(str : String) : Bool
    # Compiler maps this to NativeId::RegexMatch (191)
    false
  end

  # Scans `str` for this pattern and returns a `MatchData` instance on match, or `nil`.
  def match(str : String) : MatchData?
    # Compiler maps this to NativeId::RegexMatch (191)
    nil
  end

  # Matches `str` and returns the start index of the match, or `nil`.
  def =~(str : String) : Int32?
    nil
  end

  # Appends regex literal string format `/pattern/` to `io`.
  def to_s(io : IO)
    io << "/" << @pattern << "/"
  end
end

# Core String extensions for regex matching and formatting.
class String
  # Matches string against regex and returns match offset or `nil`.
  def =~(regex : Regex) : Int32?
    nil
  end

  # Returns a copy of the string with leading and trailing whitespace removed.
  def strip : String
    self
  end

  # Returns a copy of the string with all characters converted to lowercase.
  def downcase : String
    self
  end

  # Returns a copy of the string with all characters converted to uppercase.
  def upcase : String
    self
  end

  # Returns true if the string begins with `prefix`.
  def starts_with?(prefix : String) : Bool
    false
  end

  # Returns true if the string ends with `suffix`.
  def ends_with?(suffix : String) : Bool
    false
  end

  # Returns true if the string contains `substr`.
  def includes?(substr : String) : Bool
    false
  end

  # Splits the string into an array of substrings using `delimiter`.
  def split(delimiter : String = " ") : Array(String)
    [] of String
  end
end
{% end %}
