require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Arrays & Collections" do
  it "verifies dynamic array allocation, growth past capacity, and element integrity on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_growth_and_capacity_test")
    tc.source(<<-CR
      # Start with a small array
      items = [10, 20]

      # Grow dynamically past initial capacity
      items << 30
      items << 40
      items << 50
      items << 60
      items << 70
      items << 80

      sz = items.size
      i0 = items[0]
      i3 = items[3]
      i7 = items[7]

      # Verify all elements preserved after growth
      sum = 0
      idx = 0
      while idx < items.size
        sum = sum + items[idx]
        idx = idx + 1
      end

      # Sum of 10..80 (step 10) = 360
      if sz == 8 && i0 == 10 && i3 == 40 && i7 == 80 && sum == 360
        debug_puts "[CITRINE TEST] Arrays#dynamic_growth_and_capacity: PASS"
      else
        debug_puts "[CITRINE TEST] Arrays#dynamic_growth_and_capacity: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Arrays#dynamic_growth_and_capacity: PASS")
  end

  it "verifies positive and negative indexing and in-place mutation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_indexing_and_mutation_test")
    tc.source(<<-CR
      arr = [100, 200, 300, 400, 500]

      # Negative indexing
      last_elem = arr[-1]
      second_last = arr[-2]

      # In-place element mutation
      arr[0] = 111
      arr[2] = 333
      arr[-1] = 555

      m0 = arr[0]
      m2 = arr[2]
      m4 = arr[4]
      m_last = arr[-1]

      if last_elem == 500 && second_last == 400 && m0 == 111 && m2 == 333 && m4 == 555 && m_last == 555
        debug_puts "[CITRINE TEST] Arrays#indexing_and_in_place_mutation: PASS"
      else
        debug_puts "[CITRINE TEST] Arrays#indexing_and_in_place_mutation: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Arrays#indexing_and_in_place_mutation: PASS")
  end

  it "verifies stack operations pop, push, and clear on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_stack_ops_test")
    tc.source(<<-CR
      stack = [1, 2, 3]

      p1 = stack.pop # should be 3
      p2 = stack.pop # should be 2
      sz_after_pop = stack.size # should be 1

      stack.push(99)
      sz_after_push = stack.size # should be 2
      top = stack[-1] # should be 99

      stack.clear
      sz_cleared = stack.size # should be 0

      if p1 == 3 && p2 == 2 && sz_after_pop == 1 && sz_after_push == 2 && top == 99 && sz_cleared == 0
        debug_puts "[CITRINE TEST] Arrays#stack_pop_push_clear: PASS"
      else
        debug_puts "[CITRINE TEST] Arrays#stack_pop_push_clear: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Arrays#stack_pop_push_clear: PASS")
  end

  it "verifies 2D multidimensional arrays and matrix indexing on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_2d_matrix_test")
    tc.source(<<-CR
      # 3x3 identity-like matrix
      matrix = [
        [1, 0, 0],
        [0, 1, 0],
        [0, 0, 1]
      ]

      # Read elements
      r0c0 = matrix[0][0]
      r1c1 = matrix[1][1]
      r2c2 = matrix[2][2]
      r0c1 = matrix[0][1]

      # Mutate inner element
      matrix[0][1] = 9
      matrix[2][0] = 7

      mut01 = matrix[0][1]
      mut20 = matrix[2][0]

      if r0c0 == 1 && r1c1 == 1 && r2c2 == 1 && r0c1 == 0 && mut01 == 9 && mut20 == 7
        debug_puts "[CITRINE TEST] Arrays#multidimensional_matrix: PASS"
      else
        debug_puts "[CITRINE TEST] Arrays#multidimensional_matrix: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Arrays#multidimensional_matrix: PASS")
  end

  it "verifies higher-order iteration each, map, and select on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_higher_order_test")
    tc.source(<<-CR
      numbers = [1, 2, 3, 4, 5, 6]

      # each accumulation
      acc = 0
      numbers.each do |n|
        acc = acc + n
      end

      # map transformation
      doubled = numbers.map do |n|
        n * 2
      end
      d0 = doubled[0]
      d5 = doubled[5]

      # select filtering
      evens = numbers.select do |n|
        (n % 2) == 0
      end
      ev_size = evens.size
      ev0 = evens[0]
      ev2 = evens[2]

      # acc: 21, doubled[0]: 2, doubled[5]: 12, evens: [2, 4, 6] (size: 3)
      if acc == 21 && d0 == 2 && d5 == 12 && ev_size == 3 && ev0 == 2 && ev2 == 6
        debug_puts "[CITRINE TEST] Arrays#higher_order_iteration: PASS"
      else
        debug_puts "[CITRINE TEST] Arrays#higher_order_iteration: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Arrays#higher_order_iteration: PASS")
  end

  it "verifies arrays of custom objects and property mutation on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("arr_objects_test")
    tc.source(<<-CR
      class Particle
        property x : Int32
        property y : Int32
        property active : Bool

        def initialize(@x, @y, @active)
        end

        def step(dx : Int32, dy : Int32)
          @x = @x + dx
          @y = @y + dy
        end
      end

      particles = [
        Particle.new(10, 20, true),
        Particle.new(30, 40, false),
        Particle.new(50, 60, true)
      ]

      # Step active particles
      idx = 0
      while idx < particles.size
        p = particles[idx]
        if p.active
          p.step(5, 10)
        end
        idx = idx + 1
      end

      p0_x = particles[0].x # 15
      p0_y = particles[0].y # 30
      p1_x = particles[1].x # 30 (not active)
      p2_x = particles[2].x # 55

      if p0_x == 15 && p0_y == 30 && p1_x == 30 && p2_x == 55
        debug_puts "[CITRINE TEST] Arrays#objects_collection: PASS"
      else
        debug_puts "[CITRINE TEST] Arrays#objects_collection: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Arrays#objects_collection: PASS")
  end
end
