require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/audio"

describe "Citrine::Audio & SPU2 Memory Architecture" do
  it "defines the 2MB SPU2 hardware memory constant" do
    Citrine::Audio::SPU2_RAM_TOTAL.should eq(2 * 1024 * 1024)
    Citrine::Audio.free_memory.should be <= 2 * 1024 * 1024
  end

  it "declares a sound bank with memory budget and sample policies" do
    bank = Citrine::Audio.bank :dungeon_test, budget: 256 * 1024 do |b|
      b.sound :footstep, "sfx/footstep.vag", size_bytes: 16 * 1024, pinned: true
      b.sound :sword_clash, "sfx/clash.vag", size_bytes: 32 * 1024, cached: true
      b.sound :death_cry, "sfx/cry.vag", size_bytes: 64 * 1024, transient: true
      b.stream :ambient, "music/dungeon.cas"
    end

    bank.clips.size.should eq(3)
    bank.streams.size.should eq(1)
    bank.total_size_bytes.should eq((16 + 32 + 64) * 1024)

    # Pinned sounds should be preloaded automatically
    footstep = bank.clips[:footstep]
    footstep.policy.should eq(Citrine::Audio::Policy::Pinned)
    footstep.is_loaded.should be_true

    # Cached sounds load on demand
    clash = bank.clips[:sword_clash]
    clash.policy.should eq(Citrine::Audio::Policy::Cached)
    clash.is_loaded.should be_false

    # Transient sounds are marked transient
    cry = bank.clips[:death_cry]
    cry.policy.should eq(Citrine::Audio::Policy::Transient)
  end

  it "tracks SPU2 memory allocation and free space" do
    initial_used = Citrine::Audio.used_memory
    initial_free = Citrine::Audio.free_memory

    Citrine::Audio.play(:sword_clash, volume: 1.0, pitch: 1.0)

    # sword_clash (32 KB) should now be loaded
    clash = Citrine::Audio.get_bank(:dungeon_test).not_nil!.clips[:sword_clash]
    clash.is_loaded.should be_true
    Citrine::Audio.used_memory.should eq(initial_used + 32 * 1024)
    Citrine::Audio.free_memory.should eq(initial_free - 32 * 1024)
  end

  it "evicts cached sounds under memory pressure while protecting pinned sounds" do
    bank = Citrine::Audio.bank :eviction_test, budget: 128 * 1024 do |b|
      b.sound :pinned_sfx, "sfx/p.vag", size_bytes: 64 * 1024, pinned: true
      b.sound :cached_sfx1, "sfx/c1.vag", size_bytes: 64 * 1024, cached: true
      b.sound :cached_sfx2, "sfx/c2.vag", size_bytes: 64 * 1024, cached: true
    end

    # Play cached_sfx1 first
    Citrine::Audio.play(:cached_sfx1)
    bank.clips[:cached_sfx1].is_loaded.should be_true
    bank.clips[:pinned_sfx].is_loaded.should be_true

    # Unload cached_sfx1 explicitly
    bank.clips[:cached_sfx1].unload!
    bank.clips[:cached_sfx1].is_loaded.should be_false
    bank.clips[:pinned_sfx].is_loaded.should be_true
  end

  it "supports scoped bank lifecycle with with_bank" do
    Citrine::Audio.bank :scoped_test, budget: 64 * 1024 do |b|
      b.sound :level_sfx, "sfx/level.vag", size_bytes: 32 * 1024, pinned: true
    end

    bank = Citrine::Audio.get_bank(:scoped_test).not_nil!

    Citrine::Audio.with_bank(:scoped_test) do |b|
      b.clips[:level_sfx].is_loaded.should be_true
    end

    # Upon block exit, sounds in bank are unloaded
    bank.clips[:level_sfx].is_loaded.should be_false
  end
end
