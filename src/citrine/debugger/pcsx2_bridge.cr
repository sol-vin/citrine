require "process"
require "file_utils"

module Citrine
  module Debugger
    class Pcsx2Bridge
      getter pcsx2_path : String?
      getter log_path : String?
      getter inis_path : String?
      getter is_running : Bool = false
      getter last_panic_message : String? = nil
      getter last_crash_pc : UInt32? = nil
      getter log_history : Array(String) = [] of String

      def initialize
        @pcsx2_path = find_pcsx2_executable
        @log_path = find_emulog_path
        @inis_path = find_inis_path
      end

      def find_pcsx2_executable : String?
        # Check standard installation locations on Windows and PATH
        candidates = [
          "C:\\Program Files\\PCSX2\\pcsx2-qt.exe",
          "C:\\Program Files (x86)\\PCSX2\\pcsx2-qt.exe",
          "C:\\Program Files\\PCSX2\\pcsx2.exe",
          File.expand_path("~/AppData/Local/Programs/PCSX2/pcsx2-qt.exe"),
          File.expand_path("~/Documents/PCSX2/pcsx2-qt.exe")
        ]

        candidates.each do |c|
          return c if File.exists?(c)
        end

        Process.find_executable("pcsx2-qt") || Process.find_executable("pcsx2")
      end

      def find_emulog_path : String?
        candidates = [
          File.expand_path("~/Documents/PCSX2/logs/emulog.txt"),
          "C:\\Users\\Ian\\Documents\\PCSX2\\logs\\emulog.txt",
          File.expand_path("~/AppData/Roaming/PCSX2/logs/emulog.txt"),
          File.expand_path("~/AppData/Local/PCSX2/logs/emulog.txt")
        ]

        candidates.each do |c|
          return c if File.exists?(c)
        end

        # Return primary default
        File.expand_path("~/Documents/PCSX2/logs/emulog.txt")
      end

      def find_inis_path : String?
        candidates = [
          File.expand_path("~/Documents/PCSX2/inis/PCSX2.ini"),
          "C:\\Users\\Ian\\Documents\\PCSX2\\inis\\PCSX2.ini",
          File.expand_path("~/AppData/Roaming/PCSX2/inis/PCSX2.ini")
        ]

        candidates.each do |c|
          return c if File.exists?(c)
        end

        File.expand_path("~/Documents/PCSX2/inis/PCSX2.ini")
      end

      def ensure_logging_configured : Bool
        ini_file = @inis_path
        return false unless ini_file && File.exists?(ini_file)

        content = File.read(ini_file)
        modified = false

        if content.includes?("EnableEEConsole = false")
          content = content.gsub("EnableEEConsole = false", "EnableEEConsole = true")
          modified = true
        end

        if content.includes?("EnableFileLogging = false")
          content = content.gsub("EnableFileLogging = false", "EnableFileLogging = true")
          modified = true
        end

        if modified
          File.write(ini_file, content)
        end
        true
      rescue
        false
      end

      def spawn_pcsx2(
        iso_path : String,
        batch : Bool = false,
        debugger_gui : Bool = false,
        timeout : Time::Span? = nil,
        &block : String -> Nil
      ) : Process::Status?
        bin = @pcsx2_path
        unless bin && File.exists?(bin)
          raise "PCSX2 executable not found. Please install PCSX2 or add it to PATH."
        end

        ensure_logging_configured

        args = [] of String
        args << "-fastboot"
        args << "-earlyconsolelog"

        if batch
          args << "-batch"
          args << "-nogui"
        end

        if debugger_gui
          args << "-debugger"
        end

        args << File.expand_path(iso_path)

        log_file = @log_path
        start_pos = 0_i64
        if log_file && File.exists?(log_file)
          start_pos = File.size(log_file)
        end

        # Spawn PCSX2 process
        process = Process.new(bin, args)
        @is_running = true

        # Start background fiber to tail emulog.txt
        stop_tailing = false
        tail_fiber = spawn do
          current_offset = start_pos
          while !stop_tailing
            if log_file && File.exists?(log_file)
              begin
                file_size = File.size(log_file)
                if file_size > current_offset
                  File.open(log_file, "r") do |f|
                    f.seek(current_offset)
                    while line = f.gets
                      line_clean = line.strip
                      unless line_clean.empty?
                        @log_history << line_clean
                        block.call(line_clean)
                        check_for_faults(line_clean)
                      end
                    end
                    current_offset = f.pos
                  end
                end
              rescue
                # Ignore concurrent read access errors
              end
            end
            sleep 0.05.seconds
          end
        end

        status : Process::Status? = nil

        if timeout
          # Run with supervisor timeout
          elapsed = 0.0
          interval = 0.1
          while elapsed < timeout.total_seconds
            sleep interval.seconds
            elapsed += interval

            # Check if process terminated on its own
            if process.terminated?
              status = process.wait
              break
            end

            # If panic was detected, terminate gracefully
            if @last_panic_message
              process.terminate
              status = process.wait
              break
            end
          end

          unless process.terminated?
            process.terminate
            status = process.wait
          end
        else
          # Interactive wait until user closes PCSX2
          status = process.wait
        end

        stop_tailing = true
        @is_running = false
        status
      end

      private def check_for_faults(line : String)
        if line.includes?("[CITRINE PANIC]")
          @last_panic_message = line
          if match = line.match(/PC:\s*(\d+)/i)
            @last_crash_pc = match[1].to_u32?
          end
        elsif line.includes?("Instruction Watchdog Timeout")
          @last_panic_message = line
        elsif line.includes?("Unhandled Exception") || line.includes?("TLB Miss") || line.includes?("Bus Error")
          @last_panic_message = line
        end
      end
    end
  end
end
