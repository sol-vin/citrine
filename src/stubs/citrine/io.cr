# Citrine IO::Memory stubs for PlayStation 2 EE runtime
# Allows user code to typecheck and use IO::Memory with zero overhead

module IO
  class Memory
    property pos : Int32
    property size : Int32

    def initialize(capacity : Int32 = 64)
      @pos = 0
      @size = 0
      @buffer = Bytes.new(capacity)
    end

    def write_byte(byte : UInt8 | Int32) : Nil
      # Native NativeId::MemoryIOWriteByte
    end

    def write(slice : Bytes | String) : Nil
      # Native NativeId::MemoryIOWrite
    end

    def print(obj) : Nil
      # Native NativeId::MemoryIOWrite
    end

    def puts(obj) : Nil
      # Native NativeId::MemoryIOPuts
    end

    def to_s : String
      # Native NativeId::MemoryIOToS
      ""
    end

    def rewind : Nil
      @pos = 0
    end

    def clear : Nil
      @pos = 0
      @size = 0
    end
  end
end
