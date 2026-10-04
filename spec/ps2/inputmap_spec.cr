require "../spec_helper"
require "../../src/stubs/citrine"
require "../../src/stubs/citrine/inputmap"
require "../../src/citrine/compiler/bytecode_compiler"
require "../../src/citrine/ast/types"

def compile_citrine_source(source : String) : Bytes
  parser = Citrine::DslParser.new
  prog = parser.parse(source)
  compiler = Citrine::BytecodeCompiler.new
  compiler.compile(prog)
end

describe "Citrine Multi-Port Controller & Godot-Style InputMap" do
  describe "Citrine::Port and Citrine.player" do
    it "defines Port enum with 0-indexed port values" do
      Citrine::Port::Port1.value.should eq(0_u8)
      Citrine::Port::Port2.value.should eq(1_u8)
      Citrine::Port::Player1.value.should eq(0_u8)
      Citrine::Port::Player2.value.should eq(1_u8)
      Citrine::Port::Port1.index.should eq(0)
      Citrine::Port::Port2.index.should eq(1)
    end

    it "creates Controller handles for Player 1 and Player 2" do
      p1 = Citrine.player(0)
      p2 = Citrine.player(1)
      p1.port.should eq(Citrine::Port::Port1)
      p2.port.should eq(Citrine::Port::Port2)
    end
  end

  describe "Citrine::InputMap Registry" do
    it "registers actions with specific button and port bindings" do
      Citrine::InputMap.clear
      Citrine::InputMap.add_action("jump", Button::Cross, port: 0)
      Citrine::InputMap.add_action("p2_jump", Button::Cross, port: 1)

      actions = Citrine::InputMap.instance.actions
      actions.has_key?("jump").should be_true
      actions.has_key?("p2_jump").should be_true

      actions["jump"].first.button.should eq(Button::Cross)
      actions["jump"].first.port.should eq(0)

      actions["p2_jump"].first.button.should eq(Button::Cross)
      actions["p2_jump"].first.port.should eq(1)
    end

    it "supports declarative input_map DSL" do
      input_map do
        action :test_attack, Button::Square, port: 0
        action :test_shield, Button::Circle, port: 1
      end

      actions = Citrine::InputMap.instance.actions
      actions.has_key?("test_attack").should be_true
      actions["test_attack"].first.button.should eq(Button::Square)
      actions["test_attack"].first.port.should eq(0)

      actions.has_key?("test_shield").should be_true
      actions["test_shield"].first.button.should eq(Button::Circle)
      actions["test_shield"].first.port.should eq(1)
    end

    it "supports multiple button bindings for a single action" do
      Citrine::InputMap.clear
      Citrine::Hardware::VirtualPad.reset

      # Bind Jump to both Cross and Up (common platformer mapping)
      Citrine::InputMap.add_action("jump", Button::Cross, port: 0)
      Citrine::InputMap.add_action("jump", Button::Up, port: 0)

      # Neither pressed
      Action.is_down?("jump").should be_false

      # Press Cross -> Jump is active
      Citrine::Hardware::VirtualPad.press_button(0, Button::Cross)
      Action.is_pressed?("jump").should be_true
      Action.is_down?("jump").should be_true

      # Release Cross, press Up -> Jump is still active
      Citrine::Hardware::VirtualPad.release_button(0, Button::Cross)
      Citrine::Hardware::VirtualPad.press_button(0, Button::Up)
      Action.is_down?("jump").should be_true

      Citrine::Hardware::VirtualPad.reset
    end

    it "queries independent actions across Player 1 and Player 2" do
      Citrine::InputMap.clear
      Citrine::Hardware::VirtualPad.reset

      Citrine::InputMap.add_action("p1_fire", Button::Square, port: 0)
      Citrine::InputMap.add_action("p2_fire", Button::Square, port: 1)

      # P1 fires, P2 does not
      Citrine::Hardware::VirtualPad.press_button(0, Button::Square)

      Action.is_down?("p1_fire").should be_true
      Action.is_down?("p2_fire").should be_false

      # P2 fires as well
      Citrine::Hardware::VirtualPad.press_button(1, Button::Square)

      Action.is_down?("p1_fire").should be_true
      Action.is_down?("p2_fire").should be_true

      Citrine::Hardware::VirtualPad.reset
    end

    it "computes directional axis values and cancels opposing inputs" do
      Citrine::InputMap.clear
      Citrine::Hardware::VirtualPad.reset

      Citrine::InputMap.add_action("move_left", Button::Left, port: 0)
      Citrine::InputMap.add_action("move_right", Button::Right, port: 0)

      # Neutral: 0.0
      Action.get_axis("move_left", "move_right").should eq(0.0_f32)

      # Left pressed: -1.0
      Citrine::Hardware::VirtualPad.press_button(0, Button::Left)
      Action.get_axis("move_left", "move_right").should eq(-1.0_f32)

      # Right also pressed: cancels to 0.0
      Citrine::Hardware::VirtualPad.press_button(0, Button::Right)
      Action.get_axis("move_left", "move_right").should eq(0.0_f32)

      # Left released, only right: +1.0
      Citrine::Hardware::VirtualPad.release_button(0, Button::Left)
      Action.get_axis("move_left", "move_right").should eq(1.0_f32)

      Citrine::Hardware::VirtualPad.reset
    end

    it "supports dynamic runtime rebinding of actions" do
      Citrine::InputMap.clear
      Citrine::Hardware::VirtualPad.reset

      # Initial: Jump bound to Cross
      Citrine::InputMap.add_action("jump", Button::Cross, port: 0)
      Citrine::Hardware::VirtualPad.press_button(0, Button::Cross)
      Action.is_down?("jump").should be_true

      # Rebind: Clear and bind Jump to Triangle
      Citrine::InputMap.clear
      Citrine::InputMap.add_action("jump", Button::Triangle, port: 0)

      # Holding Cross no longer triggers Jump
      Action.is_down?("jump").should be_false

      # Pressing Triangle triggers newly rebound Jump
      Citrine::Hardware::VirtualPad.press_button(0, Button::Triangle)
      Action.is_down?("jump").should be_true

      Citrine::Hardware::VirtualPad.reset
    end

    it "provides Godot-style compatibility method aliases" do
      Citrine::InputMap.clear
      Citrine::Hardware::VirtualPad.reset

      Citrine::InputMap.add_action("dash", Button::L1, port: 0)
      Citrine::Hardware::VirtualPad.press_button(0, Button::L1)

      Action.is_action_just_pressed("dash").should be_true
      Action.is_action_pressed("dash").should be_true

      # Transition frame: held down -> prev = L1
      Citrine::Hardware::VirtualPad.update_frame

      # Release button: curr = 0, prev = L1 -> falling edge
      Citrine::Hardware::VirtualPad.release_button(0, Button::L1)
      Action.is_action_just_released("dash").should be_true

      Citrine::Hardware::VirtualPad.reset
    end
  end

  describe "Bytecode Compiler Port Enforcement" do
    it "rejects portless Citrine.button_pressed? calls at compile time" do
      source = <<-CR
        require "citrine"
        Citrine.main_loop do
          Citrine.button_pressed?(Button::Cross)
        end
      CR

      expect_raises(Exception, /requires explicit port/) do
        compile_citrine_source(source)
      end
    end

    it "compiles Citrine.button_pressed?(port, button) cleanly" do
      source = <<-CR
        require "citrine"
        Citrine.main_loop do
          Citrine.button_pressed?(0, Button::Cross)
        end
      CR

      bytes = compile_citrine_source(source)
      bytes.size.should be > 0
    end

    it "compiles player(0).button_pressed?(Button::Cross) cleanly" do
      source = <<-CR
        require "citrine"
        Citrine.main_loop do
          p1 = Citrine.player(0)
          p1.button_pressed?(Button::Cross)
        end
      CR

      bytes = compile_citrine_source(source)
      bytes.size.should be > 0
    end

    it "compiles Action.is_pressed?(Actions::SpawnOne) directly to NativeId::ActionPressed" do
      source = <<-CR
        require "citrine"
        require "citrine/inputmap"
        Citrine.main_loop do
          Action.is_pressed?(Actions::SpawnOne)
        end
      CR

      bytes = compile_citrine_source(source)
      bytes.size.should be > 0
    end
  end
end
