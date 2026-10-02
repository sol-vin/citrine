# Citrine Event Emitter & Pub-Sub Dispatcher
# Modular engine abstraction - require "citrine/events"

module Citrine
  class EventEmitter
    alias Handler = Proc(String, Nil)
    @listeners : Hash(String, Array(Handler))

    def initialize
      @listeners = {} of String => Array(Handler)
    end

    def on(event : String, &block : String -> Nil)
      handlers = @listeners[event]?
      unless handlers
        handlers = [] of Handler
        @listeners[event] = handlers
      end
      handlers << block
    end

    def emit(event : String, payload : String = "")
      if handlers = @listeners[event]?
        handlers.each { |h| h.call(payload) }
      end
    end

    def clear(event : String? = nil)
      if event
        @listeners.delete(event)
      else
        @listeners.clear
      end
    end
  end
end
