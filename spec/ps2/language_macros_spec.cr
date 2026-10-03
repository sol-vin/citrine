require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 Crystal Language Parity: Macro Reflection & @instance_vars" do
  it "verifies @type.instance_vars loop expansion in class body on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_macro_ivars_test")
    tc.source(<<-CR
      class Player
        property name : String
        property score : Int32

        def initialize(@name : String, @score : Int32)
        end

        {% for ivar in @type.instance_vars %}
          def get_{{ ivar.name }}
            @{{ ivar.name }}
          end
        {% end %}
      end

      p = Player.new("Sora", 9000)
      if p.get_name == "Sora"
        debug_puts "[CITRINE TEST] Generated get_name: PASS"
      end

      if p.get_score == 9000
        debug_puts "[CITRINE TEST] Generated get_score: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] Generated get_name: PASS")
    result.should_have_output("[CITRINE TEST] Generated get_score: PASS")
  end

  it "verifies top-level macro reflection with @type.name and @type.instance_vars on PS2" do
    tc = Citrine::Spec::Ps2TestCase.new("language_macro_type_name_test")
    tc.source(<<-CR
      macro make_resetters
        def class_label
          "{{ @type.name }}"
        end

        {% for ivar in @type.instance_vars %}
          def reset_{{ ivar.name }}
            @{{ ivar.name }} = 0
          end
        {% end %}
      end

      class Stats
        property hp : Int32
        property mp : Int32

        def initialize(@hp : Int32, @mp : Int32)
        end

        make_resetters
      end

      s = Stats.new(100, 50)
      if s.class_label == "Stats"
        debug_puts "[CITRINE TEST] @type.name reflected correctly: PASS"
      end

      s.reset_hp
      if s.hp == 0
        debug_puts "[CITRINE TEST] Macro reset_hp method executed: PASS"
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 7.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CITRINE TEST] @type.name reflected correctly: PASS")
    result.should_have_output("[CITRINE TEST] Macro reset_hp method executed: PASS")
  end
end
