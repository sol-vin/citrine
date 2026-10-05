require "file_utils"
require "../subsystems/controller"

module Citrine
  module Debugger
    # Host-side Virtual Controller Bridge for PCSX2
    #
    # Bridges host input devices (keyboard and XInput gamepads) directly into
    # the emulated PS2 Emotion Engine's Scratchpad RAM (SPRAM at 0x70000010)
    # via Fastmem direct virtual memory writes.
    class VirtualPadBridge
      property is_running : Bool = false
      property connected : Bool = false
      property pcsx2_log_path : String
      property fastmem_base : UInt64 = 0_u64
      property spram_button_addr : UInt64 = 0_u64
      property spram_base_addr : UInt64 = 0_u64
      property h_process : Void* = Pointer(Void).null
      property last_written_mask : UInt32 = 0_u32

      {% if flag?(:windows) %}
      @[Link("user32")]
      lib LibUser32
        fun GetAsyncKeyState(vKey : Int32) : Int16
      end

      @[Link("kernel32")]
      lib LibKernel32
        fun OpenProcess(dwDesiredAccess : UInt32, bInheritHandle : Int32, dwProcessId : UInt32) : Void*
        fun WriteProcessMemory(hProcess : Void*, lpBaseAddress : Void*, lpBuffer : Void*, nSize : LibC::SizeT, lpNumberOfBytesWritten : LibC::SizeT*) : Int32
        fun ReadProcessMemory(hProcess : Void*, lpBaseAddress : Void*, lpBuffer : Void*, nSize : LibC::SizeT, lpNumberOfBytesRead : LibC::SizeT*) : Int32
        fun CloseHandle(hObject : Void*) : Int32
      end

      @[Link("xinput9_1_0")]
      lib LibXInput
        struct XINPUT_GAMEPAD
          wButtons : UInt16
          bLeftTrigger : UInt8
          bRightTrigger : UInt8
          sThumbLX : Int16
          sThumbLY : Int16
          sThumbRX : Int16
          sThumbRY : Int16
        end

        struct XINPUT_STATE
          dwPacketNumber : UInt32
          gamepad : XINPUT_GAMEPAD
        end

        fun XInputGetState(dwUserIndex : UInt32, pState : XINPUT_STATE*) : UInt32
      end
      {% end %}

      def initialize(pcsx2_log_path : String? = nil)
        @pcsx2_log_path = pcsx2_log_path || Pcsx2Bridge.new.find_emulog_path || "logs/emulog.txt"
      end

      def clean_previous_log
        if File.exists?(@pcsx2_log_path)
          File.delete(@pcsx2_log_path) rescue nil
        end
      end

      def start(pid : Int64)
        @is_running = true
        spawn do
          run_bridge_worker(pid)
        end
      end

      def stop
        @is_running = false
        {% if flag?(:windows) %}
        if !@h_process.null?
          LibKernel32.CloseHandle(@h_process)
          @h_process = Pointer(Void).null
        end
        {% end %}
      end

      private def run_bridge_worker(pid : Int64)
        {% if flag?(:windows) %}
        # 1. Poll for Fastmem area address in PCSX2 emulog.txt (up to 6 seconds)
        found_base : UInt64? = nil
        120.times do
          break unless @is_running
          if File.exists?(@pcsx2_log_path)
            begin
              content = File.read(@pcsx2_log_path)
              matches = content.scan(/Fastmem area:\s+([0-9A-Fa-f]+)/)
              if !matches.empty?
                found_base = matches.last[1].to_u64(16)
                break
              end
            rescue
            end
          end
          sleep 0.05.seconds
        end

        return unless found_base && @is_running
        @fastmem_base = found_base
        @spram_base_addr = @fastmem_base + 0x70000000_u64
        @spram_button_addr = @fastmem_base + 0x70000010_u64

        # 2. Attach to PCSX2 process
        @h_process = LibKernel32.OpenProcess(0x1F0FFF_u32, 0, pid.to_u32)
        return if @h_process.null? || !@is_running

        # 3. Wait for EE kernel boot and SPRAM canary (0xdeadbeef or 0xcafe0001)
        canary_ready = false
        60.times do
          break unless @is_running
          canary = 0_u32
          read_bytes = 0_u64
          LibKernel32.ReadProcessMemory(@h_process, Pointer(Void).new(@spram_base_addr), pointerof(canary), 4, pointerof(read_bytes))
          if canary == 0xdeadbeef_u32 || canary == 0xcafe0001_u32
            canary_ready = true
            break
          end
          sleep 0.1.seconds
        end

        return unless canary_ready && @is_running
        @connected = true

        puts "\n[Citrine] ========================================================"
        puts "[Citrine] [CONTROLLER] Virtual Controller Bridge Connected to PCSX2!"
        puts "[Citrine] [CONTROLLER] Keyboard Controls:"
        puts "[Citrine]   [X] or [Space]   -> Cross (X)      : Primary Action / Select"
        puts "[Citrine]   [T] or [V]       -> Triangle       : Secondary / Menu"
        puts "[Citrine]   [C]              -> Circle         : Back / Cancel"
        puts "[Citrine]   [Z] or [S]       -> Square         : Action / Alternate"
        puts "[Citrine]   [Enter]          -> Start          : Start / Pause"
        puts "[Citrine]   [Arrows]         -> D-Pad"
        puts "[Citrine] [CONTROLLER] Gamepad Controls (Xbox / PS):"
        puts "[Citrine]   [A] / [Cross]    -> Cross (X)      : Primary Action"
        puts "[Citrine]   [Y] / [Triangle] -> Triangle       : Secondary"
        puts "[Citrine]   [B] / [Circle]   -> Circle         : Back"
        puts "[Citrine]   [X] / [Square]   -> Square         : Alternate"
        puts "[Citrine] ========================================================\n"

        # 4. Active 60 Hz polling and injection loop
        while @is_running
          mask = poll_inputs
          written_bytes = 0_u64
          LibKernel32.WriteProcessMemory(
            @h_process,
            Pointer(Void).new(@spram_button_addr),
            pointerof(mask),
            4,
            pointerof(written_bytes)
          )
          @last_written_mask = mask
          sleep 0.016.seconds
        end
        {% end %}
      end

      # Queries host keyboard state and XInput gamepad state, returning a combined 16-bit PS2 PadButton mask
      def poll_inputs : UInt32
        mask = 0_u32
        {% if flag?(:windows) %}
        # --- Keyboard Polling (LibUser32.GetAsyncKeyState) ---
        # Cross: 'X' (0x58) or Space (0x20)
        if (LibUser32.GetAsyncKeyState(0x58) < 0) || (LibUser32.GetAsyncKeyState(0x20) < 0)
          mask |= 0x4000_u32
        end

        # Triangle: 'T' (0x54) or 'V' (0x56)
        if (LibUser32.GetAsyncKeyState(0x54) < 0) || (LibUser32.GetAsyncKeyState(0x56) < 0)
          mask |= 0x1000_u32
        end

        # Circle: 'C' (0x43)
        if LibUser32.GetAsyncKeyState(0x43) < 0
          mask |= 0x2000_u32
        end

        # Square: 'Z' (0x5A) or 'S' (0x53)
        if (LibUser32.GetAsyncKeyState(0x5A) < 0) || (LibUser32.GetAsyncKeyState(0x53) < 0)
          mask |= 0x8000_u32
        end

        # Start: Enter (0x0D)
        if LibUser32.GetAsyncKeyState(0x0D) < 0
          mask |= 0x0008_u32
        end

        # Select: Escape (0x1B) or Backspace (0x08)
        if (LibUser32.GetAsyncKeyState(0x1B) < 0) || (LibUser32.GetAsyncKeyState(0x08) < 0)
          mask |= 0x0001_u32
        end

        # D-Pad Arrows
        if LibUser32.GetAsyncKeyState(0x26) < 0 # Up Arrow
          mask |= 0x0010_u32
        end
        if LibUser32.GetAsyncKeyState(0x28) < 0 # Down Arrow
          mask |= 0x0040_u32
        end
        if LibUser32.GetAsyncKeyState(0x25) < 0 # Left Arrow
          mask |= 0x0080_u32
        end
        if LibUser32.GetAsyncKeyState(0x27) < 0 # Right Arrow
          mask |= 0x0020_u32
        end

        # --- Gamepad Polling (XInput Controller 0) ---
        x_state = LibXInput::XINPUT_STATE.new
        if LibXInput.XInputGetState(0_u32, pointerof(x_state)) == 0
          btns = x_state.gamepad.wButtons
          mask |= 0x4000_u32 if (btns & 0x1000_u16) != 0 # A -> Cross
          mask |= 0x2000_u32 if (btns & 0x2000_u16) != 0 # B -> Circle
          mask |= 0x8000_u32 if (btns & 0x4000_u16) != 0 # X -> Square
          mask |= 0x1000_u32 if (btns & 0x8000_u16) != 0 # Y -> Triangle
          mask |= 0x0010_u32 if (btns & 0x0001_u16) != 0 # D-Up
          mask |= 0x0040_u32 if (btns & 0x0002_u16) != 0 # D-Down
          mask |= 0x0080_u32 if (btns & 0x0004_u16) != 0 # D-Left
          mask |= 0x0020_u32 if (btns & 0x0008_u16) != 0 # D-Right
          mask |= 0x0008_u32 if (btns & 0x0010_u16) != 0 # Start
          mask |= 0x0001_u32 if (btns & 0x0020_u16) != 0 # Back
          mask |= 0x0400_u32 if (btns & 0x0100_u16) != 0 # LB -> L1
          mask |= 0x0800_u32 if (btns & 0x0200_u16) != 0 # RB -> R1
        end
        {% end %}
        mask
      end
    end
  end
end
