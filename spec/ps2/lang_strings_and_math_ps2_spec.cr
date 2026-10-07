require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Strings, Interpolation & Bitwise Math" do
  it "verifies string interpolation and dynamic concatenation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("strings_interpolation_concat_test")
    tc.source(<<-CR
      engine = "Citrine"
      version_major = 2
      version_minor = 1
      active = true

      # 1. Multi-variable interpolation
      banner = "Welcome to \#{engine} v\#{version_major}.\#{version_minor} (active: \#{active})"

      # 2. String concatenation
      prefix = "Sony "
      suffix = "PlayStation 2"
      platform = prefix + suffix

      # 3. Dynamic expression inside interpolation
      calc_summary = "Calculation: 15 * 4 = \#{15 * 4}"

      c1 = (banner == "Welcome to Citrine v2.1 (active: true)")
      c2 = (platform == "Sony PlayStation 2")
      c3 = (calc_summary == "Calculation: 15 * 4 = 60")

      if c1 && c2 && c3
        debug_puts "[CITRINE TEST] Strings#interpolation_and_concat: PASS"
      else
        debug_puts "[CITRINE TEST] Strings#interpolation_and_concat: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Strings#interpolation_and_concat: PASS")
  end

  it "verifies string queries, size, and transformations on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("strings_queries_and_transforms_test")
    tc.source(<<-CR
      original = "  Emotion Engine R5900  "
      cleaned = original.strip
      upper = cleaned.upcase
      lower = cleaned.downcase

      len_clean = cleaned.size
      len_orig = original.size

      sw = cleaned.starts_with?("Emotion")
      ew = cleaned.ends_with?("R5900")
      inc = cleaned.includes?("Engine")
      not_inc = cleaned.includes?("CellBroadband")

      c1 = (cleaned == "Emotion Engine R5900")
      c2 = (upper == "EMOTION ENGINE R5900")
      c3 = (lower == "emotion engine r5900")
      c4 = (len_clean == 20) && (len_orig == 24)
      c5 = sw && ew && inc && (!not_inc)

      if c1 && c2 && c3 && c4 && c5
        debug_puts "[CITRINE TEST] Strings#queries_and_transforms: PASS"
      else
        debug_puts "[CITRINE TEST] Strings#queries_and_transforms: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Strings#queries_and_transforms: PASS")
  end

  it "verifies bitwise logic, shifts, and bitmask packing on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("bitwise_logic_and_packing_test")
    tc.source(<<-CR
      # 1. 16-bit RGB 5:5:5 packing
      r = 31 # 5 bits max
      g = 15 # 5 bits
      b = 7  # 5 bits
      packed_rgb = (r << 10) | (g << 5) | b

      # Unpack and verify
      unpacked_r = (packed_rgb >> 10) & 0x1F
      unpacked_g = (packed_rgb >> 5) & 0x1F
      unpacked_b = packed_rgb & 0x1F

      # 2. Bitwise operations & XOR swap logic
      val_a = 0xA5 # 10100101
      val_b = 0x5A # 01011010
      b_and = val_a & val_b # 0x00
      b_or  = val_a | val_b # 0xFF (255)
      b_xor = val_a ^ val_b # 0xFF (255)

      # 3. Shift bit multipliers
      shl_val = 3 << 4 # 3 * 16 = 48
      shr_val = 128 >> 3 # 128 / 8 = 16

      rgb_ok = (unpacked_r == 31) && (unpacked_g == 15) && (unpacked_b == 7)
      bit_ok = (b_and == 0) && (b_or == 255) && (b_xor == 255)
      shift_ok = (shl_val == 48) && (shr_val == 16)

      if rgb_ok && bit_ok && shift_ok
        debug_puts "[CITRINE TEST] Bitwise#logic_and_shifts: PASS"
      else
        debug_puts "[CITRINE TEST] Bitwise#logic_and_shifts: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Bitwise#logic_and_shifts: PASS")
  end

  it "verifies arithmetic operator precedence, grouping, and negative numbers on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arithmetic_precedence_test")
    tc.source(<<-CR
      # Standard precedence: * and // precede + and -
      r1 = 10 + 5 * 4 - 20 // 4
      # 10 + 20 - 5 = 25

      # Parenthesized grouping
      r2 = (10 + 5) * (4 - 2) // 3
      # 15 * 2 // 3 = 30 // 3 = 10

      # Modulus operation
      r3 = 100 % 37
      # 100 - (2 * 37 = 74) = 26

      # Negative arithmetic
      neg = -50
      r4 = neg + 120 - (-30)
      # -50 + 120 + 30 = 100

      if r1 == 25 && r2 == 10 && r3 == 26 && r4 == 100
        debug_puts "[CITRINE TEST] Math#precedence_and_negatives: PASS"
      else
        debug_puts "[CITRINE TEST] Math#precedence_and_negatives: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Math#precedence_and_negatives: PASS")
  end

  it "verifies compound in-place assignment operators on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("compound_assignments_test")
    tc.source(<<-CR
      acc = 100
      acc += 50   # 150
      acc -= 30   # 120
      acc *= 3    # 360
      acc //= 4   # 90
      acc %= 25   # 15
      acc &= 0x0F # 15 & 15 = 15
      acc |= 0x10 # 15 | 16 = 31
      acc ^= 0x01 # 31 ^ 1 = 30
      acc <<= 2   # 30 * 4 = 120
      acc >>= 1   # 120 / 2 = 60

      if acc == 60
        debug_puts "[CITRINE TEST] Math#compound_assignments: PASS"
      else
        debug_puts "[CITRINE TEST] Math#compound_assignments: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Math#compound_assignments: PASS")
  end

  it "verifies dynamic string comparisons and empty string checks on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("strings_comparisons_and_empty_test")
    tc.source(<<-CR
      str1 = "GraphicsSynthesizer"
      str2 = "Graphics" + "Synthesizer"
      str3 = "EmotionEngine"
      empty_str = ""

      eq_test = (str1 == str2)
      ne_test = (str1 != str3)
      empty_size = (empty_str.size == 0)

      if eq_test && ne_test && empty_size
        debug_puts "[CITRINE TEST] Strings#comparisons_and_empty: PASS"
      else
        debug_puts "[CITRINE TEST] Strings#comparisons_and_empty: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Strings#comparisons_and_empty: PASS")
  end
end
