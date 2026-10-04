require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Comprehensive Language Features" do
  it "verifies modules, mixins, multi-include, extend, and module constants on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_modules_and_mixins_test")
    tc.source(<<-CR
      module Identifiable
        def identify
          "[ID] #"
        end
      end

      module Boostable
        def boost_factor
          3
        end
      end

      module MathConsts
        PI = 3
        TAU = 6
        def self.calc_tau(r : Int32)
          TAU * r
        end
      end

      module ClassLevelHelpers
        def make_default_score
          100
        end
      end

      class GameEntity
        include Identifiable
        include Boostable
        extend ClassLevelHelpers

        property name : String
        property base_power : Int32

        def initialize(@name, @base_power)
        end

        def total_power
          @base_power * boost_factor
        end
      end

      debug_puts "[CITRINE TEST] Modules & Mixins EE Init"

      # 1. Multi-include methods
      ent = GameEntity.new("Titan", 50)
      if ent.identify == "[ID] #"
        debug_puts "[CITRINE TEST] Mixin Identifiable#identify: PASS"
      end

      if ent.total_power == 150
        debug_puts "[CITRINE TEST] Mixin Boostable#boost_factor combined: PASS"
      end

      # 2. Extend on class
      default_score = GameEntity.make_default_score
      if default_score == 100
        debug_puts "[CITRINE TEST] Extend ClassLevelHelpers.make_default_score == 100: PASS"
      end

      # 3. Direct module methods and constants
      tau_res = MathConsts.calc_tau(5)
      if tau_res == 30
        debug_puts "[CITRINE TEST] MathConsts.calc_tau(5) == 30: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Mixin Identifiable#identify: PASS")
    result.should_have_output("[CITRINE TEST] Mixin Boostable#boost_factor combined: PASS")
    result.should_have_output("[CITRINE TEST] Extend ClassLevelHelpers.make_default_score == 100: PASS")
    result.should_have_output("[CITRINE TEST] MathConsts.calc_tau(5) == 30: PASS")
  end

  it "verifies multi-tier inheritance, super in initialize, super in overriding methods, and properties on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_inheritance_and_super_test")
    tc.source(<<-CR
      class Grandparent
        property realm : String

        def initialize(@realm)
        end

        def scale_stat(val : Int32)
          val + 10
        end
      end

      class Parent < Grandparent
        property family : String

        def initialize(@family, realm : String)
          super(realm)
        end

        def scale_stat(val : Int32)
          super(val * 2)
        end
      end

      class Child < Parent
        property name : String
        property level : Int32

        def initialize(@name, @level, family : String, realm : String)
          super(family, realm)
        end

        def scale_stat(val : Int32)
          super(val + 5)
        end
      end

      debug_puts "[CITRINE TEST] Multi-Tier Inheritance EE Init"

      c = Child.new("Aragorn", 99, "Dunedain", "MiddleEarth")

      # 1. Multi-tier field initialization via chained super
      if c.name == "Aragorn"
        debug_puts "[CITRINE TEST] Child property name == Aragorn: PASS"
      end
      if c.level == 99
        debug_puts "[CITRINE TEST] Child property level == 99: PASS"
      end
      if c.family == "Dunedain"
        debug_puts "[CITRINE TEST] Parent property family == Dunedain: PASS"
      end
      if c.realm == "MiddleEarth"
        debug_puts "[CITRINE TEST] Grandparent property realm == MiddleEarth: PASS"
      end

      # 2. Inherited property mutation
      c.realm = "Gondor"
      if c.realm == "Gondor"
        debug_puts "[CITRINE TEST] Mutated realm property == Gondor: PASS"
      end

      # 3. Super call forwarding and mutation across 3 tiers:
      # scale_stat(10) -> Child: super(10 + 5 = 15) -> Parent: super(15 * 2 = 30) -> Grandparent: 30 + 10 = 40
      stat_res = c.scale_stat(10)
      if stat_res == 40
        debug_puts "[CITRINE TEST] 3-tier super.scale_stat(10) == 40: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Child property name == Aragorn: PASS")
    result.should_have_output("[CITRINE TEST] Child property level == 99: PASS")
    result.should_have_output("[CITRINE TEST] Parent property family == Dunedain: PASS")
    result.should_have_output("[CITRINE TEST] Grandparent property realm == MiddleEarth: PASS")
    result.should_have_output("[CITRINE TEST] Mutated realm property == Gondor: PASS")
    result.should_have_output("[CITRINE TEST] 3-tier super.scale_stat(10) == 40: PASS")
  end

  it "verifies is_a?, as, as?, nil?, responds_to?, and case/when type dispatch on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_introspection_and_casts_test")
    tc.source(<<-CR
      module Flyer
        def fly
          "soaring"
        end
      end

      class Creature
        property name : String
        def initialize(@name)
        end
      end

      class Bird < Creature
        include Flyer
        def chirp
          "tweet"
        end
      end

      class Eagle < Bird
        def hunt
          "catch"
        end
      end

      class Stone
        property weight : Int32
        def initialize(@weight)
        end
      end

      e = Eagle.new("Aquila")
      s = Stone.new(500)

      # 1. Multi-tier is_a? checks
      if e.is_a?(Eagle)
        debug_puts "[CITRINE TEST] Eagle is_a? Eagle: PASS"
      end
      if e.is_a?(Bird)
        debug_puts "[CITRINE TEST] Eagle is_a? Bird (Parent): PASS"
      end
      if e.is_a?(Creature)
        debug_puts "[CITRINE TEST] Eagle is_a? Creature (Grandparent): PASS"
      end
      if e.is_a?(Flyer)
        debug_puts "[CITRINE TEST] Eagle is_a? Flyer (Mixin): PASS"
      end
      if !e.is_a?(Stone)
        debug_puts "[CITRINE TEST] Eagle !is_a? Stone: PASS"
      end
      if !s.is_a?(Creature)
        debug_puts "[CITRINE TEST] Stone !is_a? Creature: PASS"
      end

      # 2. Primitive type is_a?
      num = 42
      if num.is_a?(Int32)
        debug_puts "[CITRINE TEST] 42 is_a? Int32: PASS"
      end
      str = "hello"
      if str.is_a?(String)
        debug_puts "[CITRINE TEST] string is_a? String: PASS"
      end

      # 3. nil? checks
      empty_val = nil
      if empty_val.nil?
        debug_puts "[CITRINE TEST] nil.nil? is true: PASS"
      end
      if !e.nil?
        debug_puts "[CITRINE TEST] object.nil? is false: PASS"
      end

      # 4. as(T) casts
      e_bird = e.as(Bird)
      if e_bird.is_a?(Bird)
        debug_puts "[CITRINE TEST] Eagle.as(Bird): PASS"
      end

      # 5. as?(T) nilable casts
      as_valid = e.as?(Creature)
      if !as_valid.nil?
        debug_puts "[CITRINE TEST] Eagle.as?(Creature) != nil: PASS"
      end
      as_invalid = e.as?(Stone)
      if as_invalid.nil?
        debug_puts "[CITRINE TEST] Eagle.as?(Stone) == nil: PASS"
      end

      # 6. responds_to? checks
      if e.responds_to?(:hunt)
        debug_puts "[CITRINE TEST] Eagle responds_to?(:hunt): PASS"
      end
      if e.responds_to?(:chirp)
        debug_puts "[CITRINE TEST] Eagle responds_to?(:chirp) (inherited): PASS"
      end
      if !e.responds_to?(:weight)
        debug_puts "[CITRINE TEST] Eagle !responds_to?(:weight): PASS"
      end

      # 7. case / when Type pattern matching
      def match_type(item)
        case item
        when String
          10
        when Int32
          20
        when Eagle
          30
        else
          99
        end
      end

      if match_type("test") == 10
        debug_puts "[CITRINE TEST] case String match: PASS"
      end
      if match_type(123) == 20
        debug_puts "[CITRINE TEST] case Int32 match: PASS"
      end
      if match_type(e) == 30
        debug_puts "[CITRINE TEST] case Eagle match: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Eagle is_a? Eagle: PASS")
    result.should_have_output("[CITRINE TEST] Eagle is_a? Bird (Parent): PASS")
    result.should_have_output("[CITRINE TEST] Eagle is_a? Creature (Grandparent): PASS")
    result.should_have_output("[CITRINE TEST] Eagle is_a? Flyer (Mixin): PASS")
    result.should_have_output("[CITRINE TEST] Eagle !is_a? Stone: PASS")
    result.should_have_output("[CITRINE TEST] Stone !is_a? Creature: PASS")
    result.should_have_output("[CITRINE TEST] 42 is_a? Int32: PASS")
    result.should_have_output("[CITRINE TEST] string is_a? String: PASS")
    result.should_have_output("[CITRINE TEST] nil.nil? is true: PASS")
    result.should_have_output("[CITRINE TEST] object.nil? is false: PASS")
    result.should_have_output("[CITRINE TEST] Eagle.as(Bird): PASS")
    result.should_have_output("[CITRINE TEST] Eagle.as?(Creature) != nil: PASS")
    result.should_have_output("[CITRINE TEST] Eagle.as?(Stone) == nil: PASS")
    result.should_have_output("[CITRINE TEST] Eagle responds_to?(:hunt): PASS")
    result.should_have_output("[CITRINE TEST] Eagle responds_to?(:chirp) (inherited): PASS")
    result.should_have_output("[CITRINE TEST] Eagle !responds_to?(:weight): PASS")
    result.should_have_output("[CITRINE TEST] case String match: PASS")
    result.should_have_output("[CITRINE TEST] case Int32 match: PASS")
    result.should_have_output("[CITRINE TEST] case Eagle match: PASS")
  end

  it "verifies structs, value semantics, copy-on-assignment, and struct methods on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_structs_and_value_semantics_test")
    tc.source(<<-CR
      struct Vector3
        property x : Int32
        property y : Int32
        property z : Int32

        def initialize(@x, @y, @z)
        end

        def length_sq
          @x * @x + @y * @y + @z * @z
        end

        def manhattan_dist
          @x + @y + @z
        end
      end

      debug_puts "[CITRINE TEST] Structs & Value Semantics EE Init"

      # 1. Struct creation and field access
      v1 = Vector3.new(2, 3, 6)
      if v1.x == 2 && v1.y == 3 && v1.z == 6
        debug_puts "[CITRINE TEST] Struct fields initialized: PASS"
      end

      # 2. Struct methods
      # 2*2 + 3*3 + 6*6 = 4 + 9 + 36 = 49
      if v1.length_sq == 49
        debug_puts "[CITRINE TEST] Struct method length_sq == 49: PASS"
      end
      if v1.manhattan_dist == 11
        debug_puts "[CITRINE TEST] Struct method manhattan_dist == 11: PASS"
      end

      # 3. Value copy semantics
      v2 = v1
      v1.x = 100
      if v1.x == 100 && v2.x == 2
        debug_puts "[CITRINE TEST] Struct value semantics copy independent: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Struct fields initialized: PASS")
    result.should_have_output("[CITRINE TEST] Struct method length_sq == 49: PASS")
    result.should_have_output("[CITRINE TEST] Struct method manhattan_dist == 11: PASS")
    result.should_have_output("[CITRINE TEST] Struct value semantics copy independent: PASS")
  end

  it "verifies control flow, unless, while with break/next, until, and range matching on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_control_flow_and_loops_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Control Flow & Loops EE Init"

      # 1. if / elsif / else
      score = 85
      grade = 0
      if score >= 90
        grade = 1
      elsif score >= 80
        grade = 2
      else
        grade = 3
      end
      if grade == 2
        debug_puts "[CITRINE TEST] if/elsif/else grade == 2: PASS"
      end

      # 2. unless / else
      is_locked = false
      opened = false
      unless is_locked
        opened = true
      end
      if opened
        debug_puts "[CITRINE TEST] unless is_locked opened == true: PASS"
      end

      # 3. while with break and next
      sum = 0
      i = 0
      while i < 10
        i = i + 1
        if i == 3
          next
        end
        if i == 7
          break
        end
        sum = sum + i
      end
      # i sequence added: 1, 2, 4, 5, 6 = 18
      if sum == 18
        debug_puts "[CITRINE TEST] while with break/next sum == 18: PASS"
      end

      # 4. until loop
      counter = 0
      until counter >= 5
        counter = counter + 1
      end
      if counter == 5
        debug_puts "[CITRINE TEST] until counter == 5: PASS"
      end

      # 5. case / when with RangeLiteral
      def classify_val(v : Int32)
        case v
        when 1..10
          100
        when 11..20
          200
        when 21..30
          300
        else
          999
        end
      end

      if classify_val(5) == 100 && classify_val(15) == 200 && classify_val(25) == 300
        debug_puts "[CITRINE TEST] case when 1..10, 11..20, 21..30: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] if/elsif/else grade == 2: PASS")
    result.should_have_output("[CITRINE TEST] unless is_locked opened == true: PASS")
    result.should_have_output("[CITRINE TEST] while with break/next sum == 18: PASS")
    result.should_have_output("[CITRINE TEST] until counter == 5: PASS")
    result.should_have_output("[CITRINE TEST] case when 1..10, 11..20, 21..30: PASS")
  end

  it "verifies higher-order functions with yield, multi-argument blocks, and array iterators on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_blocks_and_iterators_test")
    tc.source(<<-CR
      debug_puts "[CITRINE TEST] Blocks & Iterators EE Init"

      # 1. Custom higher-order function with yield
      def apply_op(a : Int32, b : Int32)
        yield(a, b)
      end

      res_add = apply_op(20, 22) do |x, y|
        x + y
      end
      if res_add == 42
        debug_puts "[CITRINE TEST] apply_op yield 2-args sum == 42: PASS"
      end

      res_mul = apply_op(6, 7) do |x, y|
        x * y
      end
      if res_mul == 42
        debug_puts "[CITRINE TEST] apply_op yield 2-args mul == 42: PASS"
      end

      # 2. Block inside instance method
      class Calculator
        property factor : Int32
        def initialize(@factor)
        end

        def process(val : Int32)
          yield(val * @factor)
        end
      end

      calc = Calculator.new(10)
      processed = calc.process(5) do |n|
        n + 2
      end
      # (5 * 10) + 2 = 52
      if processed == 52
        debug_puts "[CITRINE TEST] Method block with ivar factor == 52: PASS"
      end

      # 3. Array iterators: each and map
      nums = [1, 2, 3, 4]
      total = 0
      nums.each do |n|
        total = total + n
      end
      if total == 10
        debug_puts "[CITRINE TEST] Array#each sum == 10: PASS"
      end

      doubled = nums.map do |n|
        n * 2
      end
      if doubled[0] == 2 && doubled[1] == 4 && doubled[2] == 6 && doubled[3] == 8
        debug_puts "[CITRINE TEST] Array#map doubled: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] apply_op yield 2-args sum == 42: PASS")
    result.should_have_output("[CITRINE TEST] apply_op yield 2-args mul == 42: PASS")
    result.should_have_output("[CITRINE TEST] Method block with ivar factor == 52: PASS")
    result.should_have_output("[CITRINE TEST] Array#each sum == 10: PASS")
    result.should_have_output("[CITRINE TEST] Array#map doubled: PASS")
  end

  it "verifies arrays, hashes, and enum operations on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("lang_arrays_hashes_enums_test")
    tc.source(<<-CR
      enum State
        Stopped = 0
        Running = 1
        Paused  = 2
      end

      enum Attribute
        Strength = 10
        Agility  = 20
        Intellect = 30
      end

      debug_puts "[CITRINE TEST] Arrays, Hashes & Enums EE Init"

      # 1. Enums & comparisons
      st = State::Running
      if st == State::Running
        debug_puts "[CITRINE TEST] Enum State::Running equality: PASS"
      end
      if st != State::Stopped
        debug_puts "[CITRINE TEST] Enum State::Running != Stopped: PASS"
      end
      if Attribute::Intellect.value == 30
        debug_puts "[CITRINE TEST] Enum Attribute::Intellect.value == 30: PASS"
      end

      # 2. Dynamic Array operations
      items = [10, 20, 30]
      items << 40
      if items.size == 4
        debug_puts "[CITRINE TEST] Array << 40 size == 4: PASS"
      end
      popped = items.pop
      if popped == 40 && items.size == 3
        debug_puts "[CITRINE TEST] Array.pop == 40 and size == 3: PASS"
      end
      if items.first == 10 && items.last == 30
        debug_puts "[CITRINE TEST] Array first == 10, last == 30: PASS"
      end
      items[1] = 99
      if items[1] == 99
        debug_puts "[CITRINE TEST] Array index assign items[1] == 99: PASS"
      end

      # 3. StaticArray operations
      sarr = StaticArray(Int32, 4).new(0)
      sarr[0] = 77
      sarr[1] = 88
      if sarr[0] == 77 && sarr[1] == 88 && sarr.size == 4
        debug_puts "[CITRINE TEST] StaticArray(Int32, 4) indexing and size: PASS"
      end

      # 4. IO::Memory operations
      mem = IO::Memory.new(64)
      mem.puts "Citrine PS2 Parity"
      if mem.pos > 0
        debug_puts "[CITRINE TEST] IO::Memory pos > 0: PASS"
      end
      mem.rewind
      if mem.pos == 0
        debug_puts "[CITRINE TEST] IO::Memory rewind pos == 0: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_output("[CITRINE TEST] Enum State::Running equality: PASS")
    result.should_have_output("[CITRINE TEST] Enum State::Running != Stopped: PASS")
    result.should_have_output("[CITRINE TEST] Enum Attribute::Intellect.value == 30: PASS")
    result.should_have_output("[CITRINE TEST] Array << 40 size == 4: PASS")
    result.should_have_output("[CITRINE TEST] Array.pop == 40 and size == 3: PASS")
    result.should_have_output("[CITRINE TEST] Array first == 10, last == 30: PASS")
    result.should_have_output("[CITRINE TEST] Array index assign items[1] == 99: PASS")
    result.should_have_output("[CITRINE TEST] StaticArray(Int32, 4) indexing and size: PASS")
    result.should_have_output("[CITRINE TEST] IO::Memory pos > 0: PASS")
    result.should_have_output("[CITRINE TEST] IO::Memory rewind pos == 0: PASS")
  end
end
