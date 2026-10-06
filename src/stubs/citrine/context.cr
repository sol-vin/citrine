# Citrine Dynamic Subsystems and VM Execution Contexts
# Modular engine abstraction - require "citrine/context"

require "../citrine"

module Citrine
  # Current active VM execution context (:default, :menu, :game, etc.)
  @@active_context : Symbol = :default

  # Returns the currently active VM context name.
  def self.active_context : Symbol
    @@active_context
  end

  # Explicitly switches the active VM context. Forbidden inside an active main_loop.
  def self.switch_context(name : Symbol)
    @@active_context = name
  end

  # Executes the main game loop bound to `context`.
  # When `context` is omitted, defaults to the first declared context in the file.
  def self.main_loop(context : Symbol? = nil, &block)
    if ctx = context
      switch_context(ctx)
    end
    while window_open?
      yield
    end
  end

  # Cleanly breaks out of the active main_loop, initiating context shift and DMA synchronization.
  def self.exit_loop
  end
end

# Top-level context declaration block DSL:
#
# ```crystal
# context(:game) do
#   require "citrine/draw3d"
#   require "./entities/player"
# end
# ```
macro context(name, &block)
  {{block.body}}
end

# Top-level exit keyword breaking the active Citrine.main_loop
def exit(status : Int = 0)
  Citrine.exit_loop
  Process.exit(status)
end
