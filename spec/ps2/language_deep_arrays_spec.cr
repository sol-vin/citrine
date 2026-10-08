require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Deep Arrays & Complex Collections" do
  it "verifies dynamic array capacity resizing, large element accumulation (64+ elements), and element summation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_deep_dynamic_realloc_test")
    tc.source(<<-CR
      # Initialize with initial elements
      arr = [100, 200, 300]

      # Dynamically push 64 elements to force multiple buffer reallocations
      i = 1
      while i <= 64
        arr << i
        i = i + 1
      end

      sz = arr.size
      first_elem = arr[0]
      third_elem = arr[2]
      elem_1 = arr[3]
      elem_64 = arr[66]

      # Accumulate sum of all elements
      total_sum = 0
      idx = 0
      while idx < arr.size
        total_sum = total_sum + arr[idx]
        idx = idx + 1
      end

      # Initial sum: 100 + 200 + 300 = 600
      # Sum of 1..64 = (64 * 65) / 2 = 2080
      # Total expected sum = 2680
      if sz == 67 && first_elem == 100 && third_elem == 300 && elem_1 == 1 && elem_64 == 64 && total_sum == 2680
        debug_puts "[CITRINE TEST] DeepArrays#dynamic_realloc_and_sum: PASS"
      else
        debug_puts "[CITRINE TEST] DeepArrays#dynamic_realloc_and_sum: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepArrays#dynamic_realloc_and_sum: PASS")
  end

  it "verifies 3D cube matrix coordinate transforms and non-uniform jagged arrays on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_deep_3d_and_jagged_test")
    tc.source(<<-CR
      # 1. 3D nested array (2 x 2 x 2)
      cube = [
        [
          [10, 20],
          [30, 40]
        ],
        [
          [50, 60],
          [70, 80]
        ]
      ]

      c000 = cube[0][0][0] # 10
      c011 = cube[0][1][1] # 40
      c100 = cube[1][0][0] # 50
      c111 = cube[1][1][1] # 80

      # In-place 3D mutation
      cube[1][1][0] = 777
      mut_c110 = cube[1][1][0]

      # 2. Non-uniform jagged array
      jagged = [
        [1],
        [10, 20, 30],
        [100, 200, 300, 400, 500]
      ]

      sz_r0 = jagged[0].size # 1
      sz_r1 = jagged[1].size # 3
      sz_r2 = jagged[2].size # 5

      # Jagged element mutations
      jagged[0][0] = 9
      jagged[1][1] = 222
      jagged[2][4] = 999

      j00 = jagged[0][0]
      j11 = jagged[1][1]
      j24 = jagged[2][4]

      cube_ok = (c000 == 10) && (c011 == 40) && (c100 == 50) && (c111 == 80) && (mut_c110 == 777)
      jagged_ok = (sz_r0 == 1) && (sz_r1 == 3) && (sz_r2 == 5) && (j00 == 9) && (j11 == 222) && (j24 == 999)

      if cube_ok && jagged_ok
        debug_puts "[CITRINE TEST] DeepArrays#3d_and_jagged_arrays: PASS"
      else
        debug_puts "[CITRINE TEST] DeepArrays#3d_and_jagged_arrays: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepArrays#3d_and_jagged_arrays: PASS")
  end

  it "verifies in-place bubble sorting, element swapping, and array reversal on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_deep_sort_and_reverse_test")
    tc.source(<<-CR
      numbers = [42, 17, 89, 5, 23, 71, 1, 99, 34, 12]
      n = numbers.size

      # Bubble sort in ascending order
      i = 0
      while i < n - 1
        j = 0
        while j < n - i - 1
          if numbers[j] > numbers[j + 1]
            temp = numbers[j]
            numbers[j] = numbers[j + 1]
            numbers[j + 1] = temp
          end
          j = j + 1
        end
        i = i + 1
      end

      # Expected: [1, 5, 12, 17, 23, 34, 42, 71, 89, 99]
      s0 = numbers[0]
      s1 = numbers[1]
      s4 = numbers[4]
      s8 = numbers[8]
      s9 = numbers[9]
      sort_ok = (s0 == 1) && (s1 == 5) && (s4 == 23) && (s8 == 89) && (s9 == 99)

      # In-place two-pointer reversal
      left = 0
      right = n - 1
      while left < right
        tmp = numbers[left]
        numbers[left] = numbers[right]
        numbers[right] = tmp
        left = left + 1
        right = right - 1
      end

      # Expected: [99, 89, 71, 42, 34, 23, 17, 12, 5, 1]
      r0 = numbers[0]
      r1 = numbers[1]
      r4 = numbers[4]
      r8 = numbers[8]
      r9 = numbers[9]
      rev_ok = (r0 == 99) && (r1 == 89) && (r4 == 34) && (r8 == 5) && (r9 == 1)

      if sort_ok && rev_ok
        debug_puts "[CITRINE TEST] DeepArrays#bubble_sort_and_reverse: PASS"
      else
        debug_puts "[CITRINE TEST] DeepArrays#bubble_sort_and_reverse: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepArrays#bubble_sort_and_reverse: PASS")
  end

  it "verifies higher-order pipelines: chained map, select, and accumulation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_deep_higher_order_pipeline_test")
    tc.source(<<-CR
      base_items = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

      # 1. Select even numbers: [2, 4, 6, 8, 10]
      evens = base_items.select do |x|
        (x % 2) == 0
      end
      ev_len = evens.size

      # 2. Map multiplying each even by 5: [10, 20, 30, 40, 50]
      scaled = evens.map do |x|
        x * 5
      end
      sc_len = scaled.size
      sc0 = scaled[0] # 10
      sc2 = scaled[2] # 30
      sc4 = scaled[4] # 50

      # 3. Accumulate sum of scaled elements with each
      total = 0
      scaled.each do |v|
        total = total + v
      end
      # Sum = 10 + 20 + 30 + 40 + 50 = 150

      if ev_len == 5 && sc_len == 5 && sc0 == 10 && sc2 == 30 && sc4 == 50 && total == 150
        debug_puts "[CITRINE TEST] DeepArrays#higher_order_pipelines: PASS"
      else
        debug_puts "[CITRINE TEST] DeepArrays#higher_order_pipelines: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepArrays#higher_order_pipelines: PASS")
  end

  it "verifies arrays of custom objects with nested array properties and aggregate queries on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_deep_objects_with_nested_arrays_test")
    tc.source(<<-CR
      class InventoryItem
        property name : String
        property prices : Array(Int32)

        def initialize(@name, @prices)
        end

        def average_price : Int32
          if @prices.empty?
            0
          else
            sum = 0
            i = 0
            while i < @prices.size
              sum = sum + @prices[i]
              i = i + 1
            end
            sum // @prices.size
          end
        end

        def add_price(p : Int32)
          @prices << p
        end
      end

      items = [
        InventoryItem.new("Potion", [50, 40, 60]),
        InventoryItem.new("Elixir", [200, 180, 220]),
        InventoryItem.new("PhoenixDown", [500, 520, 480])
      ]

      # Initial averages:
      # Potion: (50 + 40 + 60) / 3 = 50
      # Elixir: (200 + 180 + 220) / 3 = 200
      # PhoenixDown: (500 + 520 + 480) / 3 = 500
      avg0 = items[0].average_price
      avg1 = items[1].average_price
      avg2 = items[2].average_price

      # Mutate nested arrays
      items[0].add_price(90) # Potion prices now [50, 40, 60, 90], avg = 240 / 4 = 60
      new_avg0 = items[0].average_price
      p0_sz = items[0].prices.size

      if avg0 == 50 && avg1 == 200 && avg2 == 500 && new_avg0 == 60 && p0_sz == 4
        debug_puts "[CITRINE TEST] DeepArrays#objects_with_nested_arrays: PASS"
      else
        debug_puts "[CITRINE TEST] DeepArrays#objects_with_nested_arrays: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepArrays#objects_with_nested_arrays: PASS")
  end

  it "verifies edge conditions: empty arrays, pop to exhaustion, clear-refill cycle, and negative indexing on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_deep_edge_conditions_test")
    tc.source(<<-CR
      # 1. Empty array creation
      empty_arr = [] of Int32
      is_init_empty = empty_arr.empty?
      sz_empty = empty_arr.size

      # 2. Push elements then pop to exhaustion
      work = [10, 20, 30]
      p1 = work.pop # 30
      p2 = work.pop # 20
      p3 = work.pop # 10
      sz_exhausted = work.size # 0
      is_exhausted = work.empty?

      # 3. Clear and refill cycle
      refill = [100, 200, 300, 400]
      refill.clear
      sz_after_clear = refill.size # 0
      refill << 999
      refill << 888
      sz_after_refill = refill.size # 2
      first_refill = refill[0] # 999
      second_refill = refill[1] # 888

      # 4. Negative indexing and in-place negative mutation
      neg_arr = [5, 15, 25, 35, 45]
      last_val = neg_arr[-1] # 45
      second_last = neg_arr[-2] # 35
      neg_arr[-1] = 99
      mut_last = neg_arr[-1] # 99
      orig_last_via_pos = neg_arr[4] # 99

      edge1_ok = is_init_empty && (sz_empty == 0)
      edge2_ok = (p1 == 30) && (p2 == 20) && (p3 == 10) && (sz_exhausted == 0) && is_exhausted
      edge3_ok = (sz_after_clear == 0) && (sz_after_refill == 2) && (first_refill == 999) && (second_refill == 888)
      edge4_ok = (last_val == 45) && (second_last == 35) && (mut_last == 99) && (orig_last_via_pos == 99)

      if edge1_ok && edge2_ok && edge3_ok && edge4_ok
        debug_puts "[CITRINE TEST] DeepArrays#edge_conditions_and_exhaustion: PASS"
      else
        debug_puts "[CITRINE TEST] DeepArrays#edge_conditions_and_exhaustion: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] DeepArrays#edge_conditions_and_exhaustion: PASS")
  end
end
