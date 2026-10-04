require "./spec_helper"
require "../src/stubs/citrine"
require "../src/stubs/citrine/physics"
require "../src/stubs/citrine/physics/collision"

describe "Citrine Physics 2D & Collision Subsystem" do
  describe "Q16.16 FixedPoint Arithmetic" do
    it "converts between floats, integers, and fixed-point representations" do
      fp1 = FixedPoint.from_float(1.5_f32)
      fp1.to_float.should be_close(1.5_f32, 0.001_f32)
      fp1.to_int.should eq(1)

      fp2 = FixedPoint.from_int(10)
      fp2.to_int.should eq(10)
      fp2.to_float.should eq(10.0_f32)
    end

    it "performs basic arithmetic operations accurately" do
      a = FixedPoint.from_float(3.25_f32)
      b = FixedPoint.from_float(1.75_f32)

      sum = a + b
      sum.to_float.should be_close(5.0_f32, 0.001_f32)

      diff = a - b
      diff.to_float.should be_close(1.5_f32, 0.001_f32)

      prod = a * b
      prod.to_float.should be_close(5.6875_f32, 0.01_f32)

      quot = a / b
      quot.to_float.should be_close(1.8571_f32, 0.01_f32)
    end
  end

  describe "Broadphase AABB & Circle Colliders" do
    it "detects overlaps between axis-aligned bounding boxes" do
      box1 = AABB.new(0.0_f32, 0.0_f32, 50.0_f32, 50.0_f32)
      box2 = AABB.new(40.0_f32, 40.0_f32, 50.0_f32, 50.0_f32)
      box3 = AABB.new(100.0_f32, 100.0_f32, 50.0_f32, 50.0_f32)

      box1.overlaps?(box2).should be_true
      box2.overlaps?(box1).should be_true
      box1.overlaps?(box3).should be_false

      box1.contains?(25.0_f32, 25.0_f32).should be_true
      box1.contains?(60.0_f32, 25.0_f32).should be_false
    end

    it "detects circle-to-circle and circle-to-AABB intersections" do
      c1 = CircleCollider.new(100.0_f32, 100.0_f32, 20.0_f32)
      c2 = CircleCollider.new(130.0_f32, 100.0_f32, 15.0_f32)
      c3 = CircleCollider.new(200.0_f32, 100.0_f32, 10.0_f32)

      c1.overlaps?(c2).should be_true
      c1.overlaps?(c3).should be_false

      box = AABB.new(115.0_f32, 90.0_f32, 30.0_f32, 20.0_f32)
      c1.overlaps_aabb?(box).should be_true
    end
  end

  describe "Collision Filtering & Raycasting (CCD)" do
    it "evaluates 16-bit layer and mask collision filtering" do
      # Player: Layer 1 (0x0001), collides with Enemies (0x0002) and Walls (0x0004) -> Mask 0x0006
      player_filter = Citrine::Collision::Filter.new(layer: 0x0001_u16, mask: 0x0006_u16)

      # Enemy: Layer 2 (0x0002), collides with Player (0x0001) -> Mask 0x0001
      enemy_filter = Citrine::Collision::Filter.new(layer: 0x0002_u16, mask: 0x0001_u16)

      # Collectible: Layer 3 (0x0008), collides only with Player (0x0001) -> Mask 0x0001
      collectible_filter = Citrine::Collision::Filter.new(layer: 0x0008_u16, mask: 0x0001_u16)

      player_filter.can_collide?(enemy_filter).should be_true
      enemy_filter.can_collide?(player_filter).should be_true

      # Enemy and Collectible do not collide
      enemy_filter.can_collide?(collectible_filter).should be_false
      collectible_filter.can_collide?(enemy_filter).should be_false
    end

    it "constructs normalized 2D rays for cast queries" do
      origin = Vector2.new(10.0_f32, 10.0_f32)
      dir = Vector2.new(3.0_f32, 4.0_f32) # Length = 5
      ray = Citrine::Collision::Ray2D.new(origin, dir, 100.0_f32)

      ray.origin.x.should eq(10.0_f32)
      ray.origin.y.should eq(10.0_f32)
      ray.direction.x.should be_close(0.6_f32, 0.001_f32)
      ray.direction.y.should be_close(0.8_f32, 0.001_f32)
      ray.max_distance.should eq(100.0_f32)
    end
  end

  describe "Verlet Particle Integration & Restitution" do
    it "updates particle trajectory under gravity and drag" do
      p = Citrine::VerletParticle.new(100.0_f32, 100.0_f32)
      p.x.should eq(100.0_f32)
      p.y.should eq(100.0_f32)

      # Update with 1/60s delta time and gravity 500
      p.update(0.016_f32, gravity: 500.0_f32)

      p.x.should eq(100.0_f32)
      p.y.should be > 100.0_f32 # Fell downward
    end

    it "constrains particles within bounds and reflects velocity on bounce" do
      p = Citrine::VerletParticle.new(50.0_f32, 395.0_f32)
      # Accelerate downward past floor at 400
      p.update(0.016_f32, gravity: 2000.0_f32)

      # Constrain within [0, 0, 640, 400]
      p.constrain(0.0_f32, 0.0_f32, 640.0_f32, 400.0_f32, bounce: 0.8_f32)

      p.y.should be <= 400.0_f32
    end
  end
end
