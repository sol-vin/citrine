module Citrine
  class SimpleRegex
    getter pattern : String

    def initialize(@pattern : String)
    end

    def match(str : String) : Int32?
      if @pattern.includes?('|')
        @pattern.split('|').each do |sub_pat|
          sub_re = SimpleRegex.new(sub_pat)
          if idx = sub_re.match(str)
            return idx
          end
        end
        return nil
      end

      pat = @pattern
      anchor_start = pat.starts_with?('^')
      pat = pat[1..-1] if anchor_start
      anchor_end = pat.ends_with?('$') && !pat.ends_with?("\\$")
      pat = pat[0...-1] if anchor_end

      if anchor_start
        if end_idx = match_here(pat, 0, str, 0)
          return (anchor_end ? (end_idx == str.size ? 0 : nil) : 0)
        else
          return nil
        end
      end

      0.upto(str.size) do |i|
        if end_idx = match_here(pat, 0, str, i)
          if anchor_end
            return i if end_idx == str.size
          else
            return i
          end
        end
      end
      nil
    end

    def matches?(str : String) : Bool
      !match(str).nil?
    end

    def match?(str : String) : Bool
      matches?(str)
    end

    private def next_token(pat : String, p_idx : Int32) : Tuple(String, Int32)
      return {"", p_idx} if p_idx >= pat.size
      if pat[p_idx] == '\\' && p_idx + 1 < pat.size
        {pat[p_idx..(p_idx + 1)], p_idx + 2}
      elsif pat[p_idx] == '['
        close_idx = pat.index(']', p_idx + 1)
        if close_idx
          {pat[p_idx..close_idx], close_idx + 1}
        else
          {pat[p_idx..p_idx], p_idx + 1}
        end
      else
        {pat[p_idx..p_idx], p_idx + 1}
      end
    end

    private def match_here(pat : String, p_idx : Int32, str : String, s_idx : Int32) : Int32?
      if p_idx >= pat.size
        return s_idx
      end

      token, next_p = next_token(pat, p_idx)
      return s_idx if token.empty?

      quantifier = next_p < pat.size ? pat[next_p] : nil

      if quantifier == '*' || quantifier == '+' || quantifier == '?'
        next_p_after = next_p + 1
        case quantifier
        when '?'
          if s_idx < str.size && token_match?(token, str[s_idx])
            res = match_here(pat, next_p_after, str, s_idx + 1)
            return res if res
          end
          return match_here(pat, next_p_after, str, s_idx)
        when '*'
          max_k = 0
          while (s_idx + max_k) < str.size && token_match?(token, str[s_idx + max_k])
            max_k += 1
          end
          max_k.downto(0) do |k|
            res = match_here(pat, next_p_after, str, s_idx + k)
            return res if res
          end
          return nil
        when '+'
          if s_idx >= str.size || !token_match?(token, str[s_idx])
            return nil
          end
          max_k = 1
          while (s_idx + max_k) < str.size && token_match?(token, str[s_idx + max_k])
            max_k += 1
          end
          max_k.downto(1) do |k|
            res = match_here(pat, next_p_after, str, s_idx + k)
            return res if res
          end
          return nil
        end
      end

      if s_idx < str.size && token_match?(token, str[s_idx])
        return match_here(pat, next_p, str, s_idx + 1)
      end

      nil
    end

    private def token_match?(token : String, c : Char) : Bool
      if token.starts_with?('\\') && token.size >= 2
        case token[1]
        when 'd' then c.ascii_number?
        when 'w' then c.ascii_alphanumeric? || c == '_'
        when 's' then c.ascii_whitespace?
        else c == token[1]
        end
      elsif token.starts_with?('[') && token.ends_with?(']') && token.size >= 3
        inner = token[1...-1]
        negated = inner.starts_with?('^')
        inner = inner[1..-1] if negated
        matched = false
        i = 0
        while i < inner.size
          if i + 2 < inner.size && inner[i + 1] == '-'
            range_start = inner[i]
            range_end = inner[i + 2]
            if c >= range_start && c <= range_end
              matched = true
              break
            end
            i += 3
          else
            if inner[i] == c
              matched = true
              break
            end
            i += 1
          end
        end
        negated ? !matched : matched
      elsif token == "."
        c != '\n' && c != '\r'
      else
        token == c.to_s
      end
    end
  end

  alias LeanRegex = SimpleRegex
end
