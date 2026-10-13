require "../mips_compiler"

module Citrine
  module ISO
    class MipsCompiler
      # Graphics native API call dispatch (Windows, 2D/3D drawing, textures)
      private def emit_graphics_native_call(dst : Int32, base : Int32, native_id : Int32, emitter : MipsEmitter) : Bool
        case native_id
        when 1 # InitWindow
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_InitWindow")
          emitter.sw(V0, (dst * 4), FP)
        when 2 # CloseWindow
          emitter.call("Citrine_CloseWindow")
          emitter.sw(V0, (dst * 4), FP)
        when 3                     # WindowOpen
          emitter.ori(V0, ZERO, 1) # Always open on PS2
          emitter.sw(V0, (dst * 4), FP)
        when 4 # SetTargetFPS
          emitter.ori(V0, ZERO, 60)
          emitter.sw(V0, (dst * 4), FP)
        when 5 # GetFPS
          emitter.ori(V0, ZERO, 60)
          emitter.sw(V0, (dst * 4), FP)
        when 6 # GetDeltaTime
          emitter.lui(V0, 0x3C88)
          emitter.ori(V0, V0, 0x8889)
          emitter.sw(V0, (dst * 4), FP)
        when 10 # BeginDrawing
          emitter.call("Citrine_BeginDrawing")
          emitter.sw(V0, (dst * 4), FP)
        when 11 # EndDrawing
          emitter.call("Citrine_EndDrawing")
          emitter.sw(V0, (dst * 4), FP)
        when 12 # ClearBackground
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ClearBackground")
          emitter.sw(V0, (dst * 4), FP)
        when 20 # DrawRectangle
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.lw(T0, ((base + 4) * 4), FP)
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawRectangle")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)
        when 21 # DrawCircle
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.call("Citrine_DrawCircle")
          emitter.sw(V0, (dst * 4), FP)
        when 22 # DrawLine
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.lw(T0, ((base + 4) * 4), FP)
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawLine")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)
        when 24 # DrawText
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.lw(A3, ((base + 3) * 4), FP)
          emitter.lw(T0, ((base + 4) * 4), FP)
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawText")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)
        when 30 # LoadTexture
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_LoadTexture")
          emitter.sw(V0, (dst * 4), FP)
        when 31 # DrawTexture
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.ori(A3, ZERO, 128)
          emitter.addiu(SP, SP, -32)
          emitter.ori(T0, ZERO, 128)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawTexture")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)
        when 32                                # DrawTextureRec
          emitter.lw(A0, (base * 4), FP)       # tex_id
          emitter.lw(A1, ((base + 5) * 4), FP) # dx
          emitter.lw(A2, ((base + 6) * 4), FP) # dy
          emitter.lw(A3, ((base + 3) * 4), FP) # dw
          emitter.lw(T0, ((base + 4) * 4), FP) # dh
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawTexture")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)
        when 33 # UnloadTexture
          emitter.sw(ZERO, (dst * 4), FP)
        when 237                               # DrawTexturePro
          emitter.lw(A0, (base * 4), FP)       # tex_id
          emitter.lw(A1, ((base + 5) * 4), FP) # dx
          emitter.lw(A2, ((base + 6) * 4), FP) # dy
          emitter.lw(A3, ((base + 7) * 4), FP) # dw
          emitter.lw(T0, ((base + 8) * 4), FP) # dh
          emitter.addiu(SP, SP, -32)
          emitter.sw(T0, 16, SP)
          emitter.call("Citrine_DrawTexture")
          emitter.addiu(SP, SP, 32)
          emitter.sw(V0, (dst * 4), FP)
        else
          return false
        end
        true
      end

      # Audio native API call dispatch (SPU2, CDDA, Streaming)
      private def emit_audio_native_call(dst : Int32, base : Int32, native_id : Int32, emitter : MipsEmitter) : Bool
        case native_id
        when 35 # LoadSound
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_LoadSound")
          emitter.sw(V0, (dst * 4), FP)
        when 36 # PlaySound
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_PlaySound")
          emitter.sw(V0, (dst * 4), FP)
        when 37 # StopSound
          emitter.call("Citrine_StopSound")
          emitter.sw(V0, (dst * 4), FP)
        when 220 # AudioPlayCDDA
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_PlaySound")
          emitter.sw(V0, (dst * 4), FP)
        when 221 # AudioStopCDDA
          emitter.call("Citrine_StopSound")
          emitter.sw(V0, (dst * 4), FP)
        when 222 # AudioGetCDDAStatus
          emitter.call("Citrine_GetCDDAStatus")
          emitter.sw(V0, (dst * 4), FP)
        when 223 # AudioSetVolume
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_SetVolume")
          emitter.sw(V0, (dst * 4), FP)
        when 224 # AudioSeekStream
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_AudioSeekStream")
          emitter.sw(V0, (dst * 4), FP)
        when 225 # AudioPauseStream
          emitter.call("Citrine_PauseStream")
          emitter.sw(V0, (dst * 4), FP)
        when 226 # AudioResumeStream
          emitter.call("Citrine_ResumeStream")
          emitter.sw(V0, (dst * 4), FP)
        else
          return false
        end
        true
      end

      # Input native API call dispatch (DualShock 2 Pad, Analog, Rumble, ActionMap)
      private def emit_input_native_call(dst : Int32, base : Int32, native_id : Int32, emitter : MipsEmitter) : Bool
        case native_id
        when 40 # ButtonDown
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ButtonDown")
          emitter.sw(V0, (dst * 4), FP)
        when 41 # ButtonPressed
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ButtonPressed")
          emitter.sw(V0, (dst * 4), FP)
        when 42 # ButtonReleased
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ButtonReleased")
          emitter.sw(V0, (dst * 4), FP)
        when 43 # GetAnalog(port, axis)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_GetAnalog")
          emitter.sw(V0, (dst * 4), FP)
        when 44 # SetRumble(port, small, large)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_SetRumble")
          emitter.sw(V0, (dst * 4), FP)
        when 45 # ActionPressed
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ActionPressed")
          emitter.sw(V0, (dst * 4), FP)
        when 46 # ActionDown
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ActionDown")
          emitter.sw(V0, (dst * 4), FP)
        when 47 # ActionReleased
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ActionReleased")
          emitter.sw(V0, (dst * 4), FP)
        when 48 # ActionRegister
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ActionRegister")
          emitter.sw(V0, (dst * 4), FP)
        when 246 # CdvdSeekEntropy
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_CdvdSeekEntropy")
          emitter.sw(V0, (dst * 4), FP)
        else
          return false
        end
        true
      end

      # Collections, Objects, Strings, and Pointer native API call dispatch
      private def emit_collections_and_objects_native_call(
        dst : Int32,
        base : Int32,
        native_id : Int32,
        emitter : MipsEmitter,
        fn_idx : Int32,
        pc : Int32,
      ) : Bool
        case native_id
        when 120 # ArrayNew(capacity)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArrayNew")
          emitter.sw(V0, (dst * 4), FP)
        when 121 # ArrayGet(arr, index)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ArrayGet")
          emitter.sw(V0, (dst * 4), FP)
        when 122 # ArraySet(arr, index, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ArraySet")
          emitter.sw(V0, (dst * 4), FP)
        when 123 # ArrayPush(arr, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ArrayPush")
          emitter.sw(V0, (dst * 4), FP)
        when 124 # ArrayPop(arr)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArrayPop")
          emitter.sw(V0, (dst * 4), FP)
        when 125 # ArraySize(arr_or_str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArraySize")
          emitter.sw(V0, (dst * 4), FP)
        when 126 # ArrayClear(arr)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArrayClear")
          emitter.sw(V0, (dst * 4), FP)
        when 130 # StaticArrayNew(size, def_val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StaticArrayNew")
          emitter.sw(V0, (dst * 4), FP)
        when 131 # StaticArrayGet(arr, index)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ArrayGet")
          emitter.sw(V0, (dst * 4), FP)
        when 132 # StaticArraySet(arr, index, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ArraySet")
          emitter.sw(V0, (dst * 4), FP)
        when 133 # StaticArraySize(arr)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ArraySize")
          emitter.sw(V0, (dst * 4), FP)
        when 150 # ObjectNew(class_id, field_count)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ObjectNew")
          emitter.sw(V0, (dst * 4), FP)
        when 151 # ObjectGetField(obj, field_idx)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_ObjectGetField")
          emitter.sw(V0, (dst * 4), FP)
        when 152 # ObjectSetField(obj, field_idx, val)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.lw(A2, ((base + 2) * 4), FP)
          emitter.call("Citrine_ObjectSetField")
          emitter.sw(V0, (dst * 4), FP)
        when 153 # StructCopy(src_obj)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StructCopy")
          emitter.sw(V0, (dst * 4), FP)
        when 160                         # PointerMalloc: dest = malloc(count * 4)
          emitter.lw(A0, (base * 4), FP) # element count
          emitter.sll(A0, A0, 2)         # bytes = count * 4
          emitter.lui(T0, 0x7000)
          # Free-list recycling check: check bucket at 0x700000B0
          emitter.lw(V0, 0xB0, T0)
          emitter.beqz(V0, "malloc_from_heap_#{fn_idx}_#{pc}")
          emitter.nop
          # Pop from free-list
          emitter.lw(T1, 0, V0)    # next = head->next
          emitter.sw(T1, 0xB0, T0) # head = next
          emitter.jump("malloc_done_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.label("malloc_from_heap_#{fn_idx}_#{pc}")
          emitter.lw(V0, 0x8C, T0) # current heap_ptr
          emitter.bnez(V0, "malloc_heap_ok_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.lui(V0, 0x0022) # default heap base 0x00220000
          emitter.label("malloc_heap_ok_#{fn_idx}_#{pc}")
          emitter.addiu(T1, A0, 15)
          emitter.andi(T1, T1, 0xFFF0) # 16-byte align
          emitter.addu(T2, V0, T1)
          # Heap Redzone Guard: ensure allocation does not cross 0x00400000
          emitter.lui(T3, 0x0040)
          emitter.sltu(T3, T2, T3)
          emitter.bnez(T3, "malloc_in_bounds_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.move(A0, ZERO)
          emitter.call("citrine_vm_panic")
          emitter.label("malloc_in_bounds_#{fn_idx}_#{pc}")
          emitter.sw(T2, 0x8C, T0) # store updated heap_ptr
          emitter.label("malloc_done_#{fn_idx}_#{pc}")
          emitter.move(T3, V0)
          emitter.addiu(T1, A0, 15)
          emitter.andi(T1, T1, 0xFFF0)
          emitter.label("malloc_zero_loop_#{fn_idx}_#{pc}")
          emitter.beqz(T1, "malloc_zero_done_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.sw(ZERO, 0, T3)
          emitter.addiu(T3, T3, 4)
          emitter.addiu(T1, T1, -4)
          emitter.jump("malloc_zero_loop_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.label("malloc_zero_done_#{fn_idx}_#{pc}")
          emitter.sw(V0, (dst * 4), FP)
        when 161                               # PointerGet: dest = *(ptr + idx * 4)
          emitter.lw(T0, (base * 4), FP)       # ptr
          emitter.lw(T1, ((base + 1) * 4), FP) # idx
          emitter.sll(T1, T1, 2)
          emitter.addu(T0, T0, T1) # address
          emitter.lw(V0, 0, T0)    # load word from address
          emitter.sw(V0, (dst * 4), FP)
        when 162                               # PointerSet: *(ptr + idx * 4) = val
          emitter.lw(T0, (base * 4), FP)       # ptr
          emitter.lw(T1, ((base + 1) * 4), FP) # idx
          emitter.lw(T2, ((base + 2) * 4), FP) # val
          emitter.sll(T1, T1, 2)
          emitter.addu(T0, T0, T1)
          # Memory Safety Guard: prevent writes to NULL (0) and read-only code space (< 0x00200000)
          emitter.lui(T3, 0x0020)
          emitter.sltu(T3, T0, T3)
          emitter.bnez(T3, "ptr_set_guard_skip_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.sw(T2, 0, T0) # store word safely
          emitter.label("ptr_set_guard_skip_#{fn_idx}_#{pc}")
          emitter.sw(T2, (dst * 4), FP)
        when 163                               # PointerOffset: dest = ptr + idx * 4
          emitter.lw(T0, (base * 4), FP)       # ptr
          emitter.lw(T1, ((base + 1) * 4), FP) # idx
          emitter.sll(T1, T1, 2)
          emitter.addu(V0, T0, T1)
          emitter.sw(V0, (dst * 4), FP)
        when 164, 165 # PointerAddress, PointerNew
          emitter.lw(T0, (base * 4), FP)
          emitter.sw(T0, (dst * 4), FP)
        when 166 # BoxNew
          emitter.lui(T0, 0x7000)
          emitter.lw(V0, 0x8C, T0)
          emitter.bnez(V0, "box_heap_ok_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.lui(V0, 0x0022)
          emitter.label("box_heap_ok_#{fn_idx}_#{pc}")
          emitter.addiu(T1, V0, 16)
          emitter.sw(T1, 0x8C, T0)
          emitter.lw(T2, (base * 4), FP)
          emitter.sw(T2, 0, V0)
          emitter.sw(V0, (dst * 4), FP)
        when 167 # BoxUnbox
          emitter.lw(T0, (base * 4), FP)
          emitter.lw(V0, 0, T0)
          emitter.sw(V0, (dst * 4), FP)
        when 168                         # PointerFree
          emitter.lw(T0, (base * 4), FP) # ptr to free
          # Free-list recycling: if valid pointer >= 0x00200000, link into SPRAM 0x700000B0
          emitter.lui(T1, 0x0020)
          emitter.sltu(T2, T0, T1)
          emitter.bnez(T2, "ptr_free_done_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.lui(T1, 0x7000)
          emitter.lw(T2, 0xB0, T1) # current free-list head
          emitter.sw(T2, 0, T0)    # ptr->next = current_head
          emitter.sw(T0, 0xB0, T1) # free-list head = ptr
          emitter.label("ptr_free_done_#{fn_idx}_#{pc}")
          emitter.sw(ZERO, (dst * 4), FP)
        when 186 # StringStrip(str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StringStrip")
          emitter.sw(V0, (dst * 4), FP)
        when 187 # StringDowncase(str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StringDowncase")
          emitter.sw(V0, (dst * 4), FP)
        when 188 # StringUpcase(str)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_StringUpcase")
          emitter.sw(V0, (dst * 4), FP)
        when 189 # StringIncludes(str, needle)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringIncludes")
          emitter.sw(V0, (dst * 4), FP)
        when 192 # StringStartsWith(str, prefix)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringStartsWith")
          emitter.sw(V0, (dst * 4), FP)
        when 193 # StringEndsWith(str, suffix)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringEndsWith")
          emitter.sw(V0, (dst * 4), FP)
        when 195 # StringConcat(s1, s2)
          emitter.lw(A0, (base * 4), FP)
          emitter.lw(A1, ((base + 1) * 4), FP)
          emitter.call("Citrine_StringConcat")
          emitter.sw(V0, (dst * 4), FP)
        when 196 # ToString(int_val)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("Citrine_ToString")
          emitter.sw(V0, (dst * 4), FP)
        else
          return false
        end
        true
      end

      # System, Lifecycle, and Debug native API call dispatch
      private def emit_system_native_call(
        dst : Int32,
        base : Int32,
        native_id : Int32,
        emitter : MipsEmitter,
        fn_idx : Int32,
        pc : Int32,
      ) : Bool
        case native_id
        when 65 # Sleep(frames)
          emitter.lw(T4, (base * 4), FP)
          emitter.bgtz(T4, "sleep_start_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.ori(T4, ZERO, 1)
          emitter.label("sleep_start_#{fn_idx}_#{pc}")
          emitter.label("sleep_loop_#{fn_idx}_#{pc}")
          emitter.vsync_wait("slp_#{fn_idx}_#{pc}")
          emitter.addiu(T4, T4, -1)
          emitter.bgtz(T4, "sleep_loop_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.sw(ZERO, (dst * 4), FP)
        when 70, 71 # Print, DebugLog
          emitter.lw(A0, (base * 4), FP)
          emitter.call("debug_puts")
          emitter.sw(V0, (dst * 4), FP)
        when 99 # Panic(msg)
          emitter.lw(A0, (base * 4), FP)
          emitter.call("citrine_vm_panic")
        when 180 # ContextSet
          # Snapshot current heap_ptr (0x7000008C) into 0x70000098 (context_heap_base)
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x8C, T0)
          emitter.sw(T1, 0x98, T0)
          emitter.ori(V0, ZERO, 1)
          emitter.sw(V0, (dst * 4), FP)
        when 181 # ContextClear
          # Restore heap_ptr (0x7000008C) from 0x70000098 (context_heap_base)
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x98, T0)
          emitter.bnez(T1, "ctx_clear_restore_#{fn_idx}_#{pc}")
          emitter.nop
          emitter.lui(T1, 0x0022) # fallback default base if not set
          emitter.label("ctx_clear_restore_#{fn_idx}_#{pc}")
          emitter.sw(T1, 0x8C, T0)
          # Reset free-list head at 0x700000B0
          emitter.sw(ZERO, 0xB0, T0)
          emitter.ori(V0, ZERO, 1)
          emitter.sw(V0, (dst * 4), FP)
        when 182 # MemoryStats
          # Return active heap bytes (current heap_ptr - base 0x00220000)
          emitter.lui(T0, 0x7000)
          emitter.lw(T1, 0x8C, T0)
          emitter.lui(T2, 0x0022)
          emitter.subu(V0, T1, T2)
          emitter.sw(V0, (dst * 4), FP)
        when 185 # GCCycle
          emitter.move(V0, ZERO)
          emitter.sw(V0, (dst * 4), FP)
        when 170                               # TypeIsA
          emitter.lw(T0, (base * 4), FP)       # obj_reg
          emitter.lw(T1, ((base + 1) * 4), FP) # target_type_id
          emitter.ori(T2, ZERO, 0xF001)        # TypeKind::Nil
          type_is_nil_lbl = "type_is_nil_#{fn_idx}_#{pc}"
          type_check_done = "type_check_done_#{fn_idx}_#{pc}"
          emitter.beq(T1, T2, type_is_nil_lbl)
          emitter.nop

          emitter.sltu(V0, ZERO, T0)
          emitter.jump(type_check_done)
          emitter.nop

          emitter.label(type_is_nil_lbl)
          emitter.sltu(V0, ZERO, T0)
          emitter.xori(V0, V0, 1)

          emitter.label(type_check_done)
          emitter.sw(V0, (dst * 4), FP)
        when 171 # TypeAsCast
          emitter.lw(T0, (base * 4), FP)
          emitter.sw(T0, (dst * 4), FP)
        when 245 # CpuCycleCount: mfc0 $v0, $9
          emitter.emit((0x10_u32 << 26) | (2_u32 << 16) | (9_u32 << 11))
          emitter.sw(V0, (dst * 4), FP)
        else
          return false
        end
        true
      end
    end
  end
end
