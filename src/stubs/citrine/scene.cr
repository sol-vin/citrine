# Citrine Scene Lifecycle & Scene Management Framework
# Modular engine abstraction - require "citrine/scene"

module Citrine
  # Abstract base class for discrete game states (e.g. TitleScene, GameplayScene, PauseMenu).
  abstract class Scene
    # Called when this scene becomes the active scene. Allocate scene resources here.
    def enter
    end

    # Called once per frame to advance game logic by `dt` seconds.
    def update(dt : Float32)
    end

    # Called once per frame to emit draw calls to the Citrine rendering pipeline.
    def draw
    end

    # Called when transitioning away from this scene. Free scene resources here.
    def exit
    end
  end

  # Global scene lifecycle manager coordinating transitions, updates, and rendering.
  module SceneManager
    @@current : Scene? = nil

    # Transitions to `scene`, invoking `exit` on previous scene and `enter` on new scene.
    def self.set_scene(scene : Scene)
      if cur = @@current
        cur.exit
      end
      @@current = scene
      scene.enter
    end

    # Returns the currently active `Scene`, or `nil` if none is set.
    def self.current_scene : Scene?
      @@current
    end

    # Updates the active scene by `dt` seconds.
    def self.update(dt : Float32)
      if cur = @@current
        cur.update(dt)
      end
    end

    # Renders the active scene.
    def self.draw
      if cur = @@current
        cur.draw
      end
    end
  end
end
