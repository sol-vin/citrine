# Citrine IO::Memory stubs for PlayStation 2 EE runtime
# Allows user code to typecheck and use IO::Memory with zero overhead

{% unless @top_level.has_constant?("IO") %}
# Abstract stream input/output base class.
abstract class IO
  # In-memory byte stream buffer mapping directly to Citrine VM native memory routines.
  class Memory
    # Current cursor position within the memory buffer.
    property pos : Int32
    # Total written byte size of the buffer.
    property size : Int32

    # Creates a new in-memory IO stream with initial `capacity`.
    def initialize(capacity : Int32 = 64)
      @pos = 0
      @size = 0
      @buffer = Bytes.new(capacity)
    end

    # Writes a single 8-bit unsigned integer byte to the stream at current position.
    def write_byte(byte : UInt8 | Int32) : Nil
      # Native NativeId::MemoryIOWriteByte
    end

    # Writes a raw byte slice or string directly to the stream.
    def write(slice : Bytes | String) : Nil
      # Native NativeId::MemoryIOWrite
    end

    # Formats and writes `obj` to the stream without appending a newline.
    def print(obj) : Nil
      # Native NativeId::MemoryIOWrite
    end

    # Formats and writes `obj` followed by a newline `\n` to the stream.
    def puts(obj) : Nil
      # Native NativeId::MemoryIOPuts
    end

    # Returns the accumulated stream contents as a String.
    def to_s : String
      # Native NativeId::MemoryIOToS
      ""
    end

    # Repositions stream read/write cursor back to beginning (offset 0).
    def rewind : Nil
      @pos = 0
    end

    # Resets cursor position and size back to 0.
    def clear : Nil
      @pos = 0
      @size = 0
    end
  end
end
{% end %}
