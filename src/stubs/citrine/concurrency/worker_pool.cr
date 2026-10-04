# Citrine Concurrency - Production-Grade Worker Pool & Compute Pool
# Thread/fiber pool with backpressure, synchronous dispatch, idle waiting, and telemetry

module Citrine
  module Concurrency
    # Production-grade worker pool dispatching tasks across a fixed number of worker fibers.
    class WorkerPool(T)
      private record Task(T), payload : T, promise : Citrine::Promise(Bool)?

      # Number of worker fibers servicing this pool.
      getter worker_count : Int32
      # Backing task queue channel.
      getter in_channel : Citrine::Channel(Task(T))
      # Active worker fiber instances.
      getter worker_fibers : Array(Citrine::Fiber)
      # Total count of successfully completed tasks.
      getter completed_tasks : Int32
      # Total count of failed tasks that raised exceptions.
      getter failed_tasks : Int32
      @active_jobs : Int32
      @running : Bool

      # Creates a new `WorkerPool` with `worker_count` fibers processing items via `worker_block`.
      def initialize(@worker_count : Int32, capacity : Int32 = 32, &worker_block : T -> Nil)
        @in_channel = Citrine::Channel(Task(T)).new(capacity)
        @worker_fibers = [] of Citrine::Fiber
        @completed_tasks = 0
        @failed_tasks = 0
        @active_jobs = 0
        @running = true

        @worker_count.times do
          fib = Citrine.spawn do
            while @running
              if task = @in_channel.try_receive
                @active_jobs += 1
                begin
                  worker_block.call(task.payload)
                  @completed_tasks += 1
                  task.promise.try(&.resolve(true))
                rescue ex
                  @failed_tasks += 1
                  task.promise.try(&.reject(ex.message || "Worker execution failed"))
                ensure
                  @active_jobs -= 1
                end
              else
                Citrine.yield
              end
            end
          end
          @worker_fibers << fib
        end
      end

      # Asynchronously posts a job to the pool. Returns true if queued, false if full or shut down.
      def post(item : T) : Bool
        return false unless @running
        @in_channel.send(Task(T).new(item, nil))
      end

      # Non-blocking post: returns true if placed in queue immediately, false otherwise.
      def try_post(item : T) : Bool
        return false unless @running || @in_channel.full?
        @in_channel.send(Task(T).new(item, nil))
      end

      # Synchronously posts a job and cooperatively awaits completion.
      def post_sync(item : T) : Bool
        unless @running
          Citrine.panic("WorkerPool post error: pool is already shut down")
        end
        promise = Citrine::Promise(Bool).new
        task = Task(T).new(item, promise)
        @in_channel.send(task)
        promise.future.await
      end

      # Returns the number of currently queued tasks awaiting execution.
      def queue_depth : Int32
        @in_channel.size
      end

      # Returns the number of alive worker fibers.
      def active_workers : Int32
        @worker_fibers.count(&.alive?)
      end

      # Returns true if no jobs are in the queue or actively running.
      def idle? : Bool
        @in_channel.empty? && @active_jobs == 0
      end

      # Cooperatively yields until all queued and running tasks are completed.
      def wait_idle(timeout_yields : Int32 = 10_000)
        yields = 0
        while !idle?
          Citrine.yield
          yields += 1
          if yields > timeout_yields
            Citrine.panic("WorkerPool wait_idle timeout: exceeded #{timeout_yields} yields with #{@active_jobs} active and #{queue_depth} queued jobs")
          end
        end
      end

      # Gracefully shuts down the worker pool. If drain is true, finishes remaining tasks.
      def shutdown(drain : Bool = true)
        if drain
          wait_idle
        end
        @running = false
      end
    end

    # Specialized pool for computational jobs producing typed return values of type `R`.
    class ComputePool(T, R)
      private record Task(T, R), payload : T, promise : Citrine::Promise(R)?

      # Number of worker fibers servicing this compute pool.
      getter worker_count : Int32
      # Backing task queue channel.
      getter in_channel : Citrine::Channel(Task(T, R))
      # Active compute fiber instances.
      getter worker_fibers : Array(Citrine::Fiber)
      # Total count of successfully completed compute tasks.
      getter completed_tasks : Int32
      # Total count of failed compute tasks.
      getter failed_tasks : Int32
      @active_jobs : Int32
      @running : Bool

      # Creates a new `ComputePool` with `worker_count` fibers processing items via `worker_block`.
      def initialize(@worker_count : Int32, capacity : Int32 = 32, &worker_block : T -> R)
        @in_channel = Citrine::Channel(Task(T, R)).new(capacity)
        @worker_fibers = [] of Citrine::Fiber
        @completed_tasks = 0
        @failed_tasks = 0
        @active_jobs = 0
        @running = true

        @worker_count.times do
          fib = Citrine.spawn do
            while @running
              if task = @in_channel.try_receive
                @active_jobs += 1
                begin
                  res = worker_block.call(task.payload)
                  @completed_tasks += 1
                  task.promise.try(&.resolve(res))
                rescue ex
                  @failed_tasks += 1
                  task.promise.try(&.reject(ex.message || "Compute worker failed"))
                ensure
                  @active_jobs -= 1
                end
              else
                Citrine.yield
              end
            end
          end
          @worker_fibers << fib
        end
      end

      # Asynchronously posts a fire-and-forget compute job.
      def post(item : T) : Bool
        return false unless @running
        @in_channel.send(Task(T, R).new(item, nil))
      end

      # Posts a job and returns a `Future(R)` representing the asynchronous computation.
      def post_async(item : T) : Citrine::Future(R)
        unless @running
          Citrine.panic("ComputePool post error: pool is already shut down")
        end
        promise = Citrine::Promise(R).new
        task = Task(T, R).new(item, promise)
        @in_channel.send(task)
        promise.future
      end

      # Synchronously posts a job and cooperatively awaits the computed result of type `R`.
      def post_sync(item : T) : R
        post_async(item).await
      end

      # Returns the number of currently queued tasks awaiting execution.
      def queue_depth : Int32
        @in_channel.size
      end

      # Returns the number of alive worker fibers.
      def active_workers : Int32
        @worker_fibers.count(&.alive?)
      end

      # Returns true if no jobs are in the queue or actively running.
      def idle? : Bool
        @in_channel.empty? && @active_jobs == 0
      end

      # Cooperatively yields until all queued and running tasks are completed.
      def wait_idle(timeout_yields : Int32 = 10_000)
        yields = 0
        while !idle?
          Citrine.yield
          yields += 1
          if yields > timeout_yields
            Citrine.panic("ComputePool wait_idle timeout: exceeded #{timeout_yields} yields with #{@active_jobs} active and #{queue_depth} queued jobs")
          end
        end
      end

      # Gracefully shuts down the compute pool. If drain is true, finishes remaining tasks.
      def shutdown(drain : Bool = true)
        if drain
          wait_idle
        end
        @running = false
      end
    end
  end
end
