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
        if env_path = ENV["PCSX2_PATH"]?
          return env_path if File.exists?(env_path)
        end

        home = Path.home
        # Check standard installation locations on Windows and PATH
        candidates = [
          "C:\\Program Files\\PCSX2\\pcsx2-qt.exe",
          "C:\\Program Files\\PCSX2\\pcsx2-qtx64.exe",
          "C:\\Program Files\\PCSX2\\pcsx2-qtx64-avx2.exe",
          "C:\\Program Files\\PCSX2\\pcsx2.exe",
          "C:\\Program Files (x86)\\PCSX2\\pcsx2-qt.exe",
          "C:\\Program Files (x86)\\PCSX2\\pcsx2-qtx64.exe",
          "C:\\Program Files (x86)\\PCSX2\\pcsx2.exe",
          home.join("AppData", "Local", "Programs", "PCSX2", "pcsx2-qt.exe").to_s,
          home.join("AppData", "Local", "Programs", "PCSX2", "pcsx2-qtx64.exe").to_s,
          home.join("Documents", "PCSX2", "pcsx2-qt.exe").to_s,
          home.join("Documents", "PCSX2", "pcsx2-qtx64.exe").to_s,
          home.join("Documents", "PCSX2", "pcsx2.exe").to_s
        ]

        candidates.each do |c|
          return c if File.exists?(c)
        end

        Process.find_executable("pcsx2-qt") || Process.find_executable("pcsx2-qtx64") || Process.find_executable("pcsx2")
      end

      def find_emulog_path : String?
        if env_log = ENV["PCSX2_LOG"]?
          return env_log
        end

        home = Path.home
        candidates = [
          home.join("Documents", "PCSX2", "logs", "emulog.txt").to_s,
          "C:\\Program Files\\PCSX2\\logs\\emulog.txt",
          "C:\\Users\\Ian\\Documents\\PCSX2\\logs\\emulog.txt",
          home.join("AppData", "Roaming", "PCSX2", "logs", "emulog.txt").to_s,
          home.join("AppData", "Local", "PCSX2", "logs", "emulog.txt").to_s,
          File.expand_path("logs/emulog.txt")
        ]

        candidates.each do |c|
          return c if File.exists?(c)
        end

        # Return primary default
        home.join("Documents", "PCSX2", "logs", "emulog.txt").to_s
      end

      def find_inis_path : String?
        if env_inis = ENV["PCSX2_INIS"]?
          return env_inis
        end

        home = Path.home
        candidates = [
          home.join("Documents", "PCSX2", "inis", "PCSX2.ini").to_s,
          "C:\\Program Files\\PCSX2\\inis\\PCSX2.ini",
          "C:\\Users\\Ian\\Documents\\PCSX2\\inis\\PCSX2.ini",
          home.join("AppData", "Roaming", "PCSX2", "inis", "PCSX2.ini").to_s,
          File.expand_path("inis/PCSX2.ini")
        ]

        candidates.each do |c|
          return c if File.exists?(c)
        end

        home.join("Documents", "PCSX2", "inis", "PCSX2.ini").to_s
      end

      def ensure_logging_configured : Bool
        ini_file = @inis_path
        return false unless ini_file && File.exists?(ini_file)

        content = File.read(ini_file)
        modified = false

        if content.includes?("EnableEEConsole = false")
          content = content.gsub("EnableEEConsole = false", "EnableEEConsole = true")
          modified = true
        elsif !content.includes?("EnableEEConsole = true")
          if content.includes?("[Logging]")
            content = content.sub("[Logging]", "[Logging]\nEnableEEConsole = true")
          else
            content += "\n[Logging]\nEnableEEConsole = true\n"
          end
          modified = true
        end

        if content.includes?("EnableFileLogging = false")
          content = content.gsub("EnableFileLogging = false", "EnableFileLogging = true")
          modified = true
        elsif !content.includes?("EnableFileLogging = true")
          if content.includes?("[Logging]")
            content = content.sub("[Logging]", "[Logging]\nEnableFileLogging = true")
          else
            content += "\n[Logging]\nEnableFileLogging = true\n"
          end
          modified = true
        end

        if content.includes?("EnableEESIOInput = false")
          content = content.gsub("EnableEESIOInput = false", "EnableEESIOInput = true")
          modified = true
        elsif !content.includes?("EnableEESIOInput = true")
          if content.includes?("[Logging]")
            content = content.sub("[Logging]", "[Logging]\nEnableEESIOInput = true\nShowEESIOInput = true")
          else
            content += "\n[Logging]\nEnableEESIOInput = true\nShowEESIOInput = true\n"
          end
          modified = true
        end

        if content.includes?("[Pad1]")
          if content =~ /Cross\s*=\s*([^\r\n]+)/
            curr_cross = $1.strip
            unless curr_cross.includes?("Keyboard/X")
              content = content.sub(/Cross\s*=\s*[^\r\n]+/, "Cross = Keyboard/X, #{curr_cross}")
              modified = true
            end
          else
            content = content.sub("[Pad1]", "[Pad1]\nCross = Keyboard/X")
            modified = true
          end
        end

        unless content.includes?("[Filenames]") && content.includes?("BIOS =")
          if content.includes?("[Filenames]")
            content = content.sub("[Filenames]", "[Filenames]\nBIOS = SCPH-39001_BIOS_V7_USA_160.BIN")
          else
            content += "\n[Filenames]\nBIOS = SCPH-39001_BIOS_V7_USA_160.BIN\n"
          end
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

        home = Path.home
        log_candidates = [
          @log_path,
          home.join("Documents", "PCSX2", "logs", "emulog.txt").to_s,
          "C:\\Program Files\\PCSX2\\logs\\emulog.txt",
          home.join("AppData", "Roaming", "PCSX2", "logs", "emulog.txt").to_s,
          home.join("AppData", "Local", "PCSX2", "logs", "emulog.txt").to_s,
          File.expand_path("logs/emulog.txt")
        ].compact.uniq

        log_candidates.each do |cand|
          if File.exists?(cand)
            5.times do
              begin
                File.delete(cand)
                break
              rescue
                sleep 0.05.seconds
              end
            end
          end
        end
        start_pos = 0_i64

        # Spawn PCSX2 process with stdout and stderr pipes captured
        process = Process.new(
          bin,
          args,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe
        )
        @is_running = true

        # Start background fibers to capture stdout and stderr directly
        spawn do
          if out = process.output?
            out.each_line do |line|
              line_clean = line.strip
              unless line_clean.empty?
                @log_history << line_clean
                block.call(line_clean)
                check_for_faults(line_clean)
              end
            end
          end
        rescue
        end

        spawn do
          if err = process.error?
            err.each_line do |line|
              line_clean = line.strip
              unless line_clean.empty?
                @log_history << line_clean
                block.call(line_clean)
                check_for_faults(line_clean)
              end
            end
          end
        rescue
        end

        # Start background fiber to tail emulog.txt across candidate paths
        stop_tailing = false
        current_offset = start_pos
        tail_fiber = spawn do
          while !stop_tailing
            active_log = log_candidates.find { |cand| File.exists?(cand) }
            if active_log
              begin
                file_size = File.size(active_log)
                if file_size < current_offset
                  current_offset = 0_i64
                end
                if file_size > current_offset
                  File.open(active_log, "r") do |f|
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
              kill_process_tree(process)
              status = process.wait rescue nil
              break
            end
          end

          unless process.terminated?
            kill_process_tree(process)
            status = process.wait rescue nil
          end
        else
          # Interactive wait until user closes PCSX2
          status = process.wait
        end

        stop_tailing = true

        # Final drain to capture any remaining lines flushed on exit
        if active_log = log_candidates.find { |cand| File.exists?(cand) }
          begin
            file_size = File.size(active_log)
            if file_size < current_offset
              current_offset = 0_i64
            end
            if file_size > current_offset
              File.open(active_log, "r") do |f|
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
          end
        end

        @is_running = false
        status
      end

      private def kill_process_tree(process : Process)
        return if process.terminated?
        {% if flag?(:windows) %}
          Process.run("taskkill", ["/F", "/T", "/PID", process.pid.to_s]) rescue nil
        {% else %}
          process.terminate rescue nil
        {% end %}
        10.times do
          break if process.terminated?
          sleep 0.1.seconds
        end
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
