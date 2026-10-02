# Citrine Scene Lifecycle & Scene Management Framework
# Modular engine abstraction - require "citrine/scene"

module Citrine
  abstract class Scene
    def enter
    end

    def update(dt : Float32)
    end

    def draw
    end

    def exit
    end
  end

  module SceneManager
    @@current : Scene? = nil

    def self.set_scene(scene : Scene)
      if cur = @@current
        cur.exit
      end
      @@current = scene
      scene.enter
    end

    def self.current_scene : Scene?
      @@current
    end

    def self.update(dt : Float32)
      if cur = @@current
        cur.update(dt)
      end
    end

    def self.draw
      if cur = @@current
        cur.draw
      end
    end
  end
end
