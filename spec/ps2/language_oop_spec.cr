require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Advanced OOP & Type System" do
  it "verifies include and extend mixin dispatch on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_mixins_test")
    tc.source(<<-CR
      module Greeter
        def greet(name)
          debug_puts "[MIXIN] Hello, "
        end
      end

      module MathHelper
        def double(val)
          val + val
        end
      end

      class Hero
        include Greeter
        extend MathHelper

        property name : String

        def initialize(@name)
        end
      end

      h = Hero.new("Link")
      h.greet("Zelda")
      d = Hero.double(21)
      if d == 42
        debug_puts "[CITRINE TEST] Extend double == 42: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[MIXIN] Hello,")
    result.should_have_output("[CITRINE TEST] Extend double == 42: PASS")
  end

  it "verifies is_a?, as, superclasses, and union type matching on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_typing_and_unions_test")
    tc.source(<<-CR
      module Flyer
        def fly; end
      end

      class Animal
        property name : String
        def initialize(@name)
        end
      end

      class Bird < Animal
        include Flyer
      end

      class Fish < Animal
      end

      b = Bird.new("Eagle")
      f = Fish.new("Salmon")

      # is_a? checks
      if b.is_a?(Bird)
        debug_puts "[CITRINE TEST] Bird is_a? Bird: PASS"
      end
      if b.is_a?(Animal)
        debug_puts "[CITRINE TEST] Bird is_a? Animal (SuperClass): PASS"
      end
      if b.is_a?(Flyer)
        debug_puts "[CITRINE TEST] Bird is_a? Flyer (Mixin): PASS"
      end
      if !b.is_a?(Fish)
        debug_puts "[CITRINE TEST] Bird !is_a? Fish: PASS"
      end

      # as cast
      casted = b.as(Animal)
      if casted.is_a?(Animal)
        debug_puts "[CITRINE TEST] Bird.as(Animal): PASS"
      end

      # Union type checking: Int32 | Bird | Fish
      val = 100
      if val.is_a?(Int32 | Float32)
        debug_puts "[CITRINE TEST] Int32 is_a? Int32 | Float32: PASS"
      end
      if b.is_a?(Fish | Bird)
        debug_puts "[CITRINE TEST] Bird is_a? Fish | Bird: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Bird is_a? Bird: PASS")
    result.should_have_output("[CITRINE TEST] Bird is_a? Animal (SuperClass): PASS")
    result.should_have_output("[CITRINE TEST] Bird is_a? Flyer (Mixin): PASS")
    result.should_have_output("[CITRINE TEST] Bird !is_a? Fish: PASS")
    result.should_have_output("[CITRINE TEST] Bird.as(Animal): PASS")
    result.should_have_output("[CITRINE TEST] Int32 is_a? Int32 | Float32: PASS")
    result.should_have_output("[CITRINE TEST] Bird is_a? Fish | Bird: PASS")
  end

  it "verifies abstract class, abstract def, class_property, and setter modifiers" do
    tc = Citrine::Spec::Ps2TestCase.new("language_modifiers_test")
    tc.source(<<-CR
      abstract class Shape
        abstract def area : Int32
        class_property total_shapes : Int32
      end

      class Square < Shape
        getter side : Int32
        setter color_code : Int32

        def initialize(@side)
          @color_code = 0
          Shape.total_shapes = 1
        end

        def area : Int32
          @side * @side
        end
      end

      sq = Square.new(6)
      if sq.area == 36
        debug_puts "[CITRINE TEST] Square area == 36: PASS"
      end
      sq.color_code = 255
      if Shape.total_shapes == 1
        debug_puts "[CITRINE TEST] Shape.total_shapes == 1: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Square area == 36: PASS")
    result.should_have_output("[CITRINE TEST] Shape.total_shapes == 1: PASS")
  end
end
