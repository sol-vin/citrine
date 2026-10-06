require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/draw2d"
require "../src/stubs/citrine/gl"

describe "Citrine::Draw2D & Graphics DSL" do
  describe "Transform2D (2D Affine Matrix)" do
    it "initializes identity matrix" do
      t = Citrine::Draw2D::Transform2D.identity
      x, y = t.transform_point(10, 20)
      x.should eq(10.0_f32)
      y.should eq(20.0_f32)
    end

    it "applies translation" do
      t = Citrine::Draw2D::Transform2D.translation(50, 100)
      x, y = t.transform_point(10, 20)
      x.should eq(60.0_f32)
      y.should eq(120.0_f32)
    end

    it "applies rotation around origin" do
      t = Citrine::Draw2D::Transform2D.rotation(90)
      x, y = t.transform_point(10, 0)
      x.should be_close(0.0_f32, 0.001_f32)
      y.should be_close(10.0_f32, 0.001_f32)
    end

    it "applies rotation around custom pivot" do
      # Rotating (20, 10) by 90 deg around pivot (10, 10)
      t = Citrine::Draw2D::Transform2D.rotation(90, ox: 10, oy: 10)
      # Pivot point itself must be invariant
      px, py = t.transform_point(10, 10)
      px.should be_close(10.0_f32, 0.001_f32)
      py.should be_close(10.0_f32, 0.001_f32)

      # Point (20, 10) rotated 90 deg around (10, 10) -> (10, 20)
      x, y = t.transform_point(20, 10)
      x.should be_close(10.0_f32, 0.001_f32)
      y.should be_close(20.0_f32, 0.001_f32)
    end

    it "multiplies affine matrices" do
      t1 = Citrine::Draw2D::Transform2D.translation(10, 20)
      t2 = Citrine::Draw2D::Transform2D.scaling(2, 3)
      combined = t1 * t2
      x, y = combined.transform_point(5, 5)
      # Scaling then translation: 5*2 + 10 = 20, 5*3 + 20 = 35
      x.should eq(20.0_f32)
      y.should eq(35.0_f32)
    end
  end

  describe "Draw2D Primitives & Styling" do
    it "executes scoped draw_2d frame block" do
      executed = false
      Citrine.draw_2d do |d|
        d.clear(Color::Black)
        d.rect(10, 20, 100, 50, fill: Color::Red)
        d.circle(50, 50, 25, fill: Color::Blue)
        executed = true
      end
      executed.should be_true
    end

    it "supports rounded rectangle geometry" do
      executed = false
      Citrine.draw_2d do |d|
        d.rect(10, 10, 80, 40, radius: 8, fill: Color::Green, stroke: Color::White)
        executed = true
      end
      executed.should be_true
    end

    it "supports rotated primitives with arbitrary pivot" do
      executed = false
      Citrine.draw_2d do |d|
        d.rect(50, 50, 40, 40, rotation: 45.0, origin: Vector2.new(20, 20), fill: Color::Yellow)
        executed = true
      end
      executed.should be_true
    end

    it "supports rotated text rendering" do
      executed = false
      Citrine.draw_2d do |d|
        d.text("ROTATED TEXT", 100, 150, size: 16, color: Color::White, rotation: 30.0, origin: Vector2.new(50, 8))
        executed = true
      end
      executed.should be_true
    end

    it "supports star and polygon primitives" do
      executed = false
      Citrine.draw_2d do |d|
        d.star(100, 100, points: 5, inner_r: 10, outer_r: 25, fill: Color::Yellow)
        pts = [Vector2.new(10, 10), Vector2.new(30, 10), Vector2.new(40, 30), Vector2.new(20, 40)]
        d.polygon(pts, fill: Color::Cyan)
        executed = true
      end
      executed.should be_true
    end

    it "handles scoped transform and style blocks" do
      executed = false
      Citrine.draw_2d do |d|
        d.with_style(fill: Color::Red, stroke: Color::Yellow, weight: 2.0) do
          d.transform(x: 50, y: 50, rotation: 45.0) do
            d.rect(0, 0, 30, 30)
            executed = true
          end
        end
      end
      executed.should be_true
    end
  end

  describe "Citrine::GL Scoped DSL" do
    it "executes scoped triangles and matrix blocks" do
      executed = false
      Citrine::GL.matrix do
        Citrine::GL.translate(10, 20, 0)
        Citrine::GL.triangles do
          Citrine::GL.color(Color::Red)
          Citrine::GL.vertex(0, 0)
          Citrine::GL.vertex(50, 0)
          Citrine::GL.vertex(25, 50)
          executed = true
        end
      end
      executed.should be_true
    end
  end
end
