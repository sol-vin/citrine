require "../spec_helper"
require "../../src/citrine/spec/ps2_spec"

describe "Citrine PS2 VM Contexts & Multi-File Requires" do
  it "partitions libraries with make_vm_context and set_vm_context" do
    tc = Citrine::Spec::Ps2TestCase.new("vm_contexts_test")
    tc.source(<<-CR
      make_vm_context(:menu) do
        def menu_render
          debug_puts "[CONTEXT:MENU] Rendering Title Screen"
        end
      end

      make_vm_context(:game) do
        def game_render
          debug_puts "[CONTEXT:GAME] Rendering 3D World"
        end
      end

      set_vm_context(:menu)
      menu_render

      set_vm_context(:game)
      game_render

      vm_context(:menu) do
        menu_render
      end
    CR
    )
    bytes, sm = tc.compile
    bytes.size.should be > 18

    result = tc.boot_pcsx2(timeout: 12.seconds)
    result.should_boot_cleanly
    result.should_have_output("[CONTEXT:MENU] Rendering Title Screen")
    result.should_have_output("[CONTEXT:GAME] Rendering 3D World")
  end

  it "resolves multi-file relative requires with cycle detection" do
    # Create temporary subfiles
    sub_dir = File.join(Dir.tempdir, "citrine_subfile_test_#{Time.utc.to_unix}")
    Dir.mkdir_p(sub_dir)
    file_a = File.join(sub_dir, "helper_a.cr")
    file_b = File.join(sub_dir, "helper_b.cr")
    main_f = File.join(sub_dir, "main.cr")

    # Cycle test: A requires B, B requires A
    File.write(file_a, <<-CR
      require "./helper_b.cr"
      def from_helper_a
        10
      end
    CR
    )

    File.write(file_b, <<-CR
      require "./helper_a.cr"
      def from_helper_b
        20
      end
    CR
    )

    File.write(main_f, <<-CR
      require "./helper_a.cr"
      val_a = from_helper_a
      val_b = from_helper_b
      if val_a + val_b == 30
        debug_puts "[CITRINE TEST] Multi-File Requires & Cycle Detection: PASS"
      end
    CR
    )

    parser = Citrine::DslParser.new(filename: main_f)
    program = parser.parse(File.read(main_f))
    program.defs.has_key?("from_helper_a").should be_true
    program.defs.has_key?("from_helper_b").should be_true

    compiler = Citrine::BytecodeCompiler.new(filename: main_f)
    cbc_bytes = compiler.compile(program)
    cbc_bytes.size.should be > 18

    # Clean up temp files
    File.delete(main_f) rescue nil
    File.delete(file_a) rescue nil
    File.delete(file_b) rescue nil
    Dir.delete(sub_dir) rescue nil
  end
end
