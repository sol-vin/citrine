# Citrine 2D Rigid Body Physics Engine (Box2D Architecture)
# Modular engine abstraction - require "citrine/physics/box2d"

require "../../citrine"

module Citrine
  module Physics
    # Physics simulation simulation response categories.
    enum BodyType
      # Immovable body with infinite mass and zero velocity response.
      Static
      # Velocity-driven body unaffected by forces or collision reactions.
      Kinematic
      # Fully simulated body responsive to gravity, forces, impulses, and contact reactions.
      Dynamic
    end

    # 2D Rigid body with Newtonian kinematics, rotational inertia, and contact restitution.
    class RigidBody2D
      # World position of the body's center of mass.
      property position : Vector2
      # Linear velocity in units per second.
      property velocity : Vector2
      # Accumulated forces acting on the body during this step.
      property force : Vector2
      # Orientation angle in radians.
      property angle : Float32
      # Rotational angular velocity in radians per second.
      property angular_velocity : Float32
      # Accumulated torque acting on the body during this step.
      property torque : Float32
      # Bounding box width.
      property width : Float32
      # Bounding box height.
      property height : Float32
      # Total mass (0.0 for static bodies).
      property mass : Float32
      # Reciprocal of mass (1 / mass).
      property inv_mass : Float32
      # Moment of rotational inertia.
      property inertia : Float32
      # Reciprocal of moment of inertia (1 / inertia).
      property inv_inertia : Float32
      # Coefficient of bounciness/restitution (0.0 = inelastic, 1.0 = perfectly elastic).
      property restitution : Float32
      # Surface friction coefficient.
      property friction : Float32
      # Simulation type (Static, Kinematic, or Dynamic).
      property body_type : BodyType

      # Creates a new 2D rigid body.
      def initialize(
        @position : Vector2,
        @width : Float32 = 32.0_f32,
        @height : Float32 = 32.0_f32,
        @mass : Float32 = 1.0_f32,
        @body_type : BodyType = BodyType::Dynamic
      )
        @velocity = Vector2.new(0.0_f32, 0.0_f32)
        @force = Vector2.new(0.0_f32, 0.0_f32)
        @angle = 0.0_f32
        @angular_velocity = 0.0_f32
        @torque = 0.0_f32
        @restitution = 0.4_f32 # Bounciness
        @friction = 0.2_f32

        if @body_type == BodyType::Static || @mass <= 0.0_f32
          @inv_mass = 0.0_f32
          @inertia = 0.0_f32
          @inv_inertia = 0.0_f32
        else
          @inv_mass = 1.0_f32 / @mass
          # Moment of inertia for a rectangle: I = m * (w^2 + h^2) / 12
          @inertia = @mass * (@width * @width + @height * @height) / 12.0_f32
          @inv_inertia = 1.0_f32 / @inertia
        end
      end

      # Applies linear continuous force `f` to center of mass.
      def apply_force(f : Vector2)
        return if @body_type == BodyType::Static
        @force = Vector2.new(@force.x + f.x, @force.y + f.y)
      end

      # Applies instantaneous linear impulse to center of mass.
      def apply_impulse(impulse : Vector2)
        return if @body_type == BodyType::Static
        @velocity = Vector2.new(
          @velocity.x + impulse.x * @inv_mass,
          @velocity.y + impulse.y * @inv_mass
        )
      end

      # Integrates gravitational and external forces into linear and angular velocities.
      def integrate_forces(gravity : Vector2, dt : Float32)
        return if @body_type != BodyType::Dynamic

        @velocity = Vector2.new(
          @velocity.x + (gravity.x + @force.x * @inv_mass) * dt,
          @velocity.y + (gravity.y + @force.y * @inv_mass) * dt
        )
        @angular_velocity += (@torque * @inv_inertia) * dt

        # Reset forces
        @force = Vector2.new(0.0_f32, 0.0_f32)
        @torque = 0.0_f32
      end

      # Advances position and orientation from velocities and applies velocity damping.
      def integrate_velocities(dt : Float32)
        return if @body_type == BodyType::Static

        @position = Vector2.new(
          @position.x + @velocity.x * dt,
          @position.y + @velocity.y * dt
        )
        @angle += @angular_velocity * dt

        # Damping
        @velocity = Vector2.new(@velocity.x * 0.995_f32, @velocity.y * 0.995_f32)
        @angular_velocity *= 0.98_f32
      end
    end

    # Geometric contact manifold recording overlap between two colliding bodies.
    struct ContactManifold
      # First colliding body.
      property body_a : RigidBody2D
      # Second colliding body.
      property body_b : RigidBody2D
      # Collision contact normal vector pointing from A to B.
      property normal : Vector2
      # Penetration depth distance.
      property penetration : Float32

      # Creates a contact manifold record.
      def initialize(@body_a : RigidBody2D, @body_b : RigidBody2D, @normal : Vector2, @penetration : Float32)
      end

      # Resolves velocities by applying restitution impulses along the contact normal.
      def solve_velocity
        rv = Vector2.new(
          @body_b.velocity.x - @body_a.velocity.x,
          @body_b.velocity.y - @body_a.velocity.y
        )
        vel_along_normal = rv.x * @normal.x + rv.y * @normal.y
        return if vel_along_normal > 0.0_f32

        e = (@body_a.restitution < @body_b.restitution) ? @body_a.restitution : @body_b.restitution
        inv_mass_sum = @body_a.inv_mass + @body_b.inv_mass
        return if inv_mass_sum <= 0.0_f32

        j = -(1.0_f32 + e) * vel_along_normal / inv_mass_sum
        impulse = Vector2.new(@normal.x * j, @normal.y * j)

        @body_a.apply_impulse(Vector2.new(-impulse.x, -impulse.y))
        @body_b.apply_impulse(impulse)
      end

      # Resolves positional overlap using Baumgarte stabilization.
      def solve_position
        percent = 0.3_f32 # Penetration percentage to correct
        slop = 0.02_f32   # Penetration allowance
        correction_mag = Math.max(@penetration - slop, 0.0_f32) / (@body_a.inv_mass + @body_b.inv_mass) * percent
        correction = Vector2.new(@normal.x * correction_mag, @normal.y * correction_mag)

        if @body_a.body_type == BodyType::Dynamic
          @body_a.position = Vector2.new(
            @body_a.position.x - correction.x * @body_a.inv_mass,
            @body_a.position.y - correction.y * @body_a.inv_mass
          )
        end

        if @body_b.body_type == BodyType::Dynamic
          @body_b.position = Vector2.new(
            @body_b.position.x + correction.x * @body_b.inv_mass,
            @body_b.position.y + correction.y * @body_b.inv_mass
          )
        end
      end
    end

    # Simulation container managing rigid bodies, gravity, and iterative impulse constraint solving.
    class PhysicsWorld2D
      # Global gravitational acceleration vector.
      property gravity : Vector2
      # Active rigid bodies in the world.
      getter bodies : Array(RigidBody2D)

      # Creates a 2D physics world.
      def initialize(@gravity : Vector2 = Vector2.new(0.0_f32, 9.8_f32 * 30.0_f32))
        @bodies = [] of RigidBody2D
      end

      # Adds `body` to the simulation. Returns the added body.
      def add_body(body : RigidBody2D)
        @bodies << body
        body
      end

      # Steps the physics world by `dt` seconds with configurable velocity and position solver iterations.
      def step(dt : Float32, velocity_iters : Int32 = 4, position_iters : Int32 = 2)
        # 1. Integrate forces
        @bodies.each { |b| b.integrate_forces(@gravity, dt) }

        # 2. Collision detection (AABB narrowphase)
        manifolds = [] of ContactManifold
        n = @bodies.size
        i = 0
        while i < n
          j = i + 1
          while j < n
            b1 = @bodies[i]
            b2 = @bodies[j]

            if b1.body_type != BodyType::Static || b2.body_type != BodyType::Static
              # Distance between centers
              dx = b2.position.x - b1.position.x
              dy = b2.position.y - b1.position.y
              px = (b1.width + b2.width) * 0.5_f32 - dx.abs
              py = (b1.height + b2.height) * 0.5_f32 - dy.abs

              if px > 0.0_f32 && py > 0.0_f32
                normal = px < py ? Vector2.new(dx < 0.0_f32 ? -1.0_f32 : 1.0_f32, 0.0_f32) :
                                   Vector2.new(0.0_f32, dy < 0.0_f32 ? -1.0_f32 : 1.0_f32)
                pen = px < py ? px : py
                manifolds << ContactManifold.new(b1, b2, normal, pen)
              end
            end
            j += 1
          end
          i += 1
        end

        # 3. Solve velocity impulses
        velocity_iters.times do
          manifolds.each(&.solve_velocity)
        end

        # 4. Integrate velocities
        @bodies.each { |b| b.integrate_velocities(dt) }

        # 5. Solve position penetration
        position_iters.times do
          manifolds.each(&.solve_position)
        end
      end
    end
  end
end
