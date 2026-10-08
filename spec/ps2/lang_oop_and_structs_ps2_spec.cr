require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: OOP, Structs & Typing" do
  it "verifies multi-tier inheritance and super delegation with argument transformation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("oop_multitier_super_test")
    tc.source(<<-CR
      class Tier1
        property name : String
        def initialize(@name)
        end

        def calculate_score(base : Int32)
          base + 10
        end
      end

      class Tier2 < Tier1
        property rank : Int32
        def initialize(@rank, name : String)
          super(name)
        end

        def calculate_score(base : Int32)
          # Tier2 multiplies base by rank, then delegates to Tier1
          super(base * @rank)
        end
      end

      class Tier3 < Tier2
        property title : String
        def initialize(@title, rank : Int32, name : String)
          super(rank, name)
        end

        def calculate_score(base : Int32)
          # Tier3 adds 5 to base, then delegates to Tier2
          super(base + 5)
        end
      end

      obj = Tier3.new("Archon", 3, "Kassadin")
      t_name = obj.name
      t_rank = obj.rank
      t_title = obj.title

      # calculate_score(10):
      # Tier3: super(10 + 5 = 15)
      # Tier2: super(15 * 3 = 45)
      # Tier1: 45 + 10 = 55
      score = obj.calculate_score(10)

      if t_name == "Kassadin" && t_rank == 3 && t_title == "Archon" && score == 55
        debug_puts "[CITRINE TEST] OOP#multitier_super_delegation: PASS"
      else
        debug_puts "[CITRINE TEST] OOP#multitier_super_delegation: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] OOP#multitier_super_delegation: PASS")
  end

  it "verifies struct value copy semantics vs class reference semantics on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("oop_struct_value_vs_class_ref_test")
    tc.source(<<-CR
      struct ValuePoint
        property x : Int32
        property y : Int32
        def initialize(@x, @y)
        end
      end

      class RefPoint
        property x : Int32
        property y : Int32
        def initialize(@x, @y)
        end
      end

      # 1. Struct value semantics: copying should duplicate values
      sp1 = ValuePoint.new(10, 20)
      sp2 = sp1
      sp2.x = 99

      # sp1.x should still be 10, sp2.x should be 99
      struct_ok = (sp1.x == 10) && (sp2.x == 99)

      # 2. Class reference semantics: copying reference aliases object
      rp1 = RefPoint.new(10, 20)
      rp2 = rp1
      rp2.x = 99

      # both rp1.x and rp2.x should be 99
      class_ok = (rp1.x == 99) && (rp2.x == 99)

      if struct_ok && class_ok
        debug_puts "[CITRINE TEST] OOP#struct_value_vs_class_ref: PASS"
      else
        debug_puts "[CITRINE TEST] OOP#struct_value_vs_class_ref: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] OOP#struct_value_vs_class_ref: PASS")
  end

  it "verifies dynamic type queries is_a?, as, and as? on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("oop_type_queries_test")
    tc.source(<<-CR
      class Animal
        property name : String
        def initialize(@name)
        end
      end

      class Canine < Animal
        def bark
          "WOOF"
        end
      end

      class Feline < Animal
        def purr
          "PURR"
        end
      end

      d = Canine.new("Rex")
      c = Feline.new("Whiskers")

      # is_a? checks
      d_is_canine = d.is_a?(Canine)
      d_is_animal = d.is_a?(Animal)
      d_is_feline = d.is_a?(Feline)

      # as cast
      a_ref = d.as(Animal)
      cast_ok = a_ref.name == "Rex"

      if d_is_canine && d_is_animal && (!d_is_feline) && cast_ok
        debug_puts "[CITRINE TEST] OOP#type_queries_and_casts: PASS"
      else
        debug_puts "[CITRINE TEST] OOP#type_queries_and_casts: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] OOP#type_queries_and_casts: PASS")
  end

  it "verifies responds_to? dynamic method introspection on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("oop_responds_to_test")
    tc.source(<<-CR
      class Flyer
        def fly
          100
        end
      end

      class Walker
        def walk
          50
        end
      end

      f = Flyer.new
      w = Walker.new

      f_fly = f.responds_to?(:fly)
      f_walk = f.responds_to?(:walk)
      w_fly = w.responds_to?(:fly)
      w_walk = w.responds_to?(:walk)

      if f_fly && (!f_walk) && (!w_fly) && w_walk
        debug_puts "[CITRINE TEST] OOP#responds_to_introspection: PASS"
      else
        debug_puts "[CITRINE TEST] OOP#responds_to_introspection: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] OOP#responds_to_introspection: PASS")
  end

  it "verifies is_a? polymorphic Union type checks on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("oop_union_types_test")
    tc.source(<<-CR
      class Hero
        property name : String
        def initialize(@name)
        end
      end

      class Monster
        property power : Int32
        def initialize(@power)
        end
      end

      class Item
        property cost : Int32
        def initialize(@cost)
        end
      end

      h = Hero.new("Arthur")
      m = Monster.new(9000)
      i = Item.new(50)

      # Test Union type checks: (Hero | Monster)
      h_is_combatant = h.is_a?(Hero | Monster)
      m_is_combatant = m.is_a?(Hero | Monster)
      i_is_combatant = i.is_a?(Hero | Monster)

      if h_is_combatant && m_is_combatant && (!i_is_combatant)
        debug_puts "[CITRINE TEST] OOP#union_type_checks: PASS"
      else
        debug_puts "[CITRINE TEST] OOP#union_type_checks: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] OOP#union_type_checks: PASS")
  end

  it "verifies class-struct composition and mutable property delegation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("oop_composition_test")
    tc.source(<<-CR
      struct Transform
        property x : Int32
        property y : Int32
        def initialize(@x, @y)
        end
      end

      class Entity
        property name : String
        property pos : Transform

        def initialize(@name, @pos)
        end

        def move(dx : Int32, dy : Int32)
          @pos.x = @pos.x + dx
          @pos.y = @pos.y + dy
        end
      end

      e = Entity.new("Player", Transform.new(100, 200))
      init_x = e.pos.x
      init_y = e.pos.y

      e.move(15, -25)
      after_x = e.pos.x
      after_y = e.pos.y

      if init_x == 100 && init_y == 200 && after_x == 115 && after_y == 175
        debug_puts "[CITRINE TEST] OOP#composition_and_delegation: PASS"
      else
        debug_puts "[CITRINE TEST] OOP#composition_and_delegation: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] OOP#composition_and_delegation: PASS")
  end
end

