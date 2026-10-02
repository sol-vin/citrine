require "socket"
require "../compiler/source_map"
require "../ast/types"

module Citrine
  module Cradare2
    class GdbClient
      getter host : String
      getter port : Int32
      getter socket : TCPSocket?
      getter source_map : SourceMap?

      def initialize(@host : String = "127.0.0.1", @port : Int32 = 1234, @source_map : SourceMap? = nil)
      end

      def connect : Bool
        begin
          @socket = TCPSocket.new(@host, @port)
          # Send initial ack
          if s = @socket
            s.sync = true
            s.write_byte('+'.ord.to_u8)
          end
          true
        rescue ex
          false
        end
      end

      def close
        @socket.try(&.close)
        @socket = nil
      end

      def send_command(cmd : String) : String
        s = @socket
        return "" unless s

        # Calculate checksum
        csum = 0
        cmd.each_byte { |b| csum = (csum + b) & 0xFF }
        packet = "$#{cmd}##{csum.to_s(16).rjust(2, '0')}"
        s.print(packet)

        # Wait for ack '+'
        ack = s.read_byte
        return "" unless ack == '+'.ord

        # Read response
        read_packet
      end

      private def read_packet : String
        s = @socket
        return "" unless s

        buf = IO::Memory.new
        in_packet = false

        while byte = s.read_byte
          char = byte.chr
          if char == '$'
            in_packet = true
            next
          elsif char == '#' && in_packet
            # Read 2 checksum bytes
            s.read_byte
            s.read_byte
            # Send ack
            s.write_byte('+'.ord.to_u8)
            break
          elsif in_packet
            buf << char
          end
        end

        buf.to_s
      end

      def read_memory(address : UInt64, length : Int32) : Bytes?
        cmd = sprintf("m%x,%x", address, length)
        resp = send_command(cmd)
        return nil if resp.empty? || resp.starts_with?("E")

        # Convert hex string to bytes
        bytes = Bytes.new(length)
        (0...length).each do |i|
          hex = resp[i * 2, 2]
          bytes[i] = hex.to_u8(16)
        end
        bytes
      end

      def read_spram_register(reg_index : Int32) : ValueType?
        return nil if reg_index < 0 || reg_index >= 1024

        spram_addr = 0x70000000_u64 + (reg_index.to_u64 * 16_u64)
        bytes = read_memory(spram_addr, 16)
        return nil unless bytes

        # First 4 bytes are type
        type_val = (bytes[0].to_u32) | (bytes[1].to_u32 << 8) | (bytes[2].to_u32 << 16) | (bytes[3].to_u32 << 24)
        ValueType.from_value?(type_val.to_u8)
      end
    end
  end
end
