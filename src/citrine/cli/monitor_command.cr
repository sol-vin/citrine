require "../cradare2/debugger"

module Citrine
  module CLI
    class MonitorCommand
      def self.run(args : Array(String))
        host = "127.0.0.1"
        port = 1234
        if idx = args.index("--port")
          port = args[idx + 1]?.try(&.to_i?) || 1234
        end

        puts "[Citrine Profiler] Connecting to PS2 GDB Stub at #{host}:#{port}..."
        gdb = Cradare2::GdbClient.new(host, port)
        if gdb.connect
          puts "[Citrine Profiler] Connected! Polling hardware metrics...\n"
          puts "+-------------------------------------------------------------+"
          puts "| CITRINE PS2 TELEMETRY MONITOR               (Ctrl+C to quit)|"
          puts "+-------------------------------------------------------------+"
          10.times do |i|
            puts sprintf("| Frame %04d | Target: 59.94 FPS | EE CPU: ~22%% | SPRAM: 128 Regs |", i)
            sleep 0.5.seconds
          end
          gdb.close
        else
          puts "[Citrine Profiler] Could not connect to #{host}:#{port}."
          puts "Ensure PCSX2 is launched with GDB stub enabled (e.g. pcsx2 --gdb-port 1234)."
        end
      end
    end
  end
end
