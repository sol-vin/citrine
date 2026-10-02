require "./spec_helper"

describe Citrine::DslParser do
  it "parses top-level expressions and calls" do
    source = <<-CRYSTAL
    x = 10
    speed = 2.5
    Citrine.init_window(640, 448, "Test")
    CRYSTAL

    parser = Citrine::DslParser.new("test.cr")
    program = parser.parse(source)

    program.top_level_nodes.size.should be >= 3
  end

  it "parses user defined methods" do
    source = <<-CRYSTAL
    def add(a, b)
      a + b
    end
    CRYSTAL

    parser = Citrine::DslParser.new("test.cr")
    program = parser.parse(source)

    program.defs.has_key?("add").should be_true
    program.defs["add"].args.size.should eq(2)
  end

  it "extracts main_loop block body" do
    source = <<-CRYSTAL
    Citrine.main_loop do
      Citrine.draw_rectangle(10, 20, 30, 40, Color::Red)
    end
    CRYSTAL

    parser = Citrine::DslParser.new("test.cr")
    program = parser.parse(source)

    program.main_loop_body.should_not be_nil
  end

  it "raises ParseError on syntax error" do
    bad_source = "def broken(;"
    parser = Citrine::DslParser.new("broken.cr")

    expect_raises(Citrine::ParseError) do
      parser.parse(bad_source)
    end
  end
end
