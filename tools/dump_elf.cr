require "../src/citrine/iso/elf_builder"

cbc = File.read("examples/10_cd_player/main.cbc").to_slice
elf = Citrine::ElfBuilder.build_default_runner_elf(cbc)
File.write("examples/10_cd_player/CITRINE.ELF", elf)
puts "Wrote CITRINE.ELF: #{elf.size} bytes"
