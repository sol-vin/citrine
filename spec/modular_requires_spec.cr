require "./spec_helper"

describe "Citrine Modular Subsystem Requires" do
  it "leaves physics out when only require 'citrine' is present" do
    source = <<-CR
    require "citrine"
    x = 100
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    program.structs.has_key?("AABB").should be_false
    program.structs.has_key?("FixedPoint").should be_false
  end

  it "loads physics module when require 'citrine/physics' is present" do
    source = <<-CR
    require "citrine"
    require "citrine/physics"

    box1 = AABB.new(10.0, 10.0, 50.0, 50.0)
    box2 = AABB.new(20.0, 20.0, 30.0, 30.0)
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    program.structs.has_key?("AABB").should be_true
    program.structs.has_key?("FixedPoint").should be_true
    program.structs.has_key?("CircleCollider").should be_true

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)
    bytes.size.should be > 16
  end

  it "loads UI module when require 'citrine/ui' is present" do
    source = <<-CR
    require "citrine"
    require "citrine/ui"

    main_loop do
      Citrine.begin_drawing
      Citrine::UI.scope do |ui|
        ui.panel(50, 50, 200, 150, "Options")
        ui.button("Start Game", 60, 90)
      end
      Citrine.end_drawing
    end
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    program.loaded_requires.should contain("citrine/ui")

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)
    bytes.size.should be > 16
  end

  it "loads camera and scene modules" do
    source = <<-CR
    require "citrine/camera"
    require "citrine/scene"

    cam = Camera2D.new
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    program.structs.has_key?("Camera2D").should be_true

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)
    bytes.size.should be > 16
  end

  it "loads low-level hardware modules" do
    source = <<-CR
    require "citrine/hardware/vu0"
    require "citrine/hardware/dmac"
    require "citrine/hardware/gs"
    require "citrine/hardware/cdvd"

    x = 1
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    program.loaded_requires.should contain("citrine/hardware/vu0")
    program.loaded_requires.should contain("citrine/hardware/dmac")
    program.loaded_requires.should contain("citrine/hardware/gs")
    program.loaded_requires.should contain("citrine/hardware/cdvd")

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)
    bytes.size.should be > 16
  end
end
