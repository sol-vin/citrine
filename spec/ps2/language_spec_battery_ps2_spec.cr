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

      # --- Section 22: Recursive Algorithm & Binary Search ---
      def s22_binary_search(arr, target)
        low = 0
        high = arr.size - 1
        found_idx = -1
        while low <= high
          mid = (low + high) / 2
          v = arr[mid]
          if v == target
            found_idx = mid
            break
          elsif v < target
            low = mid + 1
          else
            high = mid - 1
          end
        end
        found_idx
      end
      s22_data = [10, 25, 33, 47, 52, 68, 79, 84, 91, 105]
      b_idx = s22_binary_search(s22_data, 52)
      Test.assert(b_idx == 4, "S22: Binary Search")

      # --- Section 23: 4-Level Deep Polymorphic Hierarchy ---
      class S23Root
        def level
          1
        end
      end
      class S23L2 < S23Root
        def level
          super + 1
        end
      end
      class S23L3 < S23L2
        def level
          super + 1
        end
      end
      class S23Leaf < S23L3
        def level
          super * 2
        end
      end
      s23_inst = S23Leaf.new
      Test.assert(s23_inst.level == 6, "S23: Deep Polymorphism")

      # --- Section 24: String Manipulation Matrix ---
      s24_str = "PlayStation2"
      s24_up = s24_str.upcase
      s24_down = s24_str.downcase
      s24_has = s24_str.includes?("Station")
      Test.assert(s24_has && s24_up == "PLAYSTATION2" && s24_down == "playstation2", "S24: String Manipulation")

      # --- Section 25: In-Place Sort Algorithm & Dynamic Swapping ---
      def s25_sort(arr)
        n = arr.size
        i = 0
        while i < n
          j = 0
          while j < n - 1
            if arr[j] > arr[j + 1]
              temp = arr[j]
              arr[j] = arr[j + 1]
              arr[j + 1] = temp
            end
            j += 1
          end
          i += 1
        end
        arr
      end
      s25_data = [45, 12, 89, 23, 7]
      s25_sorted = s25_sort(s25_data)
      Test.assert(s25_sorted[0] == 7 && s25_sorted[1] == 12 && s25_sorted[4] == 89, "S25: In-Place Sort")

      # --- Section 26: StaticArray Matrix Math ---
      mat = StaticArray(Int32, 4).new(0)
      mat[0] = 1
      mat[1] = 2
      mat[2] = 3
      mat[3] = 4
      trace = mat[0] + mat[3]
      det = (mat[0] * mat[3]) - (mat[1] * mat[2])
      Test.assert(trace == 5 && det == -2, "S26: StaticArray Matrix")

      # --- Section 27: Multi-Nested Ternary & Logic ---
      def s27_logic(val)
        val > 100 ? (val > 200 ? 3 : 2) : (val > 50 ? 1 : 0)
      end
      Test.assert(s27_logic(250) == 3 && s27_logic(150) == 2 && s27_logic(75) == 1 && s27_logic(20) == 0, "S27: Nested Ternary Logic")

      # --- Section 28: Bitfield Packing & RGBA32 Unpacking ---
      def s28_pack(r, g, b, a)
        (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24)
      end
      def s28_unpack_r(color)
        color & 0xFF
      end
      def s28_unpack_g(color)
        (color >> 8) & 0xFF
      end
      def s28_unpack_b(color)
        (color >> 16) & 0xFF
      end
      def s28_unpack_a(color)
        (color >> 24) & 0xFF
      end
      s28_col = s28_pack(12, 34, 56, 78)
      Test.assert(s28_unpack_r(s28_col) == 12 && s28_unpack_g(s28_col) == 34 && s28_unpack_b(s28_col) == 56 && s28_unpack_a(s28_col) == 78, "S28: Bitfield Packing")

      # --- Section 29: Nested Struct Pass-By-Value Immutability ---
      struct S29Color
        property r : Int32
        property g : Int32
        def initialize(@r, @g)
        end
      end
      s29_c1 = S29Color.new(100, 200)
      s29_c2 = s29_c1
      s29_c2.r = 255
      Test.assert(s29_c1.r == 100 && s29_c2.r == 255, "S29: Struct Immutability")

      # --- Section 30: Finite State Machine & Enum Transitions ---
      fsm_state = 0
      ticks = 0
      while ticks < 10
        ticks += 1
        case fsm_state
        when 0
          fsm_state = 1
        when 1
          fsm_state = 2
        when 2
          fsm_state = 3
        when 3
          break
        end
      end
      Test.assert(fsm_state == 3 && ticks == 4, "S30: State Machine & Transitions")
    CR
    )
    result = tc.run_and_verify(timeout: 12.seconds)
    result.should_have_no_memory_leaks
    result.should_not_have_memory_faults

    # Multi-step pass assertions: verify all 30 sections passed on console
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
      "S21: Inline Assembly",
      "S22: Binary Search",
      "S23: Deep Polymorphism",
      "S24: String Manipulation",
      "S25: In-Place Sort",
      "S26: StaticArray Matrix",
      "S27: Nested Ternary Logic",
      "S28: Bitfield Packing",
      "S29: Struct Immutability",
      "S30: State Machine & Transitions"
    )
  end
end
