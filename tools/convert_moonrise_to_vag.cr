require "../src/citrine/importers/sound_importer"

wav_bytes = File.read("scratch/track01_22k.wav").to_slice
puts "Read WAV bytes: #{wav_bytes.size}"

asset = Citrine::Importers::SoundImporter.import_wav(wav_bytes)
puts "Parsed WAV: #{asset.pcm_samples.size} samples, #{asset.sample_rate} Hz, #{asset.channels} channel(s), duration: #{asset.duration_seconds}s"

vag_bytes = Citrine::Importers::SoundImporter.to_vag(asset, "moonrise", loop_audio: true)
puts "Encoded VAG: #{vag_bytes.size} bytes"

File.write("scratch/moonrise01.vag", vag_bytes)
puts "Wrote scratch/moonrise01.vag"
