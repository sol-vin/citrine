# Citrine PS2 Compute Shader Subsystem (VU0 Autonomous Micro Mode)
# Modular engine abstraction - require "citrine/compute"

require "../citrine"

module Citrine
  # Compute shader engine targeting Vector Unit 0 (VU0) in autonomous Micro Mode.
  # Executes parallel SIMD microcode kernels (physics, cloth, particle simulation,
  # matrix skinning, and collision detection) concurrently with the Emotion Engine CPU.
  module Compute
    # Buffer descriptor for compute kernel memory regions in VU0 Data Memory (4 KB / 256 quadwords).
    class Buffer(T)
      getter size : Int32
      getter data : Array(T)

      def initialize(@size : Int32)
        @data = Array(T).new(@size)
      end

      def initialize(@size : Int32, initial_value : T)
        @data = Array(T).new(@size, initial_value)
      end

      def [](index : Int32) : T
        @data[index]
      end

      def []=(index : Int32, value : T)
        @data[index] = value
      end
    end

    # Variable declaration in compute kernel.
    struct Variable
      property name : String
      property type_name : String
      property is_buffer : Bool
      property buffer_size : Int32

      def initialize(@name : String, @type_name : String, @is_buffer : Bool = false, @buffer_size : Int32 = 0)
      end
    end

    # Programmable compute kernel compiling to VU0 microcode.
    class Kernel
      property name : String
      property buffers : Hash(String, Variable)
      property uniforms : Hash(String, Variable)
      property code_block : Proc(Int32, Nil)?
      property microcode_bytes : Bytes?

      def initialize(@name : String)
        @buffers = Hash(String, Variable).new
        @uniforms = Hash(String, Variable).new
        @code_block = nil
        @microcode_bytes = nil
      end

      # Declares an input/output buffer in VU0 Data RAM.
      def buffer(name : String | Symbol, type_name : String, size : Int32 = 256)
        @buffers[name.to_s] = Variable.new(name.to_s, type_name, is_buffer: true, buffer_size: size)
      end

      # Declares a scalar or vector uniform parameter.
      def uniform(name : String | Symbol, type_name : String)
        @uniforms[name.to_s] = Variable.new(name.to_s, type_name)
      end

      # Defines kernel body executed per element.
      def main(&block : Int32 -> Nil)
        @code_block = block
      end
    end

    @@active_kernels = Hash(String, Kernel).new
    @@is_dispatching : Bool = false

    # Declares a new named compute shader kernel:
    # ```crystal
    # Citrine::Compute.kernel "ParticleSimulation" do |k|
    #   k.buffer :positions, "Vec4", size: 256
    #   k.buffer :velocities, "Vec4", size: 256
    #   k.uniform :gravity, "Vec4"
    #   k.uniform :dt, "Float32"
    #
    #   k.main do |i|
    #     # Kernel execution logic
    #   end
    # end
    # ```
    def self.kernel(name : String, &block : Kernel -> Nil) : Kernel
      k = Kernel.new(name)
      yield k
      @@active_kernels[name] = k
      k
    end

    # Retrieves registered compute kernel by name.
    def self.get_kernel(name : String) : Kernel?
      @@active_kernels[name]?
    end

    # Dispatches compute kernel to VU0 Micro Mode across `count` elements.
    # On real hardware, triggers MSCAL0 microprogram initiation.
    def self.dispatch(kernel : Kernel | String, count : Int32)
      k = kernel.is_a?(Kernel) ? kernel : @@active_kernels[kernel]?
      return unless k

      @@is_dispatching = true

      # Execute host simulation of kernel body or dispatch native VU0
      if cb = k.code_block
        count.times do |i|
          cb.call(i)
        end
      end

      @@is_dispatching = false
    end

    # Synchronizes EE CPU execution with VU0 completion.
    def self.sync
      # On real hardware: wait for VU0 microprogram completion (VIF0 / MSCAL0 status flag)
      @@is_dispatching = false
    end

    # Returns true if a compute kernel is actively processing on VU0.
    def self.busy? : Bool
      @@is_dispatching
    end
  end
end
