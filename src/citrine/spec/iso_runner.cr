pattern = ARGV[0]? || "examples/**/game.iso"
ARGV.clear

require "./iso_spec"

passed, failed = Citrine::Spec.run_iso_suite(pattern)
exit(failed > 0 ? 1 : 0)
