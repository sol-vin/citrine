# Citrine Event Emitter & Pub-Sub Dispatcher
# Modular engine abstraction - require "citrine/events"

module Citrine
  # Lightweight publish-subscribe event dispatch system for decoupling game logic,
  # physics triggers, and UI interactions.
  class EventEmitter
    # Signature of an event callback handler taking an optional String payload.
    alias Handler = Proc(String, Nil)
    @listeners : Hash(String, Array(Handler))

    # Creates an empty `EventEmitter`.
    def initialize
      @listeners = {} of String => Array(Handler)
    end

    # Registers a listener block to be invoked whenever `event` is emitted.
    #
    # Parameters:
    # - `event`: Event identifier name (e.g. "player_jump", "game_over").
    # - `block`: Callback block receiving payload string.
    def on(event : String, &block : String -> Nil)
      handlers = @listeners[event]?
      unless handlers
        handlers = [] of Handler
        @listeners[event] = handlers
      end
      handlers << block
    end

    # Dispatches `event` to all registered listeners with optional `payload`.
    #
    # Parameters:
    # - `event`: Event identifier name.
    # - `payload`: String payload forwarded to handlers.
    def emit(event : String, payload : String = "")
      if handlers = @listeners[event]?
        handlers.each { |h| h.call(payload) }
      end
    end

    # Removes registered listeners. If `event` is specified, clears only that event;
    # otherwise removes all listeners across all events.
    def clear(event : String? = nil)
      if event
        @listeners.delete(event)
      else
        @listeners.clear
      end
    end
  end
end
