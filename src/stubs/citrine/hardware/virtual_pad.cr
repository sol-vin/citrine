module Citrine
  module Hardware
    # DualShock 2 Virtual Pad state machine simulating PlayStation 2 controller hardware registers.
    # Maintains independent bitmasks, analog stick axes, and dual vibration motors for Port 0 and Port 1.
    class VirtualPad
      @@buttons_curr : Array(UInt32) = [0_u32, 0_u32]
      @@buttons_prev : Array(UInt32) = [0_u32, 0_u32]
      @@analog : Array(Array(UInt8)) = [
        [128_u8, 128_u8, 128_u8, 128_u8],
        [128_u8, 128_u8, 128_u8, 128_u8]
      ]
      @@rumble_small : Array(UInt8) = [0_u8, 0_u8]
      @@rumble_large : Array(UInt8) = [0_u8, 0_u8]

      # Resets all controller state to center/neutral across both ports.
      def self.reset
        @@buttons_curr = [0_u32, 0_u32]
        @@buttons_prev = [0_u32, 0_u32]
        @@analog = [
          [128_u8, 128_u8, 128_u8, 128_u8],
          [128_u8, 128_u8, 128_u8, 128_u8]
        ]
        @@rumble_small = [0_u8, 0_u8]
        @@rumble_large = [0_u8, 0_u8]
      end

      # Advances the simulation frame, committing current button state to previous for edge detection.
      def self.update_frame
        @@buttons_prev[0] = @@buttons_curr[0]
        @@buttons_prev[1] = @@buttons_curr[1]
      end

      # Sets digital button bitmask for the specified controller port.
      def self.set_buttons(port : Int32, mask : UInt32)
        return unless port == 0 || port == 1
        @@buttons_curr[port] = mask
      end

      # Presses a button on the specified port.
      def self.press_button(port : Int32, button : ::Button | Citrine::Button | PadButton | UInt8 | Int32)
        return unless port == 0 || port == 1
        val = button.is_a?(Int) ? button : button.value
        @@buttons_curr[port] |= (1_u32 << val)
      end

      # Releases a button on the specified port.
      def self.release_button(port : Int32, button : ::Button | Citrine::Button | PadButton | UInt8 | Int32)
        return unless port == 0 || port == 1
        val = button.is_a?(Int) ? button : button.value
        @@buttons_curr[port] &= ~(1_u32 << val)
      end

      # Sets raw 8-bit analog axis value (0..255, center 128) for the specified port and axis.
      def self.set_analog(port : Int32, axis : Int32, value : UInt8)
        return unless (port == 0 || port == 1) && axis >= 0 && axis < 4
        @@analog[port][axis] = value
      end

      # Gets raw 8-bit analog axis value (0..255).
      def self.get_raw_analog(port : Int32, axis : Int32) : UInt8
        return 128_u8 unless (port == 0 || port == 1) && axis >= 0 && axis < 4
        @@analog[port][axis]
      end

      # Returns true if button is currently held down on port.
      def self.button_down?(port : Int32, button : ::Button | Citrine::Button | PadButton | UInt8 | Int32) : Bool
        return false unless port == 0 || port == 1
        val = button.is_a?(Int) ? button : button.value
        mask = 1_u32 << val
        (@@buttons_curr[port] & mask) != 0
      end

      # Returns true on rising edge transition (pressed this frame) on port.
      def self.button_pressed?(port : Int32, button : ::Button | Citrine::Button | PadButton | UInt8 | Int32) : Bool
        return false unless port == 0 || port == 1
        val = button.is_a?(Int) ? button : button.value
        mask = 1_u32 << val
        curr = (@@buttons_curr[port] & mask) != 0
        prev = (@@buttons_prev[port] & mask) != 0
        curr && !prev
      end

      # Returns true on falling edge transition (released this frame) on port.
      def self.button_released?(port : Int32, button : ::Button | Citrine::Button | PadButton | UInt8 | Int32) : Bool
        return false unless port == 0 || port == 1
        val = button.is_a?(Int) ? button : button.value
        mask = 1_u32 << val
        curr = (@@buttons_curr[port] & mask) != 0
        prev = (@@buttons_prev[port] & mask) != 0
        !curr && prev
      end

      # Returns normalized analog stick float value (-1.0 to 1.0) with deadzone applied.
      def self.get_analog(port : Int32, axis : Int32) : Float32
        return 0.0_f32 unless (port == 0 || port == 1) && axis >= 0 && axis < 4
        raw = @@analog[port][axis].to_i32
        # Normalize 0..255 where 128 is center
        diff = raw - 128
        # Deadzone threshold (+/- 12 around 128)
        return 0.0_f32 if diff.abs <= 12
        (diff.to_f32 / 127.0_f32).clamp(-1.0_f32, 1.0_f32)
      end

      # Sets vibration rumble motors for port.
      def self.set_rumble(port : Int32, small : UInt8, large : UInt8)
        return unless port == 0 || port == 1
        @@rumble_small[port] = small
        @@rumble_large[port] = large
      end

      # Gets small vibration motor state (0 or 1).
      def self.get_rumble_small(port : Int32) : UInt8
        return 0_u8 unless port == 0 || port == 1
        @@rumble_small[port]
      end

      # Gets large vibration motor speed (0..255).
      def self.get_rumble_large(port : Int32) : UInt8
        return 0_u8 unless port == 0 || port == 1
        @@rumble_large[port]
      end
    end
  end
end
