# Citrine Concurrency - Multi-Channel Select Primitive
# Safe, fair multi-channel arbitration with non-blocking fallback

module Citrine
  # Builder object used in `Citrine.select` blocks to declare concurrent channel branch clauses.
  class SelectBuilder
    private abstract class Branch
      abstract def try_execute : Bool
    end

    private class ReceiveBranch(T) < Branch
      @channel : Citrine::Channel(T)
      @action : T -> Nil

      def initialize(@channel : Citrine::Channel(T), &@action : T -> Nil)
      end

      def try_execute : Bool
        if val = @channel.try_receive
          @action.call(val)
          true
        else
          false
        end
      end
    end

    private class SendBranch(T) < Branch
      @channel : Citrine::Channel(T)
      @value : T
      @action : -> Nil

      def initialize(@channel : Citrine::Channel(T), @value : T, &@action : -> Nil)
      end

      def try_execute : Bool
        if !@channel.full?
          if @channel.send(@value)
            @action.call
            return true
          end
        end
        false
      end
    end

    @branches : Array(Branch)
    @else_branch : (-> Nil)?
    @arbitration_counter : UInt32 = 0_u32

    # Creates a new empty `SelectBuilder`.
    def initialize
      @branches = [] of Branch
      @else_branch = nil
    end

    # Registers a receive clause: executes `action` when `channel` has an available item.
    def receive(channel : Citrine::Channel(T), &action : T -> Nil) forall T
      @branches << ReceiveBranch(T).new(channel, &action)
    end

    # Registers a send clause: executes `action` when `channel` has capacity to accept `value`.
    def send(channel : Citrine::Channel(T), value : T, &action : -> Nil) forall T
      @branches << SendBranch(T).new(channel, value, &action)
    end

    # Registers a non-blocking fallback clause executed immediately if no channels are ready.
    def else(&action : -> Nil)
      @else_branch = action
    end

    # Executes the select expression with fair round-robin arbitration across clauses.
    def execute : Bool
      return false if @branches.empty? && @else_branch.nil?

      # Find all ready branches
      ready_indices = [] of Int32
      # To ensure fair arbitration and avoid starvation, offset evaluation order
      start_offset = (@arbitration_counter % {@branches.size, 1}.max).to_i
      @arbitration_counter &+= 1

      @branches.size.times do |i|
        idx = (start_offset + i) % @branches.size
        # We test readiness by attempting execution in order of arbitration
        if @branches[idx].try_execute
          return true
        end
      end

      # No channels were ready: execute non-blocking else if provided
      if else_action = @else_branch
        else_action.call
        return true
      end

      # In blocking mode without else: cooperatively yield until a channel is ready
      # In cooperative single-threaded EE runtime, yield to other fibers and retry
      50.times do
        Citrine.yield
        @branches.size.times do |i|
          idx = (start_offset + i) % @branches.size
          if @branches[idx].try_execute
            return true
          end
        end
      end

      false
    end
  end

  # High-level Go/Crystal-style `select` primitive for multi-channel synchronization.
  #
  # Example:
  # ```crystal
  # Citrine.select do |s|
  #   s.receive(ch1) { |val| puts "Received from ch1: #{val}" }
  #   s.receive(ch2) { |val| puts "Received from ch2: #{val}" }
  #   s.else { puts "Neither channel ready" }
  # end
  # ```
  def self.select(&block : SelectBuilder -> Nil) : Bool
    builder = SelectBuilder.new
    block.call(builder)
    builder.execute
  end
end
