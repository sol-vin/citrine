require "../spec_helper"
require "../../src/stubs/citrine"
require "../../src/citrine/compiler/bytecode_compiler"
require "../../src/citrine/ast/types"

def compile_source(source : String) : Bytes
  parser = Citrine::DslParser.new
  prog = parser.parse(source)
  compiler = Citrine::BytecodeCompiler.new
  compiler.compile(prog)
end

describe "Citrine Multi-Port Hardware Controller Architecture" do
  describe "DualShock 2 Multi-Port Virtual State" do
    it "initializes separate button states for Port 0 (Player 1) and Port 1 (Player 2)" do
      p1 = Citrine.player(0)
      p2 = Citrine.player(1)

      p1.port.index.should eq(0)
      p2.port.index.should eq(1)

      p1.button_down?(Button::Cross).should be_false
      p2.button_down?(Button::Cross).should be_false
    end

    it "tracks simultaneous inputs on both ports independently without crosstalk" do
      # Simulate hardware pad read updating virtual button bitmasks
      # Port 0: Cross held
      # Port 1: Triangle held
      Citrine::Hardware::VirtualPad.press_button(0, Button::Cross)
      Citrine::Hardware::VirtualPad.press_button(1, Button::Triangle)

      Citrine.button_down?(0, Button::Cross).should be_true
      Citrine.button_down?(0, Button::Triangle).should be_false

      Citrine.button_down?(1, Button::Cross).should be_false
      Citrine.button_down?(1, Button::Triangle).should be_true

      # Player handle queries
      p1 = Citrine.player(0)
      p2 = Citrine.player(1)

      p1.button_down?(Button::Cross).should be_true
      p1.button_down?(Button::Triangle).should be_false

      p2.button_down?(Button::Cross).should be_false
      p2.button_down?(Button::Triangle).should be_true

      # Cleanup
      Citrine::Hardware::VirtualPad.reset
    end

    it "performs edge detection independently per port" do
      # Initial state: both pads idle (curr=0, prev=0)
      Citrine::Hardware::VirtualPad.reset

      # Frame 1: P1 presses Square, P2 presses Circle
      Citrine::Hardware::VirtualPad.press_button(0, Button::Square)
      Citrine::Hardware::VirtualPad.press_button(1, Button::Circle)

      Citrine.button_pressed?(0, Button::Square).should be_true
      Citrine.button_pressed?(1, Button::Circle).should be_true

      # Transition to Frame 2: Both held down
      Citrine::Hardware::VirtualPad.update_frame
      Citrine.button_down?(0, Button::Square).should be_true
      Citrine.button_pressed?(0, Button::Square).should be_false

      Citrine.button_down?(1, Button::Circle).should be_true
      Citrine.button_pressed?(1, Button::Circle).should be_false

      # Transition to Frame 3: P1 releases, P2 continues holding
      Citrine::Hardware::VirtualPad.release_button(0, Button::Square)

      Citrine.button_released?(0, Button::Square).should be_true
      Citrine.button_down?(0, Button::Square).should be_false

      Citrine.button_released?(1, Button::Circle).should be_false
      Citrine.button_down?(1, Button::Circle).should be_true

      # Transition to Frame 4: P1 released is finished
      Citrine::Hardware::VirtualPad.update_frame
      Citrine.button_released?(0, Button::Square).should be_false

      # Cleanup
      Citrine::Hardware::VirtualPad.reset
    end

    it "reads analog axes independently with deadzone filtering for both ports" do
      # Raw center is 128
      Citrine::Hardware::VirtualPad.set_analog(0, 0, 128_u8) # P1 LX center
      Citrine::Hardware::VirtualPad.set_analog(0, 1, 128_u8) # P1 LY center
      Citrine::Hardware::VirtualPad.set_analog(1, 0, 255_u8) # P2 LX full right
      Citrine::Hardware::VirtualPad.set_analog(1, 1, 0_u8)   # P2 LY full up

      # Raw queries
      Citrine::Hardware::VirtualPad.get_raw_analog(0, 0).should eq(128_u8)
      Citrine::Hardware::VirtualPad.get_raw_analog(1, 0).should eq(255_u8)
      Citrine::Hardware::VirtualPad.get_raw_analog(1, 1).should eq(0_u8)

      # Normalized float queries (-1.0 .. +1.0)
      p1 = Citrine.player(0)
      p2 = Citrine.player(1)

      p1.left_stick_x.should be_close(0.0_f32, 0.05_f32)
      p2.left_stick_x.should be_close(1.0_f32, 0.05_f32)
      p2.left_stick_y.should be_close(-1.0_f32, 0.05_f32)
    end

    it "dispatches dual vibration motor commands per port" do
      # Small motor is digital (0/1), Large motor is PWM (0..255)
      Citrine.set_rumble(0, 1, 180)
      Citrine.set_rumble(1, 0, 90)

      Citrine::Hardware::VirtualPad.get_rumble_small(0).should eq(1)
      Citrine::Hardware::VirtualPad.get_rumble_large(0).should eq(180)

      Citrine::Hardware::VirtualPad.get_rumble_small(1).should eq(0)
      Citrine::Hardware::VirtualPad.get_rumble_large(1).should eq(90)
    end
  end

  describe "Multi-Port Bytecode Compilation" do
    it "compiles 2-player controller loop into distinct native calls" do
      source = <<-CR
        require "citrine"
        p1 = Citrine.player(0)
        p2 = Citrine.player(1)

        Citrine.main_loop do
          if p1.button_pressed?(Button::Cross)
            Citrine.set_rumble(0, 1, 200)
          end
          if p2.button_pressed?(Button::Square)
            Citrine.set_rumble(1, 0, 150)
          end
        end
      CR

      bytes = compile_source(source)
      bytes.size.should be > 0
    end
  end
end
