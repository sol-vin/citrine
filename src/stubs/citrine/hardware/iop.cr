# Citrine I/O Processor (IOP MIPS R3000A @ 37.5 MHz) Subsystem
# Modular hardware abstraction - require "citrine/hardware/iop"
# Asynchronous SIF RPC job offloading for background I/O, audio decoding, and decompression

module Citrine
  module Hardware
    module IOP
      # Identifies the category of hardware work offloaded to the IOP co-processor.
      enum JobType : UInt8
        # Asynchronous disc reading via SIF DMA.
        DiscSectorRead       = 1
        # Streaming ADPCM audio decode via SPU2.
        AudioStreamDecode    = 2
        # Memory Card save/load I/O operations.
        MemoryCardIo         = 3
        # Background chunk decompression (gzip/LZ4).
        BackgroundDecompress = 4
      end

      # Execution status of an offloaded co-processor task.
      enum JobStatus : UInt8
        # Job queued but not yet scheduled.
        Pending   = 0
        # Job actively executing on the IOP core.
        Running   = 1
        # Job successfully finished.
        Completed = 2
        # Job encountered an I/O error or failure.
        Failed    = 3
      end

      # Tracking receipt returned when dispatching asynchronous work to the IOP.
      struct JobTicket
        # Unique ticket identifier.
        getter id : UInt32
        # Type of job executing.
        getter type : JobType
        # Current status of the job.
        getter status : JobStatus
        # Payload size or bytes processed.
        getter bytes_processed : UInt32

        def initialize(@id : UInt32, @type : JobType, @status : JobStatus = JobStatus::Pending, @bytes_processed : UInt32 = 0_u32)
        end
      end

      class JobDispatcher
        @next_ticket_id : UInt32
        @active_jobs : Hash(UInt32, JobTicket)

        def initialize
          @next_ticket_id = 1_u32
          @active_jobs = Hash(UInt32, JobTicket).new
        end

        # Submits an asynchronous job across the EE-to-IOP SIF RPC interface
        def submit_job(type : JobType, size_bytes : UInt32 = 2048_u32) : UInt32
          ticket_id = @next_ticket_id
          @next_ticket_id += 1

          # In emulation/stubs, jobs start as running and finish after cooperative steps
          ticket = JobTicket.new(ticket_id, type, JobStatus::Running, size_bytes)
          @active_jobs[ticket_id] = ticket
          ticket_id
        end

        # Polls SIF completion status for an offloaded job
        def job_completed?(ticket_id : UInt32) : Bool
          if ticket = @active_jobs[ticket_id]?
            ticket.status == JobStatus::Completed
          else
            false
          end
        end

        # Advances job progress in the background (called at V-Blank or SIF DMA interrupt)
        def step_simulated_jobs
          @active_jobs.each do |id, ticket|
            if ticket.status == JobStatus::Running
              @active_jobs[id] = JobTicket.new(id, ticket.type, JobStatus::Completed, ticket.bytes_processed)
            end
          end
        end

        # Cooperatively awaits job completion across the SIF bus
        def await_job(ticket_id : UInt32, timeout_yields : Int32 = 10_000) : Bool
          yields = 0
          while !job_completed?(ticket_id)
            step_simulated_jobs
            Citrine.yield
            yields += 1
            if yields > timeout_yields
              Citrine.panic("IOP SIF job timeout: ticket ##{ticket_id} exceeded #{timeout_yields} yields")
            end
          end
          true
        end

        def active_count : Int32
          @active_jobs.values.count { |j| j.status == JobStatus::Running }
        end
      end

      # Global IOP Job Dispatcher Singleton instance.
      @@dispatcher : JobDispatcher?

      # Returns the global IOP Job Dispatcher singleton.
      def self.dispatcher : JobDispatcher
        @@dispatcher ||= JobDispatcher.new
      end

      # Submits an asynchronous task to the IOP co-processor across the SIF RPC interface.
      # Returns a unique `ticket_id`.
      def self.submit_job(type : JobType, size_bytes : UInt32 = 2048_u32) : UInt32
        dispatcher.submit_job(type, size_bytes)
      end

      # Returns true if the offloaded job specified by `ticket_id` has completed.
      def self.job_completed?(ticket_id : UInt32) : Bool
        dispatcher.job_completed?(ticket_id)
      end

      # Cooperatively yields the calling fiber until the IOP job completes.
      def self.await_job(ticket_id : UInt32) : Bool
        dispatcher.await_job(ticket_id)
      end
    end
  end
end
