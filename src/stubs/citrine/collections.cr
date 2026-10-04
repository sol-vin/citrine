# Citrine Zero-Heap Collections & In-Place Sorting for PS2
# Modular engine abstraction - require "citrine/collections"

module Citrine
  # A fixed-capacity, zero-heap collection designed for high-performance PlayStation 2 applications.
  # Preallocates its backing buffer to avoid dynamic memory fragmentation during frame rendering loops.
  class FixedList(T)
    # The maximum number of elements this list can hold without reallocating.
    getter capacity : Int32

    # The current number of active elements in the list.
    getter size : Int32

    @buffer : Array(T)

    # Creates a new `FixedList` with the given preallocated `capacity`.
    #
    # Parameters:
    # - `capacity`: Maximum element capacity (default: 64).
    def initialize(@capacity : Int32 = 64)
      @size = 0
      @buffer = Array(T).new(@capacity)
    end

    # Appends `item` to the list if space permits. Returns `self`.
    def <<(item : T) : self
      push(item)
    end

    # Pushes `item` to the end of the list if capacity has not been reached.
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

    # Removes and returns the last element in the list, or `nil` if empty.
    def pop : T?
      return nil if @size == 0
      @size -= 1
      @buffer[@size]
    end

    # Retrieves the element at `index`. Raises `IndexOutOfBounds` if index is invalid.
    def [](index : Int32) : T
      raise "Index out of bounds" if index < 0 || index >= @size
      @buffer[index]
    end

    # Sets the element at `index` to `val`. Raises `IndexOutOfBounds` if index is invalid.
    def []=(index : Int32, val : T)
      raise "Index out of bounds" if index < 0 || index >= @size
      @buffer[index] = val
    end

    # Returns the first element in the list, or `nil` if empty.
    def first : T?
      @size > 0 ? @buffer[0] : nil
    end

    # Returns the last element in the list, or `nil` if empty.
    def last : T?
      @size > 0 ? @buffer[@size - 1] : nil
    end

    # Returns true if the list contains zero elements.
    def empty? : Bool
      @size == 0
    end

    # Resets the active element count to 0 without freeing allocated memory.
    def clear
      @size = 0
    end

    # Iterates over each active element in the list.
    def each(&block : T -> Nil)
      idx = 0
      while idx < @size
        yield @buffer[idx]
        idx += 1
      end
    end

    # Iterates over each active element in the list along with its 0-based index.
    def each_with_index(&block : (T, Int32) -> Nil)
      idx = 0
      while idx < @size
        yield @buffer[idx], idx
        idx += 1
      end
    end

    # Performs an in-place insertion sort (O(1) auxiliary memory), ideal for PlayStation 2 Scratchpad RAM.
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

    # Sorts the list in-place using a custom key comparison block.
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
