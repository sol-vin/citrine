require "./spec_helper"
require "../src/stubs/citrine/string"
require "../src/stubs/citrine/collections"

describe "Citrine String Utilities & Collections" do
  describe "StringSlice & StringUtil" do
    it "creates zero-allocation slices" do
      slice = StringSlice.new("PLAYSTATION 2", 0, 11)
      slice.size.should eq(11)
      slice.starts_with?("PLAY").should be_true
      slice.ends_with?("TION").should be_true
    end

    it "formats and joins strings" do
      Citrine::StringUtil.upcase("citrine").should eq("CITRINE")
      Citrine::StringUtil.downcase("CITRINE").should eq("citrine")
      Citrine::StringUtil.join(["A", "B", "C"], "-").should eq("A-B-C")
    end
  end

  describe "FixedList (Zero-Heap Array & Sorting)" do
    it "pushes, pops and accesses elements" do
      list = Citrine::FixedList(Int32).new(capacity: 8)
      list << 10
      list << 20
      list << 30

      list.size.should eq(3)
      list[0].should eq(10)
      list[2].should eq(30)

      popped = list.pop
      popped.should eq(30)
      list.size.should eq(2)
    end

    it "iterates with each and each_with_index" do
      list = Citrine::FixedList(Int32).new(4)
      list << 1 << 2 << 3

      sum = 0
      list.each { |x| sum += x }
      sum.should eq(6)
    end

    it "performs in-place non-allocating sorting" do
      list = Citrine::FixedList(Int32).new(8)
      list << 45 << 12 << 89 << 3 << 27

      list.sort!

      list[0].should eq(3)
      list[1].should eq(12)
      list[2].should eq(27)
      list[3].should eq(45)
      list[4].should eq(89)
    end
  end
end
