require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/draw2d"

describe "Citrine::Draw2D 2D Texture Drawing DSL & PS2 Palette Swapping" do
  describe "Rect (2D Axis-Aligned Rectangle)" do
    it "initializes coordinates and dimensions from numbers" do
      r = Citrine::Rect.new(10, 20, 100, 50)
      r.x.should eq(10.0_f32)
      r.y.should eq(20.0_f32)
      r.width.should eq(100.0_f32)
      r.height.should eq(50.0_f32)
    end

    it "supports Rectangle alias" do
      r = Citrine::Rectangle.new(5, 5, 20, 20)
      r.is_a?(Citrine::Rect).should be_true
    end

    it "checks point containment" do
      r = Citrine::Rect.new(10, 10, 50, 50)
      r.contains?(25, 25).should be_true
      r.contains?(10, 10).should be_true
      r.contains?(60, 60).should be_true
      r.contains?(5, 25).should be_false
      r.contains?(25, 70).should be_false
    end

    it "checks intersection with another rectangle" do
      r1 = Citrine::Rect.new(0, 0, 50, 50)
      r2 = Citrine::Rect.new(25, 25, 50, 50)
      r3 = Citrine::Rect.new(60, 60, 20, 20)

      r1.intersects?(r2).should be_true
      r2.intersects?(r1).should be_true
      r1.intersects?(r3).should be_false
    end

    it "produces offset rectangle" do
      r = Citrine::Rect.new(10, 20, 30, 40)
      offset_r = r.offset(5, -10)
      offset_r.x.should eq(15.0_f32)
      offset_r.y.should eq(10.0_f32)
      offset_r.width.should eq(30.0_f32)
      offset_r.height.should eq(40.0_f32)
    end
  end

  describe "Palette & PS2 CSM1 Swizzling" do
    it "initializes and loads palettes" do
      pal = Citrine::Palette.load("rom0:ALT_PAL.DAT")
      pal.handle.should be > 0_u32
      pal.size.should eq(256)
    end

    it "creates custom palette from color array" do
      colors = Array(Color).new(16, Color::White)
      pal = Citrine::Palette.create(colors)
      pal.size.should eq(16)
    end

    it "correctly swizzles 256-color palette for PS2 GS CSM1 layout" do
      # In PS2 CSM1 mode, within every 32-entry block:
      # entries 0..7 stay at 0..7
      # entries 8..15 swap with 16..23
      # entries 24..31 stay at 24..31
      raw_colors = Array(Color).new(256) do |i|
        Color.new(i.to_u8, 0_u8, 0_u8, 255_u8)
      end

      swizzled = Citrine::Palette.swizzle_psmt8(raw_colors)
      swizzled.size.should eq(256)

      # Check block 0 (indices 0..31):
      # Index 0 must match 0
      swizzled[0].r.should eq(0_u8)
      # Index 7 must match 7
      swizzled[7].r.should eq(7_u8)
      # Index 8 was swapped to target_idx 16
      swizzled[16].r.should eq(8_u8)
      # Index 16 was swapped to target_idx 8
      swizzled[8].r.should eq(16_u8)
      # Index 24 must match 24
      swizzled[24].r.should eq(24_u8)
      # Index 31 must match 31
      swizzled[31].r.should eq(31_u8)

      # Check block 1 (indices 32..63):
      # Index 32 must match 32
      swizzled[32].r.should eq(32_u8)
      # Index 40 (32 + 8) was swapped to target_idx 48 (32 + 16)
      swizzled[48].r.should eq(40_u8)
      # Index 48 (32 + 16) was swapped to target_idx 40 (32 + 8)
      swizzled[40].r.should eq(48_u8)
    end
  end

  describe "Texture & Sprite Object Extensions" do
    it "draws directly from texture instance" do
      tex = Citrine::Texture.new(10_u32, 64, 64)
      executed = false
      Citrine.draw_2d do
        tex.draw(100, 100, tint: Color::Red)
        executed = true
      end
      executed.should be_true
    end

    it "creates and draws cropped Sprite" do
      tex = Citrine::Texture.new(10_u32, 128, 128)
      sprite = tex.crop(0, 0, 32, 32)
      sprite.width.should eq(32.0_f32)
      sprite.height.should eq(32.0_f32)

      executed = false
      Citrine.draw_2d do
        sprite.draw(50, 50, rotation: 30.0, origin: :center)
        executed = true
      end
      executed.should be_true
    end
  end

  describe "Citrine::Draw2D draw_texture & texture DSL" do
    it "draws basic and sized texture" do
      tex = Citrine::Texture.new(1_u32, 64, 64)
      executed = false
      Citrine.draw_2d do |d|
        d.draw_texture(tex, 10, 20)
        d.draw_texture(tex, 10, 20, width: 32, height: 32, tint: Color::Green)
        d.texture(tex, 50, 50, scale: 2.0)
        executed = true
      end
      executed.should be_true
    end

    it "resolves origin anchor presets" do
      w = 64.0_f32
      h = 32.0_f32

      ox, oy = Citrine::Draw2D.resolve_origin(:top_left, w, h)
      ox.should eq(0.0_f32)
      oy.should eq(0.0_f32)

      ox, oy = Citrine::Draw2D.resolve_origin(:center, w, h)
      ox.should eq(32.0_f32)
      oy.should eq(16.0_f32)

      ox, oy = Citrine::Draw2D.resolve_origin(:bottom_center, w, h)
      ox.should eq(32.0_f32)
      oy.should eq(32.0_f32)

      ox, oy = Citrine::Draw2D.resolve_origin(Vector2.new(12, 14), w, h)
      ox.should eq(12.0_f32)
      oy.should eq(14.0_f32)
    end

    it "draws rotated texture with origin presets" do
      tex = Citrine::Texture.new(2_u32, 64, 64)
      executed = false
      Citrine.draw_2d do |d|
        d.draw_texture(tex, 100, 100, rotation: 45.0, origin: :center)
        d.draw_texture(tex, 200, 200, rotation: 90.0, origin: :bottom_center)
        d.draw_texture(tex, 300, 300, rotation: 180.0, origin: Vector2.new(10, 10))
        executed = true
      end
      executed.should be_true
    end

    it "draws with UV cropping and directional flipping" do
      tex = Citrine::Texture.new(3_u32, 256, 256)
      executed = false
      Citrine.draw_2d do |d|
        src_rect = Citrine::Rect.new(32, 32, 32, 32)
        dest_rect = Citrine::Rect.new(100, 100, 64, 64)

        d.draw_texture(tex, 0, 0, src: src_rect, dest: dest_rect, flip_x: true, flip_y: false)
        d.texture(tex, 50, 50, src: src_rect, flip_x: false, flip_y: true)
        executed = true
      end
      executed.should be_true
    end

    it "inherits matrix stack transformations" do
      tex = Citrine::Texture.new(4_u32, 64, 64)
      executed = false
      Citrine.draw_2d do |d|
        d.transform(x: 150, y: 200, rotation: 30.0, scale: 1.5) do
          d.draw_texture(tex, 0, 0, origin: :center)
          executed = true
        end
      end
      executed.should be_true
    end

    it "supports inline and scoped palette swapping" do
      tex = Citrine::Texture.new(5_u32, 64, 64)
      pal1 = Citrine::Palette.new(101_u32, 256)
      pal2 = Citrine::Palette.new(102_u32, 256)

      executed = false
      Citrine.draw_2d do |d|
        # Inline palette argument
        d.draw_texture(tex, 10, 10, palette: pal1)

        # Scoped palette block
        d.with_palette(pal2) do
          d.draw_texture(tex, 50, 50)
          d.draw_texture(tex, 90, 50)
        end

        executed = true
      end
      executed.should be_true
    end
  end

  describe "Compiler & Bytecode Generation for Texture Native Calls" do
    it "compiles Citrine.draw_texture_pro, load_palette, and set_palette" do
      source = <<-CRYSTAL
      require "citrine"
      @[Context(:game)]
      require "citrine/draw2d"

      Citrine.main_loop(context: :game) do
        tex = Citrine.load_texture("player.png")
        pal = Citrine.load_palette("player_alt.pal")
        Citrine.set_palette(pal)
        Citrine.draw_texture_pro(tex, 0.0, 0.0, 32.0, 32.0, 100.0, 100.0, 32.0, 32.0, 45.0, 16.0, 16.0)
        exit
      end
      CRYSTAL

      parser = Citrine::DslParser.new
      program = parser.parse(source)
      compiler = Citrine::BytecodeCompiler.new
      compiler.compile(program)
      instructions = compiler.functions.flat_map(&.instructions)



      has_load_tex = instructions.any? { |i| i.opcode == Citrine::Opcode::CallNative && (i.raw & 0xFF_u32) == Citrine::NativeId::LoadTexture.value }
      has_load_pal = instructions.any? { |i| i.opcode == Citrine::Opcode::CallNative && (i.raw & 0xFF_u32) == Citrine::NativeId::LoadPalette.value }
      has_set_pal = instructions.any? { |i| i.opcode == Citrine::Opcode::CallNative && (i.raw & 0xFF_u32) == Citrine::NativeId::SetPalette.value }
      has_draw_pro = instructions.any? { |i| i.opcode == Citrine::Opcode::CallNative && (i.raw & 0xFF_u32) == Citrine::NativeId::DrawTexturePro.value }


      has_load_tex.should be_true
      has_load_pal.should be_true
      has_set_pal.should be_true
      has_draw_pro.should be_true
    end
  end
end
