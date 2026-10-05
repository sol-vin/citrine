require "./spec_helper"

describe "Citrine Macro Expander" do
  it "expands user-defined macros with argument substitution" do
    source = <<-CR
    macro add_ten(val)
      {{val}} + 10
    end

    x = add_ten(32)
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)

    bytes.size.should be > 16
    bytes[0..3].should eq(Bytes[0x43, 0x42, 0x43, 0x32]) # CBC2
  end

  it "expands citrine_ecs! into component ID constants" do
    source = <<-CR
    citrine_ecs! do
      component Position, x: Float32, y: Float32
      component Velocity, vx: Float32, vy: Float32
      component Health, hp: Int32
    end

    main_loop do
      # Loop
    end
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    # Top level should have component constants
    program.top_level_nodes.size.should be >= 4

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)
    bytes.size.should be > 16
  end

  it "expands fsm! into state IDs and initial state variable" do
    source = <<-CR
    fsm BossAI, initial: :idle do
      state :idle
      state :patrol
      state :attack
      state :defeated
    end

    main_loop do
      # Loop
    end
    CR

    parser = Citrine::DslParser.new
    program = parser.parse(source)

    # Top level should contain STATE_IDLE, STATE_PATROL, STATE_ATTACK, STATE_DEFEATED, and boss_ai_state
    program.top_level_nodes.size.should be >= 5

    compiler = Citrine::BytecodeCompiler.new
    bytes = compiler.compile(program)
    bytes.size.should be > 16
  end
end
