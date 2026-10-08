module Citrine
  module ISO
    class RuntimeSubroutines
      def self.emit_objects_stub(sname : String, emitter : MipsEmitter, profile : ProgramProfile?) : Bool
        case sname
        when "citrine_vm_panic"
          emitter.bnez(A0, "panic_has_msg")
          emitter.nop
          emitter.lui(A0, 0x0050)
          emitter.label("panic_has_msg")
          emitter.call("debug_puts")
          emitter.label("panic_halt")
          emitter.jump("panic_halt")
        when "Citrine_ObjectNew" # A0 = class_id, A1 = field_count
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 0x8C, T0) # current heap_ptr
          emitter.bnez(V0, "obj_heap_ok")
          emitter.nop
          emitter.lui(V0, 0x0022) # init heap at 0x00220000
          emitter.label("obj_heap_ok")
          emitter.sll(T1, A1, 2) # field_count * 4
          emitter.addiu(T1, T1, 15)
          emitter.andi(T1, T1, 0xFFF0) # 16-byte align
          emitter.addu(T2, V0, T1)
          emitter.sw(T2, 0x8C, T0) # store updated heap_ptr
          # zero allocated memory
          emitter.move(T3, V0)
          emitter.label("obj_zero_loop")
          emitter.beqz(T1, "obj_zero_done")
          emitter.nop
          emitter.sw(ZERO, 0, T3)
          emitter.addiu(T3, T3, 4)
          emitter.addiu(T1, T1, -4)
          emitter.jump("obj_zero_loop")
          emitter.nop
          emitter.label("obj_zero_done")
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ObjectGetField" # A0 = obj_ptr, A1 = field_idx
          emitter.lui(T1, 0x0010)
          emitter.sltu(T1, A0, T1)
          emitter.beqz(T1, "obj_get_ok")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("obj_get_ok")
          emitter.sll(T0, A1, 2)
          emitter.addu(T0, A0, T0)
          emitter.lw(V0, 0, T0)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_ObjectSetField" # A0 = obj_ptr, A1 = field_idx, A2 = val
          emitter.lui(T1, 0x0010)
          emitter.sltu(T1, A0, T1)
          emitter.beqz(T1, "obj_set_ok")
          emitter.nop
          emitter.move(V0, ZERO)
          emitter.jr(RA)
          emitter.nop
          emitter.label("obj_set_ok")
          emitter.sll(T0, A1, 2)
          emitter.addu(T0, A0, T0)
          emitter.sw(A2, 0, T0)
          emitter.move(V0, A2)
          emitter.jr(RA)
          emitter.nop
        when "Citrine_StructCopy" # A0 = src_obj
          emitter.beqz(A0, "struct_copy_null")
          emitter.nop
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 0x8C, T0)
          emitter.bnez(V0, "struct_heap_ok")
          emitter.nop
          emitter.lui(V0, 0x0022)
          emitter.label("struct_heap_ok")
          emitter.addiu(T1, V0, 32)
          emitter.sw(T1, 0x8C, T0)
          8.times do |i|
            emitter.lw(T1, i * 4, A0)
            emitter.sw(T1, i * 4, V0)
          end
          emitter.jr(RA)
          emitter.nop
          emitter.label("struct_copy_null")
          emitter.move(V0, ZERO)
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
