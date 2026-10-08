require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Cross-Feature Synergies Suite" do
  ps2_test "cross_abstract_mixin_super_blocks_test", "verifies abstract classes, mixins, multi-tier super, and block closures working together on PS2" do |tc|
    tc.source(<<-CR
      module Enchantable
        def enchantment_factor
          3
        end
        def prefix_title(title : String)
          "[ENCHANTED] " + title
        end
      end

      abstract class CombatEntity
        property name : String
        property base_stat : Int32

        def initialize(@name, @base_stat)
        end

        def scale_stat(mult : Int32)
          @base_stat * mult
        end
      end

      class Spellcaster < CombatEntity
        include Enchantable

        property mana : Int32

        def initialize(@mana, name, base_stat)
          super(name, base_stat)
        end

        def scale_stat(mult : Int32)
          # Call super, then multiply by mixin enchantment factor
          base_scaled = super(mult)
          base_scaled * enchantment_factor
        end

        def cast_spell(power : Int32)
          # Yield scaled power to caller block
          total = scale_stat(power)
          yield(total)
        end
      end

      mage = Spellcaster.new(200, "Merlin", 10)

      # 1. Properties and mixins
      Test.assert(mage.name == "Merlin" && mage.mana == 200 && mage.base_stat == 10, "Multi-tier properties initialized")

      # 2. Scale stat: base_stat(10) * mult(2) = 20 * enchantment_factor(3) = 60
      scaled = mage.scale_stat(2)
      Test.assert(scaled == 60, "Super + mixin combination scaled == 60")

      # 3. Method with block & closure capturing outer variable
      outer_boost = 15
      spell_res = mage.cast_spell(2) do |dmg|
        dmg + outer_boost
      end
      # 60 + 15 = 75
      Test.assert(spell_res == 75, "Block closure with outer variable == 75")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_pass("Multi-tier properties initialized")
    result.should_pass("Super + mixin combination scaled == 60")
    result.should_pass("Block closure with outer variable == 75")
  end

  ps2_test "cross_structs_arrays_classes_test", "verifies struct value copy semantics with local variables and collections on PS2" do |tc|
    tc.source(<<-CR
      struct Transform2D
        property x : Int32
        property y : Int32

        def initialize(@x, @y)
        end

        def offset(dx, dy)
          @x = @x + dx
          @y = @y + dy
          @x + @y
        end
      end

      # 1. Local variable assignment copies struct by value
      t1 = Transform2D.new(10, 20)
      t2 = t1
      t2.x = 999
      Test.assert(t1.x == 10 && t2.x == 999, "Struct pass-by-value independent of original")

      # 2. Struct methods and state
      t3 = Transform2D.new(10, 20)
      res = t3.offset(5, 10)
      # t3.x = 10 + 5 = 15, t3.y = 20 + 10 = 30, res = 45
      Test.assert(res == 45 && t3.x == 15 && t3.y == 30, "Struct mutated via method")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_pass("Struct pass-by-value independent of original")
    result.should_pass("Struct mutated via method")
  end

  ps2_test "cross_case_ranges_nested_loops_test", "verifies complex case/when with ranges, unions, and multi-values inside nested loops on PS2" do |tc|
    tc.source(<<-CR
      def categorize_score(val : Int32)
        case val
        when 0..5
          1
        when 6..10
          2
        when 11, 13, 17, 19
          3
        else
          9
        end
      end

      score_pool = [3, 8, 13, 25]
      total_categories = 0

      score_pool.each do |s|
        cat = categorize_score(s)
        total_categories = total_categories + cat
      end

      # 3 in 0..5 -> 1
      # 8 in 6..10 -> 2
      # 13 in 11, 13, 17, 19 -> 3
      # 25 in else -> 9
      # Sum = 1 + 2 + 3 + 9 = 15
      Test.assert(total_categories == 15, "Case range and multi-match in collection loop == 15")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_pass("Case range and multi-match in collection loop == 15")
  end
end
