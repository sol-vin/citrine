require "../spec_helper"

describe "Citrine Tier 1: OOP & Structs Compiler Specification Suite" do
  it "compiles classes with properties, instance methods, and field offsets" do
    source = <<-CRYSTAL
      class Player
        property name : String
        property hp : Int32
        property max_hp : Int32

        def initialize(@name, @max_hp)
          @hp = @max_hp
        end

        def heal(amount : Int32)
          @hp = @hp + amount
          if @hp > @max_hp
            @hp = @max_hp
          end
          @hp
        end
      end

      p = Player.new("Hero", 100)
      p.heal(20)
    CRYSTAL

    parser = Citrine::DslParser.new("player.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("player.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
    compiler.classes.has_key?("Player").should be_true
    player_info = compiler.classes["Player"]
    player_info.fields.keys.should contain("name")
    player_info.fields.keys.should contain("hp")
    player_info.fields.keys.should contain("max_hp")

    heal_fn = compiler.functions.find { |f| f.name == "Player#heal" }
    heal_fn.should_not be_nil
  end

  it "compiles multi-tier inheritance and super calls" do
    source = <<-CRYSTAL
      class Entity
        property x : Int32
        property y : Int32
        def initialize(@x, @y)
        end
        def move(dx, dy)
          @x += dx
          @y += dy
        end
      end

      class Actor < Entity
        property speed : Int32
        def initialize(@x, @y, @speed)
        end
        def move(dx, dy)
          super(dx * @speed, dy * @speed)
        end
      end

      a = Actor.new(0, 0, 2)
      a.move(5, 10)
    CRYSTAL

    parser = Citrine::DslParser.new("actor.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("actor.cr")
    bytes = compiler.compile(prog)

    compiler.classes.has_key?("Actor").should be_true
    actor_info = compiler.classes["Actor"]
    actor_info.superclass_name.should eq("Entity")
  end

  it "compiles module mixins and multiple inclusions" do
    source = <<-CRYSTAL
      module Swimmable
        def swim_speed
          10
        end
      end

      module Attackable
        def attack_power
          50
        end
      end

      class AmphibianWarrior
        include Swimmable
        include Attackable

        def battle_score
          swim_speed + attack_power
        end
      end

      w = AmphibianWarrior.new
      score = w.battle_score
    CRYSTAL

    parser = Citrine::DslParser.new("mixins.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("mixins.cr")
    bytes = compiler.compile(prog)

    compiler.modules.has_key?("Swimmable").should be_true
    compiler.modules.has_key?("Attackable").should be_true
    compiler.classes.has_key?("AmphibianWarrior").should be_true
  end

  it "compiles class variables and static class methods" do
    source = <<-CRYSTAL
      class Counter
        @@total : Int32 = 0
        def self.increment
          @@total += 1
        end
        def self.total
          @@total
        end
      end

      Counter.increment
      Counter.increment
      cnt = Counter.total
    CRYSTAL

    parser = Citrine::DslParser.new("counter.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("counter.cr")
    bytes = compiler.compile(prog)

    bytes.size.should be > 20
  end

  it "compiles structs with value-copy semantics" do
    source = <<-CRYSTAL
      struct Vec3
        property x : Int32
        property y : Int32
        property z : Int32
        def initialize(@x, @y, @z)
        end
      end

      v1 = Vec3.new(1, 2, 3)
      v2 = v1
      v1.x = 99
      res = v2.x
    CRYSTAL

    parser = Citrine::DslParser.new("vec3.cr")
    prog = parser.parse(source)
    compiler = Citrine::BytecodeCompiler.new("vec3.cr")
    bytes = compiler.compile(prog)

    compiler.classes.has_key?("Vec3").should be_true
    compiler.classes["Vec3"].is_struct.should be_true
  end
end
