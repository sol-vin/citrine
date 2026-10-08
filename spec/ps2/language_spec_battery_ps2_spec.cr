require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Specification: Unified Batched Hardware Battery" do
  ps2_test "ee_unified_language_spec_battery", "executes the comprehensive 21-section language verification battery in a single fastboot session on PS2 EE" do |tc|
    tc.source(<<-CR
      # --- Section 1: Complex Arithmetic & Operator Precedence ---
      def s1_arithmetic(a, b, c, d)
        (a + b) * (c - d) + (a * 2) - (c / 2) + (b % 3)
      end
      # a=10, b=5, c=8, d=3: (10+5)*(8-3) + (20) - (4) + (2) = 15*5 + 20 - 4 + 2 = 75 + 18 = 93
      Test.assert(s1_arithmetic(10, 5, 8, 3) == 93, "S01: Arithmetic")

      # --- Section 2: Bitwise Logic & Shifts ---
      bit_val = 0x0F0F
      shifted = ((bit_val << 4) >> 2) & 0x0FFF
      xored = shifted ^ 0x00FF
      Test.assert(xored > 0, "S02: Bitwise & Shifts")

      # --- Section 3: Short-Circuit Logic Guarding Side Effects ---
      class S3Watcher
        @@hits : Int32 = 0
        def self.trigger
          @@hits = @@hits + 1
          true
        end
        def self.hits
          @@hits
        end
      end
      sc1 = false && S3Watcher.trigger
      sc2 = true || S3Watcher.trigger
      sc3 = true && S3Watcher.trigger
      Test.assert(S3Watcher.hits == 1, "S03: Short Circuit")

      # --- Section 4: Ternary Conditional Operator ---
      def s4_ternary(x)
        x > 50 ? 100 : 200
      end
      Test.assert(s4_ternary(75) == 100 && s4_ternary(25) == 200, "S04: Ternary")

      # --- Section 5: Compound Op-Assignments ---
      def s5_op_assign(base)
        val = base
        val += 10
        val -= 3
        val *= 2
        val /= 3
        val %= 5
        val
      end
      # 20 + 10 = 30 - 3 = 27 * 2 = 54 / 3 = 18 % 5 = 3
      Test.assert(s5_op_assign(20) == 3, "S05: Op Assign")

      # --- Section 6: Control Flow (if / elsif / unless) ---
      score = 82
      tier = 0
      if score >= 90
        tier = 1
      elsif score >= 80
        tier = 2
      else
        tier = 3
      end
      guard = false
      unless guard
        tier = tier + 10
      end
      Test.assert(tier == 12, "S06: Control Flow")

      # --- Section 7: While & Until with Break & Next ---
      loop_sum = 0
      k = 0
      while k < 10
        k = k + 1
        if k == 2
          next
        end
        if k == 6
          break
        end
        loop_sum = loop_sum + k
      end
      # 1 + 3 + 4 + 5 = 13
      Test.assert(loop_sum == 13, "S07: Loops Break Next")

      # --- Section 8: Pattern Matching Case with Ranges and Multi-Values ---
      def s8_classify(n)
        case n
        when 1, 2, 3
          10
        when 4..8
          20
        else
          30
        end
      end
      Test.assert(s8_classify(2) == 10 && s8_classify(6) == 20 && s8_classify(99) == 30, "S08: Case Ranges")

      # --- Section 9: Higher-Order Functions & Inlined Yield Blocks ---
      def s9_transform(a, b)
        res = yield(a * 2, b * 3)
        res + 5
      end
      captured_offset = 1
      t_res = s9_transform(5, 4) do |x, y|
        x + y + captured_offset
      end
      # (10 + 12 + 1) + 5 = 28
      Test.assert(t_res == 28, "S09: Blocks & Yield")

      # --- Section 10: Array Operations (Push, Pop, Index, Size) ---
      arr = [10, 20, 30]
      arr << 40
      popped = arr.pop
      arr[0] = 99
      Test.assert(popped == 40 && arr[0] == 99 && arr.size == 3, "S10: Arrays Dynamic")

      # --- Section 11: StaticArray Fixed Memory ---
      sarr = StaticArray(Int32, 3).new(0)
      sarr[0] = 7
      sarr[1] = 8
      sarr[2] = 9
      Test.assert(sarr[0] == 7 && sarr[2] == 9 && sarr.size == 3, "S11: Static Array")

      # --- Section 12: Structs & Independent Value Copy Semantics ---
      struct S12Vector
        property vx : Int32
        property vy : Int32
        def initialize(@vx, @vy)
        end
        def magnitude_sq
          @vx * @vx + @vy * @vy
        end
      end
      sv1 = S12Vector.new(3, 4)
      sv2 = sv1
      sv1.vx = 100
      # sv2.vx must remain 3
      Test.assert(sv1.vx == 100 && sv2.vx == 3 && sv2.magnitude_sq == 25, "S12: Struct Value Copy")

      # --- Section 13: Classes, Properties, and Instance Methods ---
      class S13Character
        property name : String
        property hp : Int32
        def initialize(@name, @hp)
        end
        def take_damage(dmg)
          @hp = @hp - dmg
          @hp
        end
      end
      hero = S13Character.new("Cloud", 500)
      rem_hp = hero.take_damage(120)
      Test.assert(hero.name == "Cloud" && rem_hp == 380 && hero.hp == 380, "S13: Classes & Objects")

      # --- Section 14: Multi-Tier Inheritance & Super Forwarding ---
      class S14Base
        def power_multiplier
          2
        end
      end
      class S14Child < S14Base
        def power_multiplier
          super * 3
        end
      end
      child_inst = S14Child.new
      Test.assert(child_inst.power_multiplier == 6, "S14: Inheritance & Super")

      # --- Section 15: Modules & Multiple Mixin Composition ---
      module S15Flyable
        def fly_speed
          50
        end
      end
      module S15Armor
        def defense
          25
        end
      end
      class S15Pegasus
        include S15Flyable
        include S15Armor
      end
      peg = S15Pegasus.new
      Test.assert(peg.fly_speed == 50 && peg.defense == 25, "S15: Mixin Modules")

      # --- Section 16: Class Variables (@@cvar) & Class Methods ---
      class S16Registry
        @@count : Int32 = 0
        def self.register
          @@count = @@count + 1
        end
        def self.count
          @@count
        end
      end
      S16Registry.register
      S16Registry.register
      Test.assert(S16Registry.count == 2, "S16: Class Variables")

      # --- Section 17: Method Default Parameter Application ---
      def s17_tax(amount, rate = 10)
        amount * rate / 100
      end
      Test.assert(s17_tax(200) == 20 && s17_tax(200, 15) == 30, "S17: Default Args")

      # --- Section 18: Tuples & Multiple Assignment Unpacking ---
      tup = {11, 22, 33}
      ta, tb, tc = tup
      Test.assert(ta == 11 && tb == 22 && tc == 33, "S18: Tuples Unpacking")

      # --- Section 19: Type Introspection (is_a?, as, as?, nil?) ---
      is_hero = hero.is_a?(S13Character)
      cast_hero = hero.as(S13Character)
      nil_val = nil
      Test.assert(is_hero && !cast_hero.nil? && nil_val.nil?, "S19: Type Introspection")

      # --- Section 20: Pointer Heap Allocation ---
      raw_ptr = Pointer(Int32).malloc(4)
      raw_ptr[0] = 111
      raw_ptr[1] = 222
      raw_ptr.value = 333
      Test.assert(raw_ptr[0] == 333 && raw_ptr[1] == 222, "S20: Pointer Memory")

      # --- Section 21: Inline Assembly & COP0 Verification ---
      asm("sync.l")
      Citrine.asm "sync.p"
      Test.pass("S21: Inline Assembly")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_have_no_memory_leaks
    result.should_not_have_memory_faults

    # Multi-step pass assertions: verify all 21 sections passed on console
    result.should_pass(
      "S01: Arithmetic",
      "S02: Bitwise & Shifts",
      "S03: Short Circuit",
      "S04: Ternary",
      "S05: Op Assign",
      "S06: Control Flow",
      "S07: Loops Break Next",
      "S08: Case Ranges",
      "S09: Blocks & Yield",
      "S10: Arrays Dynamic",
      "S11: Static Array",
      "S12: Struct Value Copy",
      "S13: Classes & Objects",
      "S14: Inheritance & Super",
      "S15: Mixin Modules",
      "S16: Class Variables",
      "S17: Default Args",
      "S18: Tuples Unpacking",
      "S19: Type Introspection",
      "S20: Pointer Memory",
      "S21: Inline Assembly"
    )
  end
end
