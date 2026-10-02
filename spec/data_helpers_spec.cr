require "./spec_helper"

describe Citrine::Importers::DataHelpers do
  it "parses YAML game configuration" do
    yaml_text = <<-YAML
    title: "PS2 Adventure"
    resolution:
      width: 640
      height: 448
    audio:
      master_volume: 0.85
      sfx_enabled: true
    levels:
      - id: 1
        name: "Emerald Green Zone"
      - id: 2
        name: "Lapis Ruins"
    YAML

    config = Citrine::Importers::DataHelpers.parse_yaml(yaml_text)
    config["title"].as_s.should eq("PS2 Adventure")
    config["resolution"]["width"].as_i.should eq(640)
    config["audio"]["sfx_enabled"].as_bool.should be_true
    config["levels"].as_a.size.should eq(2)
  end

  it "parses JSON game levels and asset manifests" do
    manifest_json = <<-JSON
    {
      "version": "1.0",
      "assets": {
        "hero_mesh": "models/hero.cbm",
        "title_font": "fonts/retro.cbf",
        "jump_sfx": "audio/jump.vag",
        "bg_texture": "textures/sky.cbt"
      }
    }
    JSON

    manifest = Citrine::Importers::DataHelpers.parse_manifest(manifest_json)
    manifest.version.should eq("1.0")
    manifest.assets["hero_mesh"].should eq("models/hero.cbm")
    manifest.assets["jump_sfx"].should eq("audio/jump.vag")
  end
end
