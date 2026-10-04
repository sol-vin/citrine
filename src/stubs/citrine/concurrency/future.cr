# Citrine Concurrency - Future & Promise Asynchronous Primitives
# Handles asynchronous computations with cooperative awaiting

module Citrine
  # Writable side of an asynchronous computation.
  # Can be resolved with a value or rejected with an error.
  class Promise(T)
    # The associated read-only Future handle.
    getter future : Future(T)

    # Initializes a new Promise with an unresolved Future.
    def initialize
      @future = Future(T).new
    end

    # Resolves the computation with a successful result.
    def resolve(value : T)
      @future.complete_with_value(value)
    end

    # Rejects the computation with an error message.
    def reject(error_message : String)
      @future.complete_with_error(error_message)
    end
  end

  # Read-only handle to a value produced by a concurrent asynchronous computation.
  class Future(T)
    # Returns true if the computation has finished (successfully or failed).
    getter? completed : Bool

    # Returns true if the computation ended in failure.
    getter? failed : Bool

    # The resulting value if resolved successfully.
    getter value : T?

    # Error message if rejected.
    getter error : String?

    # Initializes an uncompleted Future.
    def initialize
      @completed = false
      @failed = false
      @value = nil
      @error = nil
    end

    # Cooperatively blocks the calling fiber until the future resolves, returning the computed value.
    # Panics if the computation fails or if `timeout_yields` is exceeded.
    def await(timeout_yields : Int32 = 10_000) : T
      yields = 0
      while !@completed
        Citrine.yield
        yields += 1
        if yields > timeout_yields
          Citrine.panic("Future await timeout: exceeded #{timeout_yields} yields waiting for computation")
        end
      end

      if @failed
        Citrine.panic(@error || "Future failed with unknown error")
      end

      @value.not_nil!
    end

    # Internal completion hook: resolves future with a value.
    def complete_with_value(val : T)
      return if @completed
      @value = val
      @completed = true
    end

    # Internal completion hook: rejects future with an error message.
    def complete_with_error(err : String)
      return if @completed
      @error = err
      @failed = true
      @completed = true
    end
  end

  # Spawns an asynchronous computation on a worker fiber, returning a Future handle.
  #
  # Example:
  # ```crystal
  # future = Citrine.async do
  #   calculate_complex_mesh_normals
  # end
  # result = future.await
  # ```
  def self.async(&block : -> T) : Future(T) forall T
    promise = Promise(T).new
    Citrine.spawn do
      begin
        result = block.call
        promise.resolve(result)
      rescue ex
        promise.reject(ex.message || "Asynchronous fiber failed")
      end
    end
    promise.future
  end
end
