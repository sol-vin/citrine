# Citrine USB Peripheral Drivers (Keyboard & Mouse)
# Modular hardware abstraction - require "citrine/input/usb"

module Citrine
  module Input
    module Keyboard
      KEY_SPACE     = 32
      KEY_APOSTROPHE= 39
      KEY_COMMA     = 44
      KEY_MINUS     = 45
      KEY_PERIOD    = 46
      KEY_SLASH     = 47
      KEY_ZERO      = 48
      KEY_ONE       = 49
      KEY_TWO       = 50
      KEY_THREE     = 51
      KEY_FOUR      = 52
      KEY_FIVE      = 53
      KEY_SIX       = 54
      KEY_SEVEN     = 55
      KEY_EIGHT     = 56
      KEY_NINE      = 57
      KEY_A         = 65
      KEY_B         = 66
      KEY_C         = 67
      KEY_D         = 68
      KEY_E         = 69
      KEY_F         = 70
      KEY_G         = 71
      KEY_H         = 72
      KEY_I         = 73
      KEY_J         = 74
      KEY_K         = 75
      KEY_L         = 76
      KEY_M         = 77
      KEY_N         = 78
      KEY_O         = 79
      KEY_P         = 80
      KEY_Q         = 81
      KEY_R         = 82
      KEY_S         = 83
      KEY_T         = 84
      KEY_U         = 85
      KEY_V         = 86
      KEY_W         = 87
      KEY_X         = 88
      KEY_Y         = 89
      KEY_Z         = 90
      KEY_ESCAPE    = 256
      KEY_ENTER     = 257
      KEY_TAB       = 258
      KEY_BACKSPACE = 259
      KEY_RIGHT     = 262
      KEY_LEFT      = 263
      KEY_DOWN      = 264
      KEY_UP        = 265

      @@key_states = StaticArray(Bool, 512).new(false)

      def self.key_down?(key : Int32) : Bool
        return false if key < 0 || key >= 512
        @@key_states[key]
      end

      def self.key_pressed?(key : Int32) : Bool
        key_down?(key)
      end

      def self.simulate_key(key : Int32, down : Bool)
        if key >= 0 && key < 512
          @@key_states[key] = down
        end
      end
    end

    module Mouse
      MOUSE_BUTTON_LEFT   = 0
      MOUSE_BUTTON_RIGHT  = 1
      MOUSE_BUTTON_MIDDLE = 2

      @@x : Int32 = 320
      @@y : Int32 = 224
      @@delta_x : Int32 = 0
      @@delta_y : Int32 = 0
      @@wheel : Int32 = 0
      @@buttons = StaticArray(Bool, 8).new(false)

      def self.x : Int32
        @@x
      end

      def self.y : Int32
        @@y
      end

      def self.delta_x : Int32
        @@delta_x
      end

      def self.delta_y : Int32
        @@delta_y
      end

      def self.wheel : Int32
        @@wheel
      end

      def self.button_down?(button : Int32) : Bool
        return false if button < 0 || button >= 8
        @@buttons[button]
      end

      def self.update_state(new_x : Int32, new_y : Int32, left : Bool, right : Bool)
        @@delta_x = new_x - @@x
        @@delta_y = new_y - @@y
        @@x = new_x
        @@y = new_y
        @@buttons[MOUSE_BUTTON_LEFT] = left
        @@buttons[MOUSE_BUTTON_RIGHT] = right
      end
    end
  end
end
