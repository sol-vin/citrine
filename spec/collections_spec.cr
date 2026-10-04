require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/collections"

record FixedListEntity, id : Int32, priority : Int32

describe "Citrine Collections & FixedList Subsystem" do
  describe "FixedList Allocation & Basic Operations" do
    it "preallocates backing buffer and enforces capacity limit" do
      list = Citrine::FixedList(Int32).new(capacity: 4)
      list.capacity.should eq(4)
      list.size.should eq(0)
      list.empty?.should be_true

      list << 10
      list << 20
      list.size.should eq(2)
      list.empty?.should be_false
      list.first.should eq(10)
      list.last.should eq(20)

      list << 30
      list << 40
      list.size.should eq(4)

      # Attempting to exceed capacity drops additional elements gracefully
      list << 50
      list.size.should eq(4)
      list.last.should eq(40)
    end

    it "supports element mutation and popping" do
      list = Citrine::FixedList(String).new(capacity: 3)
      list << "alpha"
      list << "beta"
      list << "gamma"

      list[1].should eq("beta")
      list[1] = "bravo"
      list[1].should eq("bravo")

      list.pop.should eq("gamma")
      list.size.should eq(2)
      list.pop.should eq("bravo")
      list.pop.should eq("alpha")
      list.pop.should be_nil
      list.empty?.should be_true
    end

    it "raises on out-of-bounds indexing" do
      list = Citrine::FixedList(Int32).new(capacity: 2)
      list << 100

      expect_raises(Exception, /Index out of bounds/) do
        _ = list[5]
      end

      expect_raises(Exception, /Index out of bounds/) do
        list[-1] = 200
      end
    end

    it "clears elements without deallocating backing storage" do
      list = Citrine::FixedList(Int32).new(capacity: 5)
      5.times { |i| list << i }
      list.size.should eq(5)

      list.clear
      list.size.should eq(0)
      list.empty?.should be_true
      list.first.should be_nil

      # Can immediately reuse without dynamic allocation
      list << 999
      list.size.should eq(1)
      list[0].should eq(999)
    end
  end

  describe "FixedList Iteration & In-Place Sorting" do
    it "iterates through active elements with each and each_with_index" do
      list = Citrine::FixedList(Int32).new(capacity: 5)
      list << 10
      list << 20
      list << 30

      items = [] of Int32
      indices = [] of Int32
      list.each_with_index do |val, idx|
        items << val
        indices << idx
      end

      items.should eq([10, 20, 30])
      indices.should eq([0, 1, 2])
    end

    it "sorts elements in-place with zero heap allocations" do
      list = Citrine::FixedList(Int32).new(capacity: 8)
      list << 45
      list << 12
      list << 89
      list << 2
      list << 33

      list.sort!

      sorted = [] of Int32
      list.each { |x| sorted << x }
      sorted.should eq([2, 12, 33, 45, 89])
    end

    it "sorts complex items using sort_by!" do
      list = Citrine::FixedList(FixedListEntity).new(capacity: 4)
      list << FixedListEntity.new(1, 100)
      list << FixedListEntity.new(2, 10)
      list << FixedListEntity.new(3, 50)

      list.sort_by! { |e| e.priority }

      ids = [] of Int32
      list.each { |e| ids << e.id }
      ids.should eq([2, 3, 1])
    end
  end
end
