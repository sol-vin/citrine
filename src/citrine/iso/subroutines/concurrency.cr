module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_concurrency_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?, sched_addr : UInt32) : Bool
        case sname
        when "Citrine_FiberSpawn" # A0 = func_idx, A1 = arg
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x88, T0) # fiber_count
          emitter.ori(T2, ZERO, 32)
          emitter.sltu(T3, T1, T2)
          emitter.beqz(T3, "fib_sp_done")
          emitter.nop

          # Fiber table entry at 0x70002000 + (fiber_count * 32)
          emitter.sll(T2, T1, 5) # fiber_count * 32
          emitter.ori(T3, T0, 0x2000)
          emitter.addu(T3, T3, T2) # T3 = fiber entry

          emitter.sw(A0, 0, T3) # func_idx
          emitter.sw(A1, 4, T3) # arg
          emitter.ori(T4, ZERO, 1)
          emitter.sw(T4, 8, T3) # state = 1 (READY)

          # Initial fiber_pc = citrine_func_table + (func_idx * 8)
          emitter.la(T4, "citrine_func_table")
          emitter.sll(T5, A0, 3) # func_idx * 8
          emitter.addu(T4, T4, T5)
          emitter.sw(T4, 12, T3) # fiber_pc

          # Initial fiber_sp = 0x01FE0000 - (fiber_count * 0x1000)
          emitter.lui(T4, 0x01FE)
          emitter.sll(T5, T1, 12) # fiber_count * 4096
          emitter.subu(T4, T4, T5)
          emitter.sw(T4, 16, T3) # fiber_sp

          # Initial fiber_k0 = 0x70001000 + (fiber_count * 128)
          emitter.ori(T4, T0, 0x1000)
          emitter.sll(T5, T1, 7) # fiber_count * 128
          emitter.addu(T4, T4, T5)
          emitter.sw(T4, 20, T3) # fiber_k0

          # Set up register $r0 at 0(fiber_k0) with arg (A1)
          emitter.sw(A1, 0, T4)

          # fiber_count++
          emitter.addiu(T1, T1, 1)
          emitter.sw(T1, 0x88, T0)

          emitter.label("fib_sp_done")
          emitter.move(V0, T1)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_FiberYield"
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x84, T0) # current_fiber_idx
          emitter.bltz(T1, "fib_yield_ret")
          emitter.nop

          # Save fiber context: fiber entry at 0x70002000 + (idx * 32)
          emitter.sll(T2, T1, 5) # idx * 32
          emitter.ori(T3, T0, 0x2000)
          emitter.addu(T3, T3, T2)
          emitter.sw(RA, 12, T3) # save resume PC = RA
          emitter.sw(SP, 16, T3) # save SP
          emitter.sw(FP, 20, T3) # save FP

          # Restore scheduler context from 0x70000380
          emitter.lw(RA, 0x380, T0)
          emitter.lw(SP, 0x384, T0)
          emitter.lw(S0, 0x388, T0)
          emitter.lw(S1, 0x38C, T0)
          emitter.lw(S2, 0x390, T0)
          emitter.lw(FP, 0x394, T0)

          # Switch back to scheduler loop
          emitter.jump("step_fib_next")
          emitter.nop

          emitter.label("fib_yield_ret")
          emitter.jr(RA)
          emitter.nop
        when "Citrine_StepFibers"
          # Save scheduler context at 0x70000380
          emitter.lui(T0, 0x7000)
          emitter.sw(RA, 0x380, T0)
          emitter.sw(SP, 0x384, T0)
          emitter.sw(S0, 0x388, T0)
          emitter.sw(S1, 0x38C, T0)
          emitter.sw(S2, 0x390, T0)
          emitter.sw(FP, 0x394, T0)

          emitter.move(S0, ZERO) # loop index = 0

          emitter.label("step_fib_loop")
          emitter.lui(T0, 0x7000)
          emitter.lw(S1, 0x88, T0) # fiber_count
          emitter.sltu(T2, S0, S1)
          emitter.beqz(T2, "step_fib_done")
          emitter.nop

          # Check if fiber S0 is ready
          emitter.sll(T2, S0, 5) # S0 * 32
          emitter.ori(T3, T0, 0x2000)
          emitter.addu(T3, T3, T2)
          emitter.lw(T4, 8, T3) # state
          emitter.beqz(T4, "step_fib_next")
          emitter.nop

          # Mark current_fiber_idx = S0
          emitter.sw(S0, 0x84, T0)

          # Load fiber context
          emitter.lw(T9, 12, T3) # resume PC
          emitter.lw(SP, 16, T3) # fiber SP
          emitter.lw(FP, 20, T3) # fiber FP

          # Set up return address to exit trampoline if fiber terminates
          emitter.la(RA, "citrine_fiber_exit")

          # Jump to fiber resume PC
          emitter.jr(T9)
          emitter.nop

          # Label reached after fiber yields
          emitter.label("step_fib_next")
          emitter.lui(T0, 0x7000)
          emitter.lw(S0, 0x84, T0) # load current fiber idx
          emitter.addiu(S0, S0, 1) # advance to next fiber
          emitter.jump("step_fib_loop")
          emitter.nop

          emitter.label("step_fib_done")
          # Reset current_fiber_idx = -1
          emitter.lui(T0, 0x7000)
          emitter.li(T1, -1)
          emitter.sw(T1, 0x84, T0)

          # Restore scheduler context
          emitter.lw(RA, 0x380, T0)
          emitter.lw(SP, 0x384, T0)
          emitter.lw(S0, 0x388, T0)
          emitter.lw(S1, 0x38C, T0)
          emitter.lw(S2, 0x390, T0)
          emitter.lw(FP, 0x394, T0)
          emitter.jr(RA)
          emitter.nop

          # Exit handler for fibers that finish without yielding
          emitter.label("citrine_fiber_exit")
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x84, T0) # current_fiber_idx
          emitter.bltz(T1, "fib_exit_ret")
          emitter.nop

          emitter.sll(T2, T1, 5)
          emitter.ori(T3, T0, 0x2000)
          emitter.addu(T3, T3, T2)
          emitter.sw(ZERO, 8, T3) # state = 0 (done)

          # Restore scheduler context
          emitter.lw(RA, 0x380, T0)
          emitter.lw(SP, 0x384, T0)
          emitter.lw(S0, 0x388, T0)
          emitter.lw(S1, 0x38C, T0)
          emitter.lw(S2, 0x390, T0)
          emitter.lw(FP, 0x394, T0)
          emitter.jump("step_fib_next")
          emitter.nop

          emitter.label("fib_exit_ret")
          emitter.jr(RA)
          emitter.nop
        else
          return false
        end
        true
      end
    end
  end
end
