require "../src/citrine/spec/ps2_spec"
require "../src/citrine/iso/elf_builder"
require "../src/citrine/gs/framebuffer_renderer"

tc = Citrine::Spec::Ps2TestCase.new("snap_10")
tc.target("examples/10_video_and_audio/main.cr")
bytes, sm = tc.compile
builder = Citrine::ElfBuilder.new
phases, msgs, loop_start, animated = builder.parse_cbc(bytes)
puts "Phases: #{phases.size}, animated: #{animated}, loop_start: #{loop_start}"
Citrine::GS::FramebufferRenderer.save_png(phases.first.commands, "C:/Users/Ian/.gemini/antigravity/brain/800ae8f6-80d0-4428-93ad-3dc0043d07e3/example_10_video_and_audio.png")
puts "Saved example_10_video_and_audio.png successfully (#{phases.first.commands.size} commands)"
