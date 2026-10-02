require "./spec_helper"

describe Citrine::SourceMap do
  it "records and resolves source code locations" do
    sm = Citrine::SourceMap.new
    sm.add(0, "main.cr", 10, 5, "update")
    sm.add(5, "main.cr", 12, 1, "update")

    loc0 = sm.resolve(0)
    loc0.should_not be_nil
    loc0.not_nil!.line.should eq(10)
    loc0.not_nil!.function.should eq("update")

    # In-between offset resolves to closest preceding
    loc3 = sm.resolve(3)
    loc3.should_not be_nil
    loc3.not_nil!.line.should eq(10)

    loc5 = sm.resolve(5)
    loc5.should_not be_nil
    loc5.not_nil!.line.should eq(12)
  end

  it "serializes and deserializes cleanly" do
    sm = Citrine::SourceMap.new
    sm.add(0, "game.cr", 42, 8, "main")
    sm.record_register("main", 0, "pos")

    json = sm.to_json
    restored = Citrine::SourceMap.from_json(json)

    restored.locations[0].line.should eq(42)
    restored.register_names["main"][0].should eq("pos")
  end
end
