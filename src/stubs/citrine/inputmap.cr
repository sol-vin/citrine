# Citrine InputMap Subsystem
# Godot-style Action-based input mapping for PlayStation 2 DualShock 2 controllers.
#
# Provides a declarative macro DSL (`input_map`) and a runtime action registry (`Citrine::InputMap`)
# allowing games to map high-level actions (e.g. `:jump`, `:fire`, `:pause`) to specific physical
# buttons and controller ports (Port 0 / Player 1 vs Port 1 / Player 2).
#
# ### Example Usage:
# ```crystal
# require "citrine"
# require "citrine/inputmap"
#
# # Declare input mapping for the game
# input_map do
#   action :jump, Button::Cross, port: 0
#   action :attack, Button::Square, port: 0
#   action :pause, Button::Start, port: 0
#   action :p2_jump, Button::Cross, port: 1
# end
#
# Citrine.main_loop do
#   # Query actions in the frame loop (rising edge / pressed this frame):
#   if Action.is_pressed?(Actions::Jump)
#     # Player 1 jumped
#   end
#
#   # Held down state:
#   if Action.is_down?(Actions::Attack)
#     # Player 1 charging attack
#   end
#
#   # Player 2 action:
#   if Action.is_pressed?(Actions::P2Jump)
#     # Player 2 jumped on Controller Port 1
#   end
# end
# ```

module Citrine
  # Runtime entry for a mapped physical button on a specific controller port.
  struct ActionBinding
    # The physical controller button (e.g. `Button::Cross`).
    getter button : ::Button

    # The controller port index (0 = Port 1 / Player 1, 1 = Port 2 / Player 2).
    getter port : Int32

    # Initializes an action binding for a specific button and controller port.
    def initialize(button : ::Button | Int32, @port : Int32 = 0)
      @button = button.is_a?(::Button) ? button : ::Button.new(button.to_u8)
    end
  end

  # Runtime registry managing action-to-button mappings.
  # Supports both static macro-defined mappings and dynamic runtime rebinding.
  class InputMap
    # Singleton instance of the runtime input map.
    @@instance : InputMap?

    # Returns the global InputMap singleton instance.
    def self.instance : InputMap
      @@instance ||= new
    end

    # Mapping of action name to array of physical button bindings.
    getter actions : Hash(String, Array(ActionBinding))

    # Initializes an empty InputMap registry.
    def initialize
      @actions = Hash(String, Array(ActionBinding)).new
    end

    # Clears all registered action bindings.
    def self.clear : Nil
      instance.actions.clear
    end

    # Binds an action to a controller button and port.
    #
    # Parameters:
    # - `action_name`: The identifier for the action (e.g. `"jump"`, `:jump`, or enum integer).
    # - `button`: The physical DualShock 2 button.
    # - `port`: Controller port index (0 for Player 1, 1 for Player 2).
    def self.add_action(action_name : String | Symbol | Int32, button : ::Button | Int32, port : Int32 = 0) : Nil
      key = action_name.to_s
      list = instance.actions[key] ||= [] of ActionBinding
      list << ActionBinding.new(button, port)
    end

    # Returns true if the action was newly pressed during the current frame (rising edge).
    # Checks all physical button bindings associated with the action.
    def self.action_pressed?(action_name : String | Symbol | Int32) : Bool
      key = action_name.to_s
      if bindings = instance.actions[key]?
        bindings.any? do |b|
          Citrine.button_pressed?(b.port, b.button)
        end
      else
        false
      end
    end

    # Returns true if the action is currently held down.
    # Checks all physical button bindings associated with the action.
    def self.action_down?(action_name : String | Symbol | Int32) : Bool
      key = action_name.to_s
      if bindings = instance.actions[key]?
        bindings.any? do |b|
          Citrine.button_down?(b.port, b.button)
        end
      else
        false
      end
    end

    # Returns true if the action was released during the current frame (falling edge).
    # Checks all physical button bindings associated with the action.
    def self.action_released?(action_name : String | Symbol | Int32) : Bool
      key = action_name.to_s
      if bindings = instance.actions[key]?
        bindings.any? do |b|
          Citrine.button_released?(b.port, b.button)
        end
      else
        false
      end
    end

    # Computes an axis value (-1.0 to 1.0) between a negative action and a positive action.
    #
    # Example:
    # ```crystal
    # move_x = Citrine::InputMap.get_axis("move_left", "move_right")
    # ```
    def self.get_axis(negative_action : String | Symbol | Int32, positive_action : String | Symbol | Int32) : Float32
      val = 0.0_f32
      val -= 1.0_f32 if action_down?(negative_action)
      val += 1.0_f32 if action_down?(positive_action)
      val
    end
  end
end

# Top-level helper module providing ergonomic query methods for mapped actions.
# Conforms to Godot-style `Action.is_pressed?` / `Action.is_action_pressed` conventions.
module Action
  # Returns true if the specified action was pressed on this frame (rising edge).
  def self.is_pressed?(action) : Bool
    Citrine::InputMap.action_pressed?(action)
  end

  # Returns true if the specified action is currently held down.
  def self.is_down?(action) : Bool
    Citrine::InputMap.action_down?(action)
  end

  # Returns true if the specified action was released on this frame (falling edge).
  def self.is_released?(action) : Bool
    Citrine::InputMap.action_released?(action)
  end

  # Returns an axis scalar (-1.0 to 1.0) calculated from negative and positive action states.
  def self.get_axis(negative_action, positive_action) : Float32
    Citrine::InputMap.get_axis(negative_action, positive_action)
  end

  # Godot compatibility alias: returns true if action was pressed during the current frame.
  def self.is_action_just_pressed(action) : Bool
    is_pressed?(action)
  end

  # Godot compatibility alias: returns true if action is held down.
  def self.is_action_pressed(action) : Bool
    is_down?(action)
  end

  # Godot compatibility alias: returns true if action was released during the current frame.
  def self.is_action_just_released(action) : Bool
    is_released?(action)
  end
end

# Declarative Macro DSL for defining an input map and generating a type-safe `Actions` enum.
#
# ### Example:
# ```crystal
# input_map do
#   action :jump, Button::Cross, port: 0
#   action :attack, Button::Square, port: 0
#   action :pause, Button::Start, port: 0
#   action :p2_jump, Button::Cross, port: 1
# end
# ```
macro input_map(&block)
  {{ block.body }}
end

# Macro helper to register an action inside an `input_map` block.
macro action(name, button, port = 0)
  Citrine::InputMap.add_action({{name.id.stringify}}, {{button}}, {{port}})
end

# Pre-declared Actions enum populated by input map declarations.
enum Actions
  # Default action slot
  None = 0
  SpawnOne = 1
  SpawnTen = 2
  Reset = 3
  Jump = 4
  Attack = 5
  Fire = 6
  Pause = 7
  P2Jump = 8
  P2Attack = 9
  P2Fire = 10
  CycleColor = 11
  CyclePrev = 12
  ToggleHud = 13
  MoveLeft = 14
  MoveRight = 15
  SpeedUp = 16
  SlowDown = 17
  OrbitLeft = 18
  OrbitRight = 19
  BurstJobs = 20
  PlayPause = 21
  BlastCrates = 22
  ToggleBloom = 23
  ToggleScanlines = 24
  AmpUp = 25
  AmpDown = 26
  BurstParticles = 27
end
