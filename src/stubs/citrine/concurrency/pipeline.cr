# Citrine Concurrency - Multi-Stage Concurrent Pipeline
# Channels data through chained worker stages with automatic backpressure

module Citrine
  module Concurrency
    # Multi-stage asynchronous pipeline connecting data transformation stages via typed Citrine channels.
    class Pipeline(InT, OutT)
      # Input channel feeding the head stage of the pipeline.
      getter in_channel : Citrine::Channel(InT)
      # Output channel collecting the final stage results.
      getter out_channel : Citrine::Channel(OutT)

      # Creates a new single-stage pipeline transforming `InT` items into `OutT` via `block`.
      def initialize(capacity : Int32 = 16, &block : InT -> OutT)
        @in_channel = Citrine::Channel(InT).new(capacity)
        @out_channel = Citrine::Channel(OutT).new(capacity)

        Citrine.spawn do
          while true
            if item = @in_channel.try_receive
              result = block.call(item)
              @out_channel.send(result)
            else
              Citrine.yield
            end
          end
        end
      end

      # Chains an additional transformation stage onto this pipeline, returning the chained pipeline.
      def pipe(capacity : Int32 = 16, &next_block : OutT -> NextT) : Pipeline(InT, NextT) forall NextT
        Pipeline(InT, NextT).new_chained(@in_channel, @out_channel, capacity, &next_block)
      end

      protected def self.new_chained(
        orig_in : Citrine::Channel(InT),
        prev_out : Citrine::Channel(PrevOutT),
        capacity : Int32,
        &next_block : PrevOutT -> OutT
      ) : Pipeline(InT, OutT) forall PrevOutT
        p = Pipeline(InT, OutT).allocate
        p.initialize_chained(orig_in, prev_out, capacity, &next_block)
        p
      end

      protected def initialize_chained(
        @in_channel : Citrine::Channel(InT),
        prev_out : Citrine::Channel(PrevOutT),
        capacity : Int32,
        &next_block : PrevOutT -> OutT
      ) forall PrevOutT
        @out_channel = Citrine::Channel(OutT).new(capacity)
        Citrine.spawn do
          while true
            if item = prev_out.try_receive
              res = next_block.call(item)
              @out_channel.send(res)
            else
              Citrine.yield
            end
          end
        end
      end

      # Pushes an input item into the pipeline's head channel.
      def push(value : InT) : Bool
        @in_channel.send(value)
      end

      # Alias for `push`.
      def post(value : InT) : Bool
        push(value)
      end

      # Polls for the next output item without blocking; returns `nil` if not yet ready.
      def pull : OutT?
        @out_channel.try_receive
      end

      # Alias for `pull`.
      def receive : OutT?
        pull
      end

      # Waits cooperatively until an output item is produced, raising a panic on timeout.
      def pull_blocking(timeout_yields : Int32 = 10_000) : OutT
        yields = 0
        while (val = @out_channel.try_receive).nil?
          Citrine.yield
          yields += 1
          if yields > timeout_yields
            Citrine.panic("Pipeline pull timeout: exceeded #{timeout_yields} yields waiting for stage output")
          end
        end
        val.not_nil!
      end

      # Alias for `pull_blocking`.
      def receive_blocking(timeout_yields : Int32 = 10_000) : OutT
        pull_blocking(timeout_yields)
      end
    end
  end
end
