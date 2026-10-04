require "../src/citrine/iso/sound_irx_builder"

vag = File.read("scratch/moonrise01.vag").to_slice
irx = Citrine::ISO::SoundIrxBuilder.build(vag, 60.0)
puts "Successfully built S.IRX: #{irx.size} bytes from #{vag.size} bytes VAG"
