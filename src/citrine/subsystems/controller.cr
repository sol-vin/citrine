module Citrine
  # PlayStation 2 DualShock 2 Button Definitions & Virtual Controller Helpers
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

  # Represents a scheduled virtual controller button press for automated testing or macro playback.
  struct VirtualInput
    property start_frame : UInt32
    property button_mask : UInt16
    property duration_frames : UInt16

    def initialize(@start_frame : UInt32, @button_mask : UInt16, @duration_frames : UInt16 = 1_u16)
    end

    def self.button_mask(button : PadButton | Int32 | UInt8) : UInt16
      idx = button.to_i
      return 0_u16 if idx < 0 || idx > 15
      (1_u16 << idx)
    end

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
