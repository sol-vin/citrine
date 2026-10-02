# Citrine Zero-Heap Collections & In-Place Sorting for PS2
# Modular engine abstraction - require "citrine/collections"

module Citrine
  class FixedList(T)
    getter capacity : Int32
    getter size : Int32
    @buffer : Array(T)

    def initialize(@capacity : Int32 = 64)
      @size = 0
      @buffer = Array(T).new(@capacity)
    end

    def <<(item : T) : self
      push(item)
    end

    def push(item : T) : self
      if @size < @capacity
        if @size < @buffer.size
          @buffer[@size] = item
        else
          @buffer << item
        end
        @size += 1
      end
      self
    end

    def pop : T?
      return nil if @size == 0
      @size -= 1
      @buffer[@size]
    end

    def [](index : Int32) : T
      raise "Index out of bounds" if index < 0 || index >= @size
      @buffer[index]
    end

    def []=(index : Int32, val : T)
      raise "Index out of bounds" if index < 0 || index >= @size
      @buffer[index] = val
    end

    def first : T?
      @size > 0 ? @buffer[0] : nil
    end

    def last : T?
      @size > 0 ? @buffer[@size - 1] : nil
    end

    def empty? : Bool
      @size == 0
    end

    def clear
      @size = 0
    end

    def each(&block : T -> Nil)
      idx = 0
      while idx < @size
        yield @buffer[idx]
        idx += 1
      end
    end

    def each_with_index(&block : (T, Int32) -> Nil)
      idx = 0
      while idx < @size
        yield @buffer[idx], idx
        idx += 1
      end
    end

    # In-place insertion sort (O(1) auxiliary memory for PS2 scratchpad)
    def sort!
      return if @size <= 1
      i = 1
      while i < @size
        key = @buffer[i]
        j = i - 1
        while j >= 0 && @buffer[j] > key
          @buffer[j + 1] = @buffer[j]
          j -= 1
        end
        @buffer[j + 1] = key
        i += 1
      end
    end

    def sort_by!(&block : T -> Int32)
      return if @size <= 1
      i = 1
      while i < @size
        key = @buffer[i]
        key_val = yield key
        j = i - 1
        while j >= 0 && (yield @buffer[j]) > key_val
          @buffer[j + 1] = @buffer[j]
          j -= 1
        end
        @buffer[j + 1] = key
        i += 1
      end
    end
  end
end
