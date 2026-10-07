require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Dynamic Language Parity: Modules & Mixins" do
  it "verifies multiple module inclusions and method resolution precedence on PS2 EE" do
    tc = Citrine::Spec::Ps2TestCase.new("mod_multi_include_precedence_test")
    tc.source(<<-CR
      module Alpha
        def tag
          "ALPHA"
        end

        def alpha_specific
          100
        end
      end

      module Beta
        def tag
          "BETA"
        end

        def beta_specific
          200
        end
      end

      # In Crystal/Citrine, when both Alpha and Beta define #tag,
      # the later included module (Beta) takes precedence over earlier (Alpha)
      class CompositeEntity
        include Alpha
        include Beta

        property id : Int32
        def initialize(@id)
        end
      end

      # Class that overrides mixin method
      class OverridingEntity
        include Alpha
        include Beta

        def tag
          "OVERRIDDEN"
        end
      end

      c = CompositeEntity.new(1)
      tag_c = c.tag
      a_val = c.alpha_specific
      b_val = c.beta_specific

      o = OverridingEntity.new
      tag_o = o.tag

      if tag_c == "BETA" && a_val == 100 && b_val == 200 && tag_o == "OVERRIDDEN"
        debug_puts "[CITRINE TEST] Modules#multi_include_precedence: PASS"
      else
        debug_puts "[CITRINE TEST] Modules#multi_include_precedence: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Modules#multi_include_precedence: PASS")
  end

  it "verifies nested module mixins and transitive inclusion on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("mod_nested_mixins_test")
    tc.source(<<-CR
      module CoreStats
        def base_stat
          50
        end
      end

      module CombatStats
        include CoreStats

        def combat_power
          base_stat * 3
        end
      end

      class Warrior
        include CombatStats

        property weapon_bonus : Int32
        def initialize(@weapon_bonus)
        end

        def total_attack
          combat_power + @weapon_bonus
        end
      end

      w = Warrior.new(25)
      bs = w.base_stat
      cp = w.combat_power
      ta = w.total_attack

      # base_stat: 50, combat_power: 150, total_attack: 175
      if bs == 50 && cp == 150 && ta == 175
        debug_puts "[CITRINE TEST] Modules#nested_transitive_mixins: PASS"
      else
        debug_puts "[CITRINE TEST] Modules#nested_transitive_mixins: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Modules#nested_transitive_mixins: PASS")
  end

  it "verifies extend mixins for class-level and singleton methods on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("mod_extend_singleton_test")
    tc.source(<<-CR
      module FactoryHelpers
        def default_spawn_rate
          60
        end

        def create_default_label
          "GEN_ENTITY_0"
        end
      end

      class Spawner
        extend FactoryHelpers

        property rate : Int32
        def initialize
          @rate = Spawner.default_spawn_rate
        end
      end

      rate = Spawner.default_spawn_rate
      label = Spawner.create_default_label
      sp = Spawner.new

      if rate == 60 && label == "GEN_ENTITY_0" && sp.rate == 60
        debug_puts "[CITRINE TEST] Modules#extend_singleton_methods: PASS"
      else
        debug_puts "[CITRINE TEST] Modules#extend_singleton_methods: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Modules#extend_singleton_methods: PASS")
  end

  it "verifies direct module methods and self dispatch on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("mod_direct_methods_test")
    tc.source(<<-CR
      module MathUtils
        def self.clamp_val(v : Int32, min_v : Int32, max_v : Int32)
          if v < min_v
            min_v
          elsif v > max_v
            max_v
          else
            v
          end
        end

        def self.square(n : Int32)
          n * n
        end
      end

      c1 = MathUtils.clamp_val(5, 10, 50)   # clamped to 10
      c2 = MathUtils.clamp_val(100, 10, 50) # clamped to 50
      c3 = MathUtils.clamp_val(25, 10, 50)  # within range: 25
      sq = MathUtils.square(12)             # 144

      if c1 == 10 && c2 == 50 && c3 == 25 && sq == 144
        debug_puts "[CITRINE TEST] Modules#direct_self_methods: PASS"
      else
        debug_puts "[CITRINE TEST] Modules#direct_self_methods: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Modules#direct_self_methods: PASS")
  end

  it "verifies module constants and nested namespace resolution on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("mod_constants_and_namespaces_test")
    tc.source(<<-CR
      module GraphicsEngine
        SCREEN_WIDTH = 640
        SCREEN_HEIGHT = 448
        DEFAULT_CLEAR_COLOR = 0x000000FF

        module Palettes
          PRIMARY = 1
          SECONDARY = 2
        end
      end

      w = GraphicsEngine::SCREEN_WIDTH
      h = GraphicsEngine::SCREEN_HEIGHT
      clr = GraphicsEngine::DEFAULT_CLEAR_COLOR
      pal = GraphicsEngine::Palettes::PRIMARY

      if w == 640 && h == 448 && clr == 0x000000FF && pal == 1
        debug_puts "[CITRINE TEST] Modules#constants_and_namespaces: PASS"
      else
        debug_puts "[CITRINE TEST] Modules#constants_and_namespaces: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Modules#constants_and_namespaces: PASS")
  end

  it "verifies module polymorphism with is_a?(Module) on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("mod_polymorphism_is_a_test")
    tc.source(<<-CR
      module Renderable
        def render_id
          42
        end
      end

      module Auditory
        def sound_id
          84
        end
      end

      class Sprite
        include Renderable
      end

      class AudioTrack
        include Auditory
      end

      class AmbientZone
        include Renderable
        include Auditory
      end

      sp = Sprite.new
      at = AudioTrack.new
      az = AmbientZone.new

      # Type checks
      sp_ren = sp.is_a?(Renderable)
      sp_aud = sp.is_a?(Auditory)

      at_ren = at.is_a?(Renderable)
      at_aud = at.is_a?(Auditory)

      az_ren = az.is_a?(Renderable)
      az_aud = az.is_a?(Auditory)

      if sp_ren && (!sp_aud) && (!at_ren) && at_aud && az_ren && az_aud
        debug_puts "[CITRINE TEST] Modules#is_a_polymorphism: PASS"
      else
        debug_puts "[CITRINE TEST] Modules#is_a_polymorphism: FAIL"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_preserve_spram
    result.should_have_no_memory_leaks
    result.should_have_output("[CITRINE TEST] Modules#is_a_polymorphism: PASS")
  end
end
