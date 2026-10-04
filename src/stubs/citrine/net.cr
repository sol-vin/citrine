# Citrine Network Adapter, Sockets & Remote Telemetry
# Modular hardware abstraction - require "citrine/net"

module Citrine
  # PlayStation 2 Network Adapter (SMAP / PS2IP) subsystem providing IPv4 addressing,
  # UDP/TCP sockets, and remote developer telemetry consoles.
  module Net
    # Represents an IPv4 address composed of 4 octets.
    struct IPAddress
      # The 4 byte values forming the IPv4 address.
      property octets : StaticArray(UInt8, 4)

      # Creates an `IPAddress` from 4 numeric octets.
      def initialize(o1 : UInt8, o2 : UInt8, o3 : UInt8, o4 : UInt8)
        @octets = StaticArray[o1, o2, o3, o4]
      end

      # Parses a dotted-decimal IPv4 string (e.g. "192.168.1.100").
      # Defaults to localhost "127.0.0.1" on format error.
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

      # Formats address as dotted string (e.g. "192.168.1.1").
      def to_s : String
        "#{@octets[0]}.#{@octets[1]}.#{@octets[2]}.#{@octets[3]}"
      end
    end

    # Lightweight UDP socket for packet transmission over PS2IP lwIP stack.
    class UdpSocket
      # Bound local port number.
      getter port : Int32
      @bound : Bool

      # Creates a new UDP socket.
      def initialize
        @port = 0
        @bound = false
      end

      # Binds socket to a local UDP port.
      def bind(port : Int32)
        @port = port
        @bound = true
      end

      # Sends datagram payload string to target host and port.
      def send_to(data : String, host : String, port : Int32) : Int32
        # Emulates PS2IP lwIP UDP send
        data.bytesize
      end
    end

    # Stream-oriented TCP client socket.
    class TcpSocket
      # Connected remote host name or IP address.
      getter host : String?
      # Connected remote port number.
      getter port : Int32?
      @connected : Bool

      # Creates a new disconnected TCP socket.
      def initialize
        @connected = false
      end

      # Connects to remote host and port. Returns true on success.
      def connect(host : String, port : Int32) : Bool
        @host = host
        @port = port
        @connected = true
      end

      # Returns true if socket is actively connected.
      def connected? : Bool
        @connected
      end

      # Sends data buffer through established TCP connection. Returns bytes sent.
      def send(data : String) : Int32
        return 0 unless @connected
        data.bytesize
      end

      # Closes the connection.
      def close
        @connected = false
      end
    end

    @@remote_console_enabled : Bool = false
    @@remote_console_target : String = ""

    # Redirects logging and diagnostics to remote host over UDP for live debugging.
    #
    # Parameters:
    # - `ip`: Host IP address.
    # - `port`: UDP target port (default: 9999).
    def self.enable_remote_console(ip : String, port : Int32 = 9999)
      @@remote_console_enabled = true
      @@remote_console_target = "#{ip}:#{port}"
      Citrine.log("[NET] Remote console enabled -> #{@@remote_console_target}")
    end
  end
end
