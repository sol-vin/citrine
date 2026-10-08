require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Deep Types, Boxing & Polymorphism" do
  it "verifies Box(T).box and Box(T).unbox with primitive types on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("types_box_unbox_primitives_test")
    tc.source(<<-CR
      # 1. Box an Int32
      orig_int = 12345
      boxed_int = Box(Int32).box(orig_int)
      unboxed_int = Box(Int32).unbox(boxed_int)

      # 2. Box a String
      orig_str = "CITRINE_BOX"
      boxed_str = Box(String).box(orig_str)
      unboxed_str = Box(String).unbox(boxed_str)

      # 3. Box a Bool
      orig_bool = true
      boxed_bool = Box(Bool).box(orig_bool)
      unboxed_bool = Box(Bool).unbox(boxed_bool)

      int_ok = (unboxed_int == 12345)
      str_ok = (unboxed_str == "CITRINE_BOX")
      bool_ok = (unboxed_bool == true)

      if int_ok && str_ok && bool_ok
        debug_puts "[CITRINE TEST] DeepTypes#box_unbox_primitives: PASS"
      else
        debug_puts "[CITRINE TEST] DeepTypes#box_unbox_primitives: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepTypes#box_unbox_primitives: PASS")
  end

  it "verifies Box(T).box and Box(T).unbox with complex classes and cross-function pointer passing on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("types_box_unbox_classes_test")
    tc.source(<<-CR
      class GameActor
        property id : Int32
        property name : String
        property hp : Int32

        def initialize(@id, @name, @hp)
        end
      end

      def damage_actor_via_box(raw_box_ptr) : Int32
        # Unbox actor instance from raw pointer
        actor = Box(GameActor).unbox(raw_box_ptr)
        actor.hp = actor.hp - 100
        actor.hp
      end

      actor = GameActor.new(42, "Cloud", 999)
      boxed = Box(GameActor).box(actor)

      # Pass boxed pointer to function and mutate internal state
      remaining_hp = damage_actor_via_box(boxed)
      orig_actor_hp = actor.hp

      # Unbox again in main scope to verify reference preservation
      unboxed_again = Box(GameActor).unbox(boxed)
      actor_name = unboxed_again.name
      actor_id = unboxed_again.id

      if remaining_hp == 899 && orig_actor_hp == 899 && actor_name == "Cloud" && actor_id == 42
        debug_puts "[CITRINE TEST] DeepTypes#box_unbox_classes_and_passing: PASS"
      else
        debug_puts "[CITRINE TEST] DeepTypes#box_unbox_classes_and_passing: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepTypes#box_unbox_classes_and_passing: PASS")
  end

  it "verifies storing an array of boxed pointers, iterating, and unboxing in a loop on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("types_boxed_array_loop_test")
    tc.source(<<-CR
      # Allocate array containing boxed pointers
      boxes = [
        Box(Int32).box(10),
        Box(Int32).box(20),
        Box(Int32).box(30)
      ]

      # Dynamically append more boxed pointers
      boxes << Box(Int32).box(40)
      boxes << Box(Int32).box(50)

      sz = boxes.size

      # Iterate and unbox each element, accumulating the sum
      sum = 0
      idx = 0
      while idx < boxes.size
        unboxed_val = Box(Int32).unbox(boxes[idx])
        sum = sum + unboxed_val
        idx = idx + 1
      end

      # Sum = 10 + 20 + 30 + 40 + 50 = 150
      if sz == 5 && sum == 150
        debug_puts "[CITRINE TEST] DeepTypes#boxed_array_iteration: PASS"
      else
        debug_puts "[CITRINE TEST] DeepTypes#boxed_array_iteration: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepTypes#boxed_array_iteration: PASS")
  end

  it "verifies is_a? and as across a 4-tier class inheritance hierarchy and sibling discrimination on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("types_4tier_inheritance_test")
    tc.source(<<-CR
      class Entity
        property id : Int32
        def initialize(@id)
        end
      end

      class Actor < Entity
        property name : String
        def initialize(@name, id : Int32)
          super(id)
        end
      end

      class Character < Actor
        property hp : Int32
        def initialize(@hp, name : String, id : Int32)
          super(name, id)
        end
      end

      class PlayerCharacter < Character
        property level : Int32
        def initialize(@level, hp : Int32, name : String, id : Int32)
          super(hp, name, id)
        end
      end

      class EnemyCharacter < Character
        property weapon : String
        def initialize(@weapon, hp : Int32, name : String, id : Int32)
          super(hp, name, id)
        end
      end

      pc = PlayerCharacter.new(99, 500, "Noctis", 1)
      ec = EnemyCharacter.new("Dagger", 80, "Goblin", 2)

      # 4-tier inheritance type queries on PlayerCharacter
      pc_is_pc = pc.is_a?(PlayerCharacter)
      pc_is_char = pc.is_a?(Character)
      pc_is_actor = pc.is_a?(Actor)
      pc_is_entity = pc.is_a?(Entity)
      pc_is_enemy = pc.is_a?(EnemyCharacter) # sibling: should be false

      # Sibling type queries on EnemyCharacter
      ec_is_enemy = ec.is_a?(EnemyCharacter)
      ec_is_char = ec.is_a?(Character)
      ec_is_pc = ec.is_a?(PlayerCharacter) # sibling: should be false

      # Polymorphic casting up the hierarchy
      as_char = pc.as(Character)
      c_name = as_char.name
      c_hp = as_char.hp

      as_ent = ec.as(Entity)
      e_id = as_ent.id

      hierarchy_ok = pc_is_pc && pc_is_char && pc_is_actor && pc_is_entity && (!pc_is_enemy)
      sibling_ok = ec_is_enemy && ec_is_char && (!ec_is_pc)
      cast_ok = (c_name == "Noctis") && (c_hp == 500) && (e_id == 2)

      if hierarchy_ok && sibling_ok && cast_ok
        debug_puts "[CITRINE TEST] DeepTypes#four_tier_hierarchy_and_casts: PASS"
      else
        debug_puts "[CITRINE TEST] DeepTypes#four_tier_hierarchy_and_casts: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepTypes#four_tier_hierarchy_and_casts: PASS")
  end

  it "verifies polymorphic method dispatch on an array of base-class instances on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("types_polymorphic_dispatch_test")
    tc.source(<<-CR
      class Shape
        property color : String
        def initialize(@color)
        end

        def area : Int32
          0
        end
      end

      class Rectangle < Shape
        property width : Int32
        property height : Int32
        def initialize(@width, @height, color : String)
          super(color)
        end

        def area : Int32
          @width * @height
        end
      end

      class Circle < Shape
        property radius : Int32
        def initialize(@radius, color : String)
          super(color)
        end

        def area : Int32
          # 3 * r^2 approximation
          3 * @radius * @radius
        end
      end

      class Triangle < Shape
        property base_len : Int32
        property height : Int32
        def initialize(@base_len, @height, color : String)
          super(color)
        end

        def area : Int32
          (@base_len * @height) // 2
        end
      end

      r = Rectangle.new(4, 5, "Red")
      c = Circle.new(3, "Blue")
      t = Triangle.new(6, 4, "Green")

      # Expected areas:
      # Rectangle: 4 * 5 = 20
      # Circle: 3 * 3^2 = 27
      # Triangle: (6 * 4) / 2 = 12
      a0 = r.area
      a1 = c.area
      a2 = t.area

      shapes = [r.as(Shape), c.as(Shape), t.as(Shape)]
      s0 = shapes[0].as(Rectangle).area
      s1 = shapes[1].as(Circle).area
      s2 = shapes[2].as(Triangle).area
      total_area = s0 + s1 + s2

      if a0 == 20 && a1 == 27 && a2 == 12 && s0 == 20 && s1 == 27 && s2 == 12 && total_area == 59
        debug_puts "[CITRINE TEST] DeepTypes#polymorphic_method_dispatch: PASS"
      else
        debug_puts "[CITRINE TEST] DeepTypes#polymorphic_method_dispatch: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepTypes#polymorphic_method_dispatch: PASS")
  end


  it "verifies nil checks, union types, and nilable casting on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("types_nil_union_checks_test")
    tc.source(<<-CR
      class Weapon
        property name : String
        def initialize(@name)
        end
      end

      class Shield
        property defense : Int32
        def initialize(@defense)
        end
      end

      w = Weapon.new("BusterSword")
      s = Shield.new(50)

      # Union is_a? checks
      w_is_gear = w.is_a?(Weapon | Shield)
      s_is_gear = s.is_a?(Weapon | Shield)
      w_is_shield = w.is_a?(Shield)

      # Nil checks
      val_nil = nil
      val_not_nil = 42

      is_nil1 = val_nil.is_a?(Nil)
      is_nil2 = val_not_nil.is_a?(Nil)

      union_ok = w_is_gear && s_is_gear && (!w_is_shield)
      nil_ok = is_nil1 && (!is_nil2)

      if union_ok && nil_ok
        debug_puts "[CITRINE TEST] DeepTypes#nil_and_union_type_checks: PASS"
      else
        debug_puts "[CITRINE TEST] DeepTypes#nil_and_union_type_checks: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepTypes#nil_and_union_type_checks: PASS")
  end
end
