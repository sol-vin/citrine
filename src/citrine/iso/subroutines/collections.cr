module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_collections_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?) : Bool
        case sname
        when "Citrine_ArrayNew" # A0 = capacity
          emitter.ori(T1, ZERO, 64)
          emitter.sltu(T2, A0, T1)
          emitter.beqz(T2, "arr_cap_ok")
          emitter.nop
          emitter.move(A0, T1)
          emitter.label("arr_cap_ok")
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 0x8C, T0)
          emitter.bnez(V0, "arr_heap_ok")
          emitter.nop
          emitter.lui(V0, 0x0022)
          emitter.label("arr_heap_ok")
          emitter.sll(T1, A0, 2)   # cap * 4
          emitter.addiu(T1, T1, 8) # +8 for size & cap
          emitter.addiu(T1, T1, 15)
          emitter.andi(T1, T1, 0xFFF0)
          emitter.addu(T2, V0, T1)
          emitter.sw(T2, 0x8C, T0)
          emitter.sw(ZERO, 0, V0) # size = 0
          emitter.sw(A0, 4, V0)   # capacity = A0
          emitter.jr(RA)
          emitter.nop
        when "Citrine_StaticArrayNew" # A0 = size, A1 = def_val
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 0x8C, T0)
          emitter.bnez(V0, "sarr_heap_ok")
          emitter.nop
          emitter.lui(V0, 0x0022)
          emitter.label("sarr_heap_ok")
          emitter.sll(T1, A0, 2)   # size * 4
          emitter.addiu(T1, T1, 8) # +8 for size & cap
          emitter.addiu(T1, T1, 15)
          emitter.andi(T1, T1, 0xFFF0)
          emitter.addu(T2, V0, T1)
          emitter.sw(T2, 0x8C, T0)
          emitter.sw(A0, 0, V0) # size = A0
          emitter.sw(A0, 4, V0) # capacity = A0
          emitter.move(T3, ZERO)
          emitter.label("sarr_fill_loop")
          emitter.sltu(T4, T3, A0)
          emitter.beqz(T4, "sarr_fill_done")
          emitter.nop
          emitter.sll(T5, T3, 2)
          emitter.addu(T5, V0, T5)
          emitter.sw(A1, 8, T5)
          emitter.addiu(T3, T3, 1)
          emitter.j("sarr_fill_loop")
          emitter.nop
          emitter.label("sarr_fill_done")
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ArrayPush" # A0 = arr_ptr, A1 = val
          emitter.bnez(A0, "arr_push_ok")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_push_ok")
          emitter.lw(T0, 0, A0)             # size
          emitter.lw(T2, 4, A0)             # capacity
          emitter.sltu(T3, T0, T2)          # size < capacity
          emitter.beqz(T3, "arr_push_done") # prevent buffer overrun
          emitter.nop
          emitter.sll(T1, T0, 2) # size * 4
          emitter.addu(T1, A0, T1)
          emitter.sw(A1, 8, T1) # arr[8 + size * 4] = val
          emitter.addiu(T0, T0, 1)
          emitter.sw(T0, 0, A0) # size++
          emitter.label("arr_push_done")
          emitter.move(V0, A0)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ArrayPop" # A0 = arr_ptr
          emitter.bnez(A0, "arr_pop_ok")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_pop_ok")
          emitter.lw(T0, 0, A0) # size
          emitter.bnez(T0, "arr_pop_has_items")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_pop_has_items")
          emitter.addiu(T0, T0, -1)
          emitter.sw(T0, 0, A0)  # size--
          emitter.sll(T1, T0, 2) # new_size * 4
          emitter.addu(T1, A0, T1)
          emitter.lw(V0, 8, T1) # popped val = arr[8 + new_size * 4]
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ArrayClear" # A0 = arr_ptr
          emitter.beqz(A0, "arr_clr_ret")
          emitter.nop
          emitter.sw(ZERO, 0, A0) # size = 0
          emitter.label("arr_clr_ret")
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ArrayGet" # A0 = arr_ptr, A1 = index
          emitter.bnez(A0, "arr_get_ok")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_get_ok")
          emitter.lw(T1, 0, A0) # size
          emitter.bgez(A1, "arr_get_check_bounds")
          emitter.nop
          emitter.addu(A1, A1, T1) # negative index: A1 += size
          emitter.label("arr_get_check_bounds")
          emitter.sltu(T2, A1, T1)
          emitter.bnez(T2, "arr_get_in_bounds")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_get_in_bounds")
          emitter.sll(T0, A1, 2)
          emitter.addu(T0, A0, T0)
          emitter.lw(V0, 8, T0)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ArraySet" # A0 = arr_ptr, A1 = index, A2 = val
          emitter.bnez(A0, "arr_set_ok")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_set_ok")
          emitter.lw(T1, 0, A0) # size
          emitter.bgez(A1, "arr_set_check_cap")
          emitter.nop
          emitter.addu(A1, A1, T1) # negative index: A1 += size
          emitter.label("arr_set_check_cap")
          emitter.bltz(A1, "arr_set_done")
          emitter.nop
          emitter.lw(T2, 4, A0) # capacity
          emitter.sltu(T3, A1, T2)
          emitter.beqz(T3, "arr_set_done")
          emitter.nop
          emitter.sltu(T3, A1, T1) # A1 < size?
          emitter.bnez(T3, "arr_set_store")
          emitter.nop
          emitter.addiu(T1, A1, 1)
          emitter.sw(T1, 0, A0)
          emitter.label("arr_set_store")
          emitter.sll(T0, A1, 2)
          emitter.addu(T0, A0, T0)
          emitter.sw(A2, 8, T0)
          emitter.label("arr_set_done")
          emitter.move(V0, A2)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ArraySize" # A0 = arr_or_str
          emitter.bnez(A0, "arr_sz_non_zero")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_sz_non_zero")
          # Check if string pointer: in .rodata or dynamic string arena (>= 0x00500000) or ToString buffer (0x70003200..0x70003300)
          emitter.lui(T0, 0x0050)
          emitter.sltu(T1, A0, T0)
          emitter.beqz(T1, "arr_sz_strlen")
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.ori(T0, T0, 0x3200)
          emitter.subu(T1, A0, T0)
          emitter.sltiu(T1, T1, 0x100)
          emitter.bnez(T1, "arr_sz_strlen")
          emitter.nop
          # Array: size is at 0(A0)
          emitter.lw(V0, 0, A0)
          emitter.jr(RA)
          emitter.nop
          emitter.label("arr_sz_strlen")
          emitter.move(T0, A0)
          emitter.move(V0, ZERO)
          emitter.label("arr_sz_str_loop")
          emitter.lbu(T1, 0, T0)
          emitter.beqz(T1, "arr_sz_str_done")
          emitter.nop
          emitter.addiu(V0, V0, 1)
          emitter.addiu(T0, T0, 1)
          emitter.jump("arr_sz_str_loop")
          emitter.nop
          emitter.label("arr_sz_str_done")
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
