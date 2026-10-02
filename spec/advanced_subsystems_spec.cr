require "./spec_helper"
require "../src/stubs/citrine/draw"
require "../src/stubs/citrine/physics/box2d"
require "../src/stubs/citrine/physics/collision"
require "../src/stubs/citrine/events"
require "../src/stubs/citrine/input/usb"
require "../src/stubs/citrine/net"
require "../src/stubs/citrine/regex"
require "../src/stubs/citrine/shader"
require "../src/citrine/compiler/shader_compiler"

describe "Citrine Advanced Subsystems" do
  describe "Processing-Style Creative Coding API" do
    it "pushes and pops matrix transformation state" do
      Citrine::Draw.translate(10.0_f32, 20.0_f32)
      Citrine::Draw.push_matrix
      Citrine::Draw.translate(5.0_f32, 5.0_f32)
      Citrine::Draw.pop_matrix
      # Pop restored state
    end
  end

  describe "Box2D Rigid Body Physics" do
    it "simulates falling body under gravity and resolves collision" do
      world = Citrine::Physics::PhysicsWorld2D.new(Vector2.new(0.0_f32, 100.0_f32))

      ground = Citrine::Physics::RigidBody2D.new(
        position: Vector2.new(320.0_f32, 400.0_f32),
        width: 600.0_f32, height: 20.0_f32,
        mass: 0.0_f32,
        body_type: Citrine::Physics::BodyType::Static
      )
      world.add_body(ground)

      crate = Citrine::Physics::RigidBody2D.new(
        position: Vector2.new(320.0_f32, 100.0_f32),
        width: 32.0_f32, height: 32.0_f32,
        mass: 2.0_f32,
        body_type: Citrine::Physics::BodyType::Dynamic
      )
      world.add_body(crate)

      # Step simulation 10 frames
      10.times { world.step(1.0_f32 / 60.0_f32) }

      # Crate should have fallen towards ground
      crate.position.y.should be > 100.0_f32
    end
  end

  describe "Collision Filters & Raycasting" do
    it "filters collision by 16-bit bitmask" do
      player_filter = Citrine::Collision::Filter.new(layer: 1_u16, mask: 2_u16)
      enemy_filter = Citrine::Collision::Filter.new(layer: 2_u16, mask: 1_u16)
      item_filter = Citrine::Collision::Filter.new(layer: 4_u16, mask: 8_u16)

      player_filter.can_collide?(enemy_filter).should be_true
      player_filter.can_collide?(item_filter).should be_false
    end

    it "performs raycasting against AABB" do
      ray = Citrine::Collision::Ray2D.new(
        origin: Vector2.new(0.0_f32, 100.0_f32),
        direction: Vector2.new(1.0_f32, 0.0_f32),
        max_distance: 500.0_f32
      )
      hit = Citrine::Collision.raycast_aabb(ray, 200.0_f32, 80.0_f32, 40.0_f32, 40.0_f32)
      hit.hit.should be_true
      hit.distance.should be_close(200.0_f32, 0.1_f32)
      hit.normal.x.should eq(-1.0_f32)
    end
  end

  describe "Events & Pub-Sub" do
    it "registers listeners and dispatches events" do
      events = Citrine::EventEmitter.new
      received = ""
      events.on("player_scored") { |score| received = score }

      events.emit("player_scored", "1000")
      received.should eq("1000")
    end
  end

  describe "USB Input & Network Sockets" do
    it "tracks keyboard and mouse state" do
      Citrine::Input::Keyboard.simulate_key(Citrine::Input::Keyboard::KEY_SPACE, true)
      Citrine::Input::Keyboard.key_down?(Citrine::Input::Keyboard::KEY_SPACE).should be_true

      Citrine::Input::Mouse.update_state(400, 300, true, false)
      Citrine::Input::Mouse.x.should eq(400)
      Citrine::Input::Mouse.button_down?(Citrine::Input::Mouse::MOUSE_BUTTON_LEFT).should be_true
    end

    it "parses IPv4 addresses and creates sockets" do
      ip = Citrine::Net::IPAddress.parse("192.168.1.42")
      ip.to_s.should eq("192.168.1.42")

      udp = Citrine::Net::UdpSocket.new
      udp.bind(8080)
      udp.port.should eq(8080)
    end
  end

  describe "Lean Embedded Regex (Thompson NFA)" do
    it "matches literals, wildcards and anchors" do
      regex1 = Citrine::LeanRegex.new("^hello.*world$")
      regex1.match?("hello beautiful world").should be_true
      regex1.match?("goodbye beautiful world").should be_false

      regex2 = Citrine::LeanRegex.new("ps2|playstation")
      regex2.match?("sony ps2 console").should be_true
    end
  end

  describe "PS2 Shader Compiler (VU1 Microcode & GS Packets)" do
    it "compiles vertex shader to VU1 microcode VLIW instructions" do
      shader = Citrine::Shader.create("OceanWater") do |s|
        s.vertex_wave(amplitude: 4.0_f32, frequency: 0.2_f32)
        s.add_pass(Citrine::Shader::EffectType::Bloom, intensity: 0.8_f32, alpha: 192_u8)
      end

      microcode = Citrine::ShaderCompiler.compile_vu1_microcode(shader)
      microcode.size.should be >= 16

      blend_val = Citrine::ShaderCompiler.generate_gs_blend_packet(shader.passes[0])
      blend_val.should be > 0_u64
    end
  end
end
