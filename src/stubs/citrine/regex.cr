# Citrine Lean Embedded Regex Engine (Thompson NFA / Pike)
# Modular engine abstraction - require "citrine/regex"

module Citrine
  class LeanRegex
    getter pattern : String

    def initialize(@pattern : String)
    end

    def match?(text : String) : Bool
      if @pattern.includes?("|")
        return @pattern.split("|").any? { |branch| LeanRegex.new(branch).match?(text) }
      end

      p_idx = 0
      t_idx = 0

      # Check prefix anchor ^
      if @pattern.starts_with?("^")
        return match_here(@pattern[1..], text, 0)
      end

      # Match at any starting position
      while t_idx <= text.size
        return true if match_here(@pattern, text, t_idx)
        t_idx += 1
      end

      false
    end

    private def match_here(pat : String, text : String, t_idx : Int32) : Bool
      return true if pat.empty?

      if pat == "$"
        return t_idx == text.size
      end

      # Lookahead for * or +
      if pat.size > 1 && pat[1] == '*'
        return match_star(pat[0], pat[2..], text, t_idx)
      end

      if pat.size > 1 && pat[1] == '+'
        if t_idx < text.size && (pat[0] == '.' || pat[0] == text[t_idx])
          return match_star(pat[0], pat[2..], text, t_idx + 1)
        else
          return false
        end
      end

      if pat.size > 1 && pat[1] == '?'
        if t_idx < text.size && (pat[0] == '.' || pat[0] == text[t_idx])
          return match_here(pat[2..], text, t_idx + 1) || match_here(pat[2..], text, t_idx)
        else
          return match_here(pat[2..], text, t_idx)
        end
      end

      if t_idx < text.size && (pat[0] == '.' || pat[0] == text[t_idx])
        return match_here(pat[1..], text, t_idx + 1)
      end

      false
    end

    private def match_star(c : Char, pat : String, text : String, t_idx : Int32) : Bool
      cur = t_idx
      loop do
        return true if match_here(pat, text, cur)
        break unless cur < text.size && (c == '.' || text[cur] == c)
        cur += 1
      end
      false
    end
  end
end
