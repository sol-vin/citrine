require "process"
require "file_utils"
require "socket"

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
        nogui : Bool = true,
        debugger_gui : Bool = false,
        gdb_port : Int32? = nil,
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
        end
        if nogui
          args << "-nogui"
        end

        if debugger_gui
          args << "-debugger"
        end

        if port = gdb_port
          args << "-gdb" << port.to_s
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
          # Interactive wait until user closes PCSX2 (sleep yields to tail fibers)
          while !process.terminated?
            sleep 0.05.seconds
          end
          status = process.wait rescue nil
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

      # Injects a 16-bit button mask into PS2 SPRAM 0x70000010 via GDB Stub
      def inject_button_gdb(button_mask : UInt16, gdb_port : Int32 = 28011) : Bool
        begin
          client = TCPSocket.new("127.0.0.1", gdb_port, connect_timeout: 1.second)
          # GDB memory write packet: $M70000010,4:xxxx0000#checksum
          # Write Little-Endian 32-bit: byte0 = mask & 0xFF, byte1 = (mask >> 8) & 0xFF, byte2 = 0, byte3 = 0
          b0 = (button_mask & 0xFF).to_s(16).rjust(2, '0')
          b1 = ((button_mask >> 8) & 0xFF).to_s(16).rjust(2, '0')
          payload = "M70000010,4:#{b0}#{b1}0000"
          checksum = payload.bytes.reduce(0) { |acc, b| (acc + b) & 0xFF }.to_s(16).rjust(2, '0')
          packet = "$#{payload}##{checksum}"
          client << packet
          client.flush
          client.close
          true
        rescue
          false
        end
      end

      # Captures a screenshot from the running PCSX2 instance to output_path (PNG format).
      # Returns true on success.
      def capture_screenshot(output_path : String) : Bool
        abs_output = File.expand_path(output_path).gsub('/', '\\')
        Dir.mkdir_p(File.dirname(abs_output))

        {% if flag?(:windows) %}
        # Check PCSX2 snaps directory
        home = Path.home
        snap_dirs = [
          home.join("Documents", "PCSX2", "snaps").to_s,
          "C:\\Program Files\\PCSX2\\snaps",
          "C:\\Users\\Ian\\Documents\\PCSX2\\snaps"
        ]
        active_snap_dir = snap_dirs.find { |d| Dir.exists?(d) } || snap_dirs.first
        before_snaps = Dir.glob(File.join(active_snap_dir, "*.png").gsub('\\', '/')) rescue [] of String

        script = <<-POWERSHELL
        $ErrorActionPreference = 'SilentlyContinue'
        $env:LIB = ""
        Add-Type -AssemblyName System.Drawing
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        public class WinSnap {
            [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
            [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
            [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
            [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
            [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        }
        "@
        $proc = Get-Process -Name "pcsx2-qt" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [WinSnap]::SetForegroundWindow($proc.MainWindowHandle)
            Start-Sleep -Milliseconds 150
            # Send F8 via hardware keybd_event, PostMessage, and WScript.Shell
            [WinSnap]::keybd_event(0x77, 0, 0, 0)
            [WinSnap]::keybd_event(0x77, 0, 2, 0)
            [WinSnap]::PostMessage($proc.MainWindowHandle, 0x0100, [IntPtr]0x77, [IntPtr]0)
            [WinSnap]::PostMessage($proc.MainWindowHandle, 0x0101, [IntPtr]0x77, [IntPtr]0)
            $ws = New-Object -ComObject WScript.Shell
            $ws.AppActivate($proc.Id)
            $ws.SendKeys('{F8}')
            Start-Sleep -Milliseconds 800

            # GDI Capture fallback
            $rect = New-Object WinSnap+RECT
            [WinSnap]::GetWindowRect($proc.MainWindowHandle, [ref]$rect)
            $w = [Math]::Max(100, $rect.Right - $rect.Left)
            $h = [Math]::Max(100, $rect.Bottom - $rect.Top)
            $bmp = New-Object System.Drawing.Bitmap($w, $h)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
            $g.Dispose()
            $bmp.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        POWERSHELL

        Process.run("powershell", ["-NoProfile", "-Command", "$outputPath = '#{abs_output.gsub('\'', "''")}'; " + script], env: {"LIB" => ""}) rescue nil

        # If F8 produced a native GS framebuffer snapshot in snaps/, use that high-res file!
        8.times do
          after_snaps = (Dir.glob(File.join(active_snap_dir, "*.png").gsub('\\', '/')) rescue [] of String) - before_snaps
          if newest = after_snaps.last?
            FileUtils.cp(newest, abs_output) rescue nil
            break
          end
          sleep 0.25.seconds
        end
        {% end %}

        File.exists?(abs_output) && File.size(abs_output) > 0
      end

      # Copies a captured screenshot to the Antigravity conversation artifact directory for inline viewing.
      def copy_to_artifacts(src_png : String, artifact_name : String = "screen.png") : String?
        artifact_dir = ENV["ANTIGRAVITY_ARTIFACT_DIR"]? ||
                       "C:/Users/Ian/.gemini/antigravity/brain/6d2cfb99-03d5-4b98-a12a-f5c4df90f68d"
        if Dir.exists?(artifact_dir) && File.exists?(src_png)
          dest = File.join(artifact_dir, artifact_name)
          FileUtils.cp(src_png, dest) rescue nil
          return dest
        end
        nil
      end

      # Computes 2-digit hex checksum for GDB RSP packet data
      def self.gdb_checksum(cmd : String) : String
        sum = cmd.bytes.reduce(0_u8) { |acc, b| acc &+ b }
        sum.to_s(16).rjust(2, '0').downcase
      end

      # Sends a GDB RSP command packet and reads the response payload
      def self.send_gdb_packet(socket : IO, cmd : String) : String?
        chk = gdb_checksum(cmd)
        socket.print("$#{cmd}##{chk}")
        socket.flush

        # Expect ACK '+'
        ack = socket.read_char
        return nil unless ack == '+'

        # Wait for '$' response start
        char = socket.read_char
        while char && char != '$'
          char = socket.read_char
        end
        return nil unless char == '$'

        resp = IO::Memory.new
        while (c = socket.read_char) && c != '#'
          resp << c
        end
        # Read 2 checksum characters
        socket.read_char
        socket.read_char

        resp.to_s
      end

      # Connects to PCSX2's GDB stub (port 28011 by default) and reads a block of EE memory.
      def read_memory_gdb(address : UInt64, length : Int32, port : Int32 = 28011) : Bytes?
        begin
          socket = TCPSocket.new("127.0.0.1", port, connect_timeout: 1.second)
          socket.read_timeout = 2.seconds

          # Send interrupt byte (0x03) to briefly halt EE CPU if running
          socket.write_byte(0x03_u8)
          socket.flush
          sleep 0.05.seconds

          # Drain any stop packet
          socket.read_timeout = 0.2.seconds
          begin
            buf = Bytes.new(128)
            socket.read(buf)
          rescue
          end
          socket.read_timeout = 2.seconds

          # GDB command: m<hex_addr>,<hex_length>
          cmd = "m#{address.to_s(16)},#{length.to_s(16)}"
          resp = Pcsx2Bridge.send_gdb_packet(socket, cmd)

          # Send continue '$c#63' so EE execution resumes seamlessly
          Pcsx2Bridge.send_gdb_packet(socket, "c") rescue nil
          socket.close rescue nil

          if resp && !resp.starts_with?("E")
            bytes = Bytes.new(resp.size // 2)
            (0...bytes.size).each do |i|
              bytes[i] = resp[i * 2, 2].to_u8(16)
            end
            bytes
          else
            nil
          end
        rescue
          nil
        end
      end

      # Reads the 32-bit SPRAM canary at 0x70000000 via GDB
      def inspect_spram_canary_gdb(port : Int32 = 28011) : UInt32?
        if bytes = read_memory_gdb(0x70000000_u64, 4, port)
          return nil unless bytes.size == 4
          # Little-endian 32-bit word
          bytes[0].to_u32 | (bytes[1].to_u32 << 8) | (bytes[2].to_u32 << 16) | (bytes[3].to_u32 << 24)
        else
          nil
        end
      end
    end
  end
end
