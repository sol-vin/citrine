# Citrine Concurrency - Structured Concurrency Scope
# Guarantees that all child fibers complete before the enclosing scope exits

module Citrine
  module Concurrency
    # Structured concurrency lifetime manager.
    # Enforces lifetime bounds on spawned fibers, guaranteeing that all concurrent
    # child fibers complete before the enclosing scope block returns.
    #
    # Example:
    # ```crystal
    # Citrine.with_scope do |s|
    #   s.spawn { process_mesh }
    #   s.spawn { load_audio }
    # end # Guarantees mesh and audio fibers finish before continuing
    # ```
    class Scope
      @wg : Citrine::WaitGroup
      @fibers : Array(Citrine::Fiber)

      # Initializes a new structured concurrency scope.
      def initialize
        @wg = Citrine::WaitGroup.new
        @fibers = [] of Citrine::Fiber
      end

      # Spawns a concurrent fiber tracked and bounded by this scope.
      def spawn(&block) : Citrine::Fiber
        @wg.add(1)
        fib = Citrine.spawn do
          begin
            block.call
          ensure
            @wg.done
          end
        end
        @fibers << fib
        fib
      end

      # Cooperatively waits for all fibers in this scope to complete.
      def wait(timeout_yields : Int32 = 10_000)
        @wg.wait(timeout_yields)
      end
    end
  end

  # Executes a structured concurrency block with an automatic scope barrier.
  # All fibers spawned inside the block via `scope.spawn` are guaranteed to finish
  # before this method returns.
  def self.with_scope(&block : Concurrency::Scope -> Nil)
    scope = Concurrency::Scope.new
    begin
      block.call(scope)
    ensure
      scope.wait
    end
  end
end
