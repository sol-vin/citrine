require "./spec_helper"
require "../src/citrine/compiler/bytecode_compiler"
require "../src/citrine/parser/dsl_parser"
require "../src/citrine/parser/error"
require "../src/stubs/citrine"

def compile_source(source : String) : Bytes
  parser = Citrine::DslParser.new
  prog = parser.parse(source)
  compiler = Citrine::BytecodeCompiler.new
  compiler.compile(prog)
end

describe "Compile-Time Error Diagnostics & Validation" do
  describe "Controller Port Hardening" do
    it "rejects invalid port integer literals at compile time" do
      expect_raises(Citrine::CompileError, /PlayStation 2 hardware only supports Port 0 .* and Port 1/) do
        compile_source("Citrine.player(2)")
      end

      expect_raises(Citrine::CompileError, /PlayStation 2 hardware only supports Port 0 .* and Port 1/) do
        compile_source("Citrine.player(-1)")
      end
    end

    it "rejects invalid port enum literals at compile time" do
      expect_raises(Citrine::CompileError, /Unknown controller port 'Port::Port3'/) do
        compile_source("Citrine.player(Port::Port3)")
      end
    end

    it "rejects portless button query calls with explicit instruction" do
      expect_raises(Citrine::CompileError, /requires explicit port and button/) do
        compile_source("Citrine.button_pressed?(Button::Cross)")
      end

      expect_raises(Citrine::CompileError, /requires explicit port and button/) do
        compile_source("Citrine.button_down?(Button::Square)")
      end
    end

    it "rejects invalid analog axis literal" do
      expect_raises(Citrine::CompileError, /Invalid analog axis 4/) do
        compile_source("Citrine.get_analog(0, 4)")
      end
    end
  end

  describe "Constant Name Hardening" do
    it "rejects unknown button enum constants with helpful suggestions" do
      expect_raises(Citrine::CompileError, /Unknown button constant 'Button::Crosss'/) do
        compile_source("pad = Citrine.player(0); pad.button_pressed?(Button::Crosss)")
      end
    end

    it "rejects unknown color constants" do
      expect_raises(Citrine::CompileError, /Unknown color constant 'Color::Blakk'/) do
        compile_source("Citrine.clear_background(Color::Blakk)")
      end
    end

    it "rejects unknown GL mode constants" do
      expect_raises(Citrine::CompileError, /Unknown GL constant 'GL::BOGUS'/) do
        compile_source("GL.begin(GL::BOGUS)")
      end
    end

    it "rejects undefined general constants" do
      expect_raises(Citrine::CompileError, /Undefined constant 'NonExistentConstant'/) do
        compile_source("x = NonExistentConstant")
      end
    end

    it "rejects undefined enum members" do
      source = <<-CR
        enum GameState
          Playing
          Paused
        end
        state = GameState::GameOver
      CR
      expect_raises(Citrine::CompileError, /Enum 'GameState' has no member 'GameOver'/) do
        compile_source(source)
      end
    end
  end

  describe "Native Function Arity Checking" do
    it "checks arity of Citrine.init_window" do
      expect_raises(Citrine::CompileError, /Citrine.init_window requires 3 arguments/) do
        compile_source("Citrine.init_window(640, 480)")
      end
    end

    it "checks arity of Citrine.draw_rectangle" do
      expect_raises(Citrine::CompileError, /Citrine.draw_rectangle requires 5 arguments/) do
        compile_source("Citrine.draw_rectangle(0, 0, 100, 100)")
      end
    end

    it "checks arity of Citrine.draw_circle" do
      expect_raises(Citrine::CompileError, /Citrine.draw_circle requires 4 arguments/) do
        compile_source("Citrine.draw_circle(50, 50, 20)")
      end
    end

    it "checks arity of Citrine.draw_text" do
      expect_raises(Citrine::CompileError, /Citrine.draw_text requires 5 arguments/) do
        compile_source("Citrine.draw_text(\"test\", 10, 10, 16)")
      end
    end

    it "checks arity of Citrine.clear_background" do
      expect_raises(Citrine::CompileError, /Citrine.clear_background requires 1 argument/) do
        compile_source("Citrine.clear_background()")
      end
    end

    it "checks arity of Citrine.channel_send" do
      expect_raises(Citrine::CompileError, /Citrine.channel_send requires 2 arguments/) do
        compile_source("Citrine.channel_send(1)")
      end
    end

    it "checks arity of Citrine.sleep" do
      expect_raises(Citrine::CompileError, /Citrine.sleep requires 1 argument/) do
        compile_source("Citrine.sleep()")
      end
    end

    it "checks arity of Citrine.set_rumble" do
      expect_raises(Citrine::CompileError, /Citrine.set_rumble requires 3 arguments/) do
        compile_source("Citrine.set_rumble(0, 1)")
      end
    end

    it "checks arity of Citrine.play_video" do
      expect_raises(Citrine::CompileError, /Citrine.play_video requires 1 or 2 arguments/) do
        compile_source("Citrine.play_video()")
      end
      expect_raises(Citrine::CompileError, /Citrine.play_video requires 1 or 2 arguments/) do
        compile_source("Citrine.play_video(1, true, 3)")
      end
    end

    it "checks arity of Citrine.draw_triangle" do
      expect_raises(Citrine::CompileError, /Citrine.draw_triangle requires 7 arguments/) do
        compile_source("Citrine.draw_triangle(1, 2, 3)")
      end
    end

    it "checks arity of Controller instance button queries" do
      expect_raises(Citrine::CompileError, /Controller#button_down\? requires exactly 1 argument/) do
        compile_source("pad = Citrine.player(0); pad.button_down?")
      end
      expect_raises(Citrine::CompileError, /Controller#button_pressed\? requires exactly 1 argument/) do
        compile_source("pad = Citrine.player(0); pad.button_pressed?(Button::Cross, Button::Circle)")
      end
    end
  end

  describe "Constant Resolution & Math Constants" do
    it "resolves DualShock 2 analog stick click buttons L3 and R3" do
      bytes = compile_source("x = Button::L3; y = Button::R3")
      bytes.size.should be > 10
    end

    it "resolves Math::PI and PI constants" do
      bytes = compile_source("pi = PI; tau = TAU")
      bytes.size.should be > 10
    end

    it "resolves user-defined top-level constants" do
      bytes = compile_source("SECTOR_SIZE = 2048; s = SECTOR_SIZE")
      bytes.size.should be > 10
    end
  end

  describe "Arithmetic Zero-Division Hardening" do
    it "rejects integer division by zero literal" do
      expect_raises(Citrine::CompileError, /Division by zero is undefined/) do
        compile_source("x = 10 / 0")
      end
    end

    it "rejects modulo by zero literal" do
      expect_raises(Citrine::CompileError, /Division by zero is undefined/) do
        compile_source("m = 42 % 0")
      end
    end
  end
end
