# Citrine Network Adapter, Sockets & Remote Telemetry
# Modular hardware abstraction - require "citrine/net"

module Citrine
  module Net
    struct IPAddress
      property octets : StaticArray(UInt8, 4)

      def initialize(o1 : UInt8, o2 : UInt8, o3 : UInt8, o4 : UInt8)
        @octets = StaticArray[o1, o2, o3, o4]
      end

      def self.parse(str : String) : IPAddress
        parts = str.split(".")
        if parts.size == 4
          IPAddress.new(
            parts[0].to_u8? || 0_u8,
            parts[1].to_u8? || 0_u8,
            parts[2].to_u8? || 0_u8,
            parts[3].to_u8? || 0_u8
          )
        else
          IPAddress.new(127_u8, 0_u8, 0_u8, 1_u8)
        end
      end

      def to_s : String
        "#{@octets[0]}.#{@octets[1]}.#{@octets[2]}.#{@octets[3]}"
      end
    end

    class UdpSocket
      getter port : Int32
      @bound : Bool

      def initialize
        @port = 0
        @bound = false
      end

      def bind(port : Int32)
        @port = port
        @bound = true
      end

      def send_to(data : String, host : String, port : Int32) : Int32
        # Emulates PS2IP lwIP UDP send
        data.bytesize
      end
    end

    class TcpSocket
      getter host : String?
      getter port : Int32?
      @connected : Bool

      def initialize
        @connected = false
      end

      def connect(host : String, port : Int32) : Bool
        @host = host
        @port = port
        @connected = true
      end

      def connected? : Bool
        @connected
      end

      def send(data : String) : Int32
        return 0 unless @connected
        data.bytesize
      end

      def close
        @connected = false
      end
    end

    @@remote_console_enabled : Bool = false
    @@remote_console_target : String = ""

    def self.enable_remote_console(ip : String, port : Int32 = 9999)
      @@remote_console_enabled = true
      @@remote_console_target = "#{ip}:#{port}"
      Citrine.log("[NET] Remote console enabled -> #{@@remote_console_target}")
    end
  end
end
