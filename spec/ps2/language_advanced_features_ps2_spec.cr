require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Advanced Language Features Suite" do
  ps2_test "advanced_cvars_and_class_methods_test", "verifies class variables (@@cvar), class methods, and persistence across scopes on PS2 EE" do |tc|
    tc.source(<<-CR
      class InventoryManager
        @@inventory_count : Int32 = 0
        @@gold_reserve : Int32 = 500

        property item_name : String
        property item_qty : Int32

        def initialize(@item_name, @item_qty)
          @@inventory_count = @@inventory_count + @item_qty
        end

        def self.total_inventory
          @@inventory_count
        end

        def self.add_gold(amount : Int32)
          @@gold_reserve = @@gold_reserve + amount
          @@gold_reserve
        end

        def self.gold
          @@gold_reserve
        end
      end

      # 1. Initial class variable state
      Test.assert(InventoryManager.total_inventory == 0 && InventoryManager.gold == 500, "Initial class variables")

      # 2. Instance creation mutating class variable
      item1 = InventoryManager.new("Potion", 10)
      item2 = InventoryManager.new("Elixir", 5)
      Test.assert(InventoryManager.total_inventory == 15, "Cvar accumulated from instances")

      # 3. Direct mutation via class method
      new_gold = InventoryManager.add_gold(250)
      Test.assert(new_gold == 750 && InventoryManager.gold == 750, "Class method cvar mutation == 750")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_pass("Initial class variables")
    result.should_pass("Cvar accumulated from instances")
    result.should_pass("Class method cvar mutation == 750")
  end

  ps2_test "advanced_default_args_test", "verifies method default arguments and arity dispatch on PS2 EE" do |tc|
    tc.source(<<-CR
      def compute_tax(base : Int32, rate : Int32 = 10, discount : Int32 = 2)
        (base * rate / 100) - discount
      end

      # 1. Positional with all defaults applied: base=100, rate=10, discount=2 -> 10 - 2 = 8
      tax1 = compute_tax(100)
      Test.assert(tax1 == 8, "compute_tax(100) with 2 defaults == 8")

      # 2. Positional overriding first default: base=100, rate=20, discount=2 -> 20 - 2 = 18
      tax2 = compute_tax(100, 20)
      Test.assert(tax2 == 18, "compute_tax(100, 20) with 1 default == 18")

      # 3. All arguments specified: base=200, rate=15, discount=5 -> 30 - 5 = 25
      tax3 = compute_tax(200, 15, 5)
      Test.assert(tax3 == 25, "compute_tax(200, 15, 5) full arity == 25")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_pass("compute_tax(100) with 2 defaults == 8")
    result.should_pass("compute_tax(100, 20) with 1 default == 18")
    result.should_pass("compute_tax(200, 15, 5) full arity == 25")
  end

  ps2_test "advanced_tuples_unpacking_test", "verifies tuples, tuple indexing, and multiple assignment unpacking on PS2 EE" do |tc|
    tc.source(<<-CR
      # 1. Tuple literal and indexed access
      tup = {10, 20, 30}
      Test.assert(tup[0] == 10 && tup[1] == 20 && tup[2] == 30, "Tuple literal indexed access")

      # 2. Multiple assignment unpacking from tuple
      a, b, c = tup
      Test.assert(a == 10 && b == 20 && c == 30, "Multiple assignment unpacking a, b, c")

      # 3. Swap pattern via multiple assignment
      x = 100
      y = 200
      x, y = {y, x}
      Test.assert(x == 200 && y == 100, "Tuple swap x, y == 200, 100")
    CR
    )
    result = tc.run_and_verify(timeout: 7.seconds)
    result.should_pass("Tuple literal indexed access")
    result.should_pass("Multiple assignment unpacking a, b, c")
    result.should_pass("Tuple swap x, y == 200, 100")
  end
end
