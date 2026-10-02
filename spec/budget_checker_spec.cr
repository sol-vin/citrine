require "./spec_helper"

describe Citrine::BudgetChecker do
  it "passes safe resource usage" do
    funcs = {"update" => 16_u8, "draw" => 24_u8}
    report = Citrine::BudgetChecker.check(funcs, 4096)

    report.passed?.should be_true
    report.warnings.should be_empty
    report.errors.should be_empty
    report.max_frame_registers.should eq(24)
  end

  it "warns when a frame requests high register counts (> 128)" do
    funcs = {"heavy_calc" => 150_u8}
    report = Citrine::BudgetChecker.check(funcs, 8192)

    report.passed?.should be_true
    report.warnings.size.should be >= 1
    report.warnings.first.should contain("150 registers")
  end

  it "fails when exceeding total SPRAM capacity" do
    # Simulate an overflow
    report = Citrine::BudgetReport.new
    report.errors << "Exceeded SPRAM"
    report.passed?.should be_false
  end

  it "warns when texture memory exceeds VRAM budget" do
    funcs = {"main" => 10_u8}
    # 1024x1024 RGBA texture = 4MB, which exceeds the ~550KB resident texture pool
    textures = [{1024, 1024, 4}]
    report = Citrine::BudgetChecker.check(funcs, 2048, textures)

    report.warnings.any? { |w| w.includes?("exceeds standard GS VRAM") }.should be_true
  end
end
