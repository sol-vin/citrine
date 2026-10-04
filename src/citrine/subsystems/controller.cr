module Citrine
  # Controller Port enumeration for PlayStation 2 DualShock 2 controllers.
  # Represents physical controller port 1 (`Port1` / `Player1`) or port 2 (`Port2` / `Player2`).
  enum Port : UInt8
    Port1   = 0
    Port2   = 1
    Player1 = 0
    Player2 = 1

    # Returns the 0-indexed port index (0 or 1).
    def index : Int32
      self.value.to_i32
    end
  end

  # DualShock 2 Analog Stick Selection
  enum Stick : UInt8
    Left  = 0
    Right = 1
  end

  # DualShock 2 Analog Axes
  enum Axis : UInt8
    LeftX  = 0
    LeftY  = 1
    RightX = 2
    RightY = 3
  end

  # PlayStation 2 DualShock 2 Button Definitions & Virtual Controller Helpers.
  # Bit indices correspond to standard DualShock 2 digital button bit positions.
  enum PadButton : UInt8
    Select   =  0
    L3       =  1
    R3       =  2
    Start    =  3
    Up       =  4
    Right    =  5
    Down     =  6
    Left     =  7
    L2       =  8
    R2       =  9
    L1       = 10
    R1       = 11
    Triangle = 12
    Circle   = 13
    Cross    = 14
    Square   = 15
  end

  # High-level controller handle bound to a specific PlayStation 2 controller port.
  #
  # Example:
  # ```crystal
  # p1 = Citrine.player(0)
  # p2 = Citrine.player(1)
  #
  # if p1.button_pressed?(Button::Cross)
  #   # Player 1 jumped
  # end
  # ```
  struct Controller
    # The physical controller port associated with this controller handle.
    getter port : Port

    # Initializes a controller handle for the specified port (0 = Port 1, 1 = Port 2).
    def initialize(port : Port | Int32)
      @port = port.is_a?(Port) ? port : (port == 1 ? Port::Port2 : Port::Port1)
    end

    # Returns true if the specified button is currently held down on this controller port.
    def button_down?(button : PadButton | ::Button | Int32) : Bool
      btn = button.is_a?(::Button) ? button : ::Button.from_value(button.to_u8)
      Citrine.button_down?(@port, btn)
    end

    # Returns true if the specified button was pressed on this controller port during the current frame (rising edge).
    def button_pressed?(button : PadButton | ::Button | Int32) : Bool
      btn = button.is_a?(::Button) ? button : ::Button.from_value(button.to_u8)
      Citrine.button_pressed?(@port, btn)
    end

    # Returns true if the specified button was released on this controller port during the current frame (falling edge).
    def button_released?(button : PadButton | ::Button | Int32) : Bool
      btn = button.is_a?(::Button) ? button : ::Button.from_value(button.to_u8)
      Citrine.button_released?(@port, btn)
    end

    # Returns the horizontal analog axis value (-1.0 to 1.0) for the specified stick.
    def analog_x(stick : Stick = Stick::Left) : Float32
      Citrine.get_analog(@port, stick == Stick::Left ? 0 : 2)
    end

    # Returns the vertical analog axis value (-1.0 to 1.0) for the specified stick.
    def analog_y(stick : Stick = Stick::Left) : Float32
      Citrine.get_analog(@port, stick == Stick::Left ? 1 : 3)
    end

    # Returns the left analog stick horizontal axis (-1.0 to 1.0).
    def left_stick_x : Float32
      analog_x(Stick::Left)
    end

    # Returns the left analog stick vertical axis (-1.0 to 1.0).
    def left_stick_y : Float32
      analog_y(Stick::Left)
    end

    # Returns the right analog stick horizontal axis (-1.0 to 1.0).
    def right_stick_x : Float32
      analog_x(Stick::Right)
    end

    # Returns the right analog stick vertical axis (-1.0 to 1.0).
    def right_stick_y : Float32
      analog_y(Stick::Right)
    end

    # Sets vibration motors on this DualShock 2 controller.
    # `small`: 0 (off) or 1 (on) for the high-frequency rumble motor.
    # `large`: 0..255 speed for the low-frequency weight motor.
    def rumble(small : UInt8 | Int32, large : UInt8 | Int32) : Nil
      Citrine.set_rumble(@port, small.to_u8, large.to_u8)
    end
  end

  # Represents a scheduled virtual controller button press for automated testing or macro playback.
  # Supports targeting specific controller ports (0 = Player 1, 1 = Player 2).
  struct VirtualInput
    # The starting frame number when this button press becomes active.
    property start_frame : UInt32

    # Bitmask of buttons active during this scheduled input window.
    property button_mask : UInt16

    # Number of consecutive frames this input remains held.
    property duration_frames : UInt16

    # Controller port index (0 = Port 1 / Player 1, 1 = Port 2 / Player 2).
    property port : UInt8

    def initialize(
      @start_frame : UInt32,
      @button_mask : UInt16,
      @duration_frames : UInt16 = 1_u16,
      @port : UInt8 = 0_u8
    )
    end

    # Returns a 16-bit mask with the bit for `button` set to 1.
    def self.button_mask(button : PadButton | Int32 | UInt8) : UInt16
      idx = button.to_i
      return 0_u16 if idx < 0 || idx > 15
      (1_u16 << idx)
    end

    # Returns the standard PlayStation 2 button name for a given bit index.
    def self.button_name(bit_index : Int32) : String
      case bit_index
      when 0  then "Select"
      when 1  then "L3"
      when 2  then "R3"
      when 3  then "Start"
      when 4  then "Up"
      when 5  then "Right"
      when 6  then "Down"
      when 7  then "Left"
      when 8  then "L2"
      when 9  then "R2"
      when 10 then "L1"
      when 11 then "R1"
      when 12 then "Triangle"
      when 13 then "Circle"
      when 14 then "Cross"
      when 15 then "Square"
      else "Button(#{bit_index})"
      end
    end
  end
end
