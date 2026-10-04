# Citrine Immediate-Mode GUI Framework for PlayStation 2
# Modular engine abstraction - require "citrine/ui"

module Citrine
  module UI
    @@focus_id : Int32 = 0
    @@item_count : Int32 = 0

    def self.scope(&block : self.class -> Nil)
      @@item_count = 0
      yield self
    end

    def self.panel(x : Int32, y : Int32, w : Int32, h : Int32, title : String = "")
      # Background quad
      Citrine.draw_rectangle(x, y, w, h, Color.new(24_u8, 28_u8, 36_u8, 220_u8))
      # Border lines
      Citrine.draw_rectangle(x, y, w, 2, Color.new(70_u8, 80_u8, 100_u8, 255_u8))
      Citrine.draw_rectangle(x, y + h - 2, w, 2, Color.new(70_u8, 80_u8, 100_u8, 255_u8))
      Citrine.draw_rectangle(x, y, 2, h, Color.new(70_u8, 80_u8, 100_u8, 255_u8))
      Citrine.draw_rectangle(x + w - 2, y, 2, h, Color.new(70_u8, 80_u8, 100_u8, 255_u8))

      # Header bar
      if !title.empty?
        Citrine.draw_rectangle(x + 2, y + 2, w - 4, 24, Color.new(38_u8, 44_u8, 56_u8, 255_u8))
        Citrine.draw_text(title, x + 8, y + 6, 16, Color.new(230_u8, 235_u8, 245_u8, 255_u8))
      end
    end

    def self.button(text : String, x : Int32, y : Int32, w : Int32 = 140, h : Int32 = 28) : Bool
      this_id = @@item_count
      @@item_count += 1

      is_focused = (@@focus_id == this_id)

      bg_color = if is_focused
                   Color.new(80_u8, 120_u8, 200_u8, 255_u8)
                 else
                   Color.new(45_u8, 52_u8, 68_u8, 255_u8)
                 end

      Citrine.draw_rectangle(x, y, w, h, bg_color)
      # Text label centered
      Citrine.draw_text(text, x + 10, y + 6, 16, Color.new(255_u8, 255_u8, 255_u8, 255_u8))

      # DualShock Cross button press triggers button action if focused
      is_focused && Citrine.player(0).button_pressed?(Button::Cross)
    end

    def self.label(text : String, x : Int32, y : Int32, size : Int32 = 16)
      Citrine.draw_text(text, x, y, size, Color.new(220_u8, 225_u8, 230_u8, 255_u8))
    end

    def self.slider_float(label : String, val : Float32, min_val : Float32, max_val : Float32,
                          x : Int32, y : Int32, w : Int32 = 140) : Float32
      this_id = @@item_count
      @@item_count += 1
      is_focused = (@@focus_id == this_id)

      # Draw slider trough
      Citrine.draw_rectangle(x, y + 16, w, 8, Color.new(35_u8, 40_u8, 50_u8, 255_u8))

      pct = (val - min_val) / (max_val - min_val)
      pct = 0.0_f32 if pct < 0.0_f32
      pct = 1.0_f32 if pct > 1.0_f32

      fill_w = (w.to_f32 * pct).to_i32
      bar_color = is_focused ? Color.new(100_u8, 160_u8, 240_u8, 255_u8) : Color.new(60_u8, 100_u8, 160_u8, 255_u8)
      Citrine.draw_rectangle(x, y + 16, fill_w, 8, bar_color)

      Citrine.draw_text(label, x, y, 14, Color.new(200_u8, 205_u8, 215_u8, 255_u8))

      new_val = val
      if is_focused
        step = (max_val - min_val) * 0.05_f32
        if Citrine.player(0).button_pressed?(Button::Left)
          new_val -= step
        elsif Citrine.player(0).button_pressed?(Button::Right)
          new_val += step
        end
      end

      new_val = min_val if new_val < min_val
      new_val = max_val if new_val > max_val
      new_val
    end

    def self.slider_int(label : String, val : Int32, min_val : Int32, max_val : Int32,
                        x : Int32, y : Int32, w : Int32 = 140) : Int32
      f_val = slider_float(label, val.to_f32, min_val.to_f32, max_val.to_f32, x, y, w)
      f_val.to_i32
    end

    def self.checkbox(label : String, checked : Bool, x : Int32, y : Int32) : Bool
      this_id = @@item_count
      @@item_count += 1
      is_focused = (@@focus_id == this_id)

      box_color = is_focused ? Color.new(90_u8, 130_u8, 210_u8, 255_u8) : Color.new(50_u8, 55_u8, 65_u8, 255_u8)
      Citrine.draw_rectangle(x, y, 18, 18, box_color)

      if checked
        Citrine.draw_rectangle(x + 4, y + 4, 10, 10, Color.new(50_u8, 220_u8, 120_u8, 255_u8))
      end

      Citrine.draw_text(label, x + 26, y + 2, 16, Color.new(220_u8, 225_u8, 235_u8, 255_u8))

      if is_focused && Citrine.player(0).button_pressed?(Button::Cross)
        !checked
      else
        checked
      end
    end

    def self.progress_bar(val : Float32, max_val : Float32, x : Int32, y : Int32,
                          w : Int32 = 160, h : Int32 = 18)
      Citrine.draw_rectangle(x, y, w, h, Color.new(30_u8, 35_u8, 45_u8, 255_u8))
      pct = max_val > 0.0_f32 ? (val / max_val) : 0.0_f32
      pct = 0.0_f32 if pct < 0.0_f32
      pct = 1.0_f32 if pct > 1.0_f32

      fill_w = (w.to_f32 * pct).to_i32
      fill_col = if pct > 0.5_f32
                   Color.new(46_u8, 204_u8, 113_u8, 255_u8) # Green
                 elsif pct > 0.25_f32
                   Color.new(241_u8, 196_u8, 15_u8, 255_u8) # Yellow
                 else
                   Color.new(231_u8, 76_u8, 60_u8, 255_u8)  # Red
                 end

      Citrine.draw_rectangle(x + 1, y + 1, fill_w - 2, h - 2, fill_col)
    end
  end
end
