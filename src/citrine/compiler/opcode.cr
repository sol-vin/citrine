module Citrine
  # Citrine-32 Virtual Machine Instruction Opcodes.
  #
  # Redesigned ISA compressing all VM semantics into exactly 32 primary opcodes
  # (0x00 through 0x1F, 5-bit opcode field in bits [31:27]), with 3-bit sub-opcodes
  # in bits [26:24] providing 256 unique instruction permutations.
  #
  # ## Instruction Categories
  # - System & Flow: Sys (0x00), Move (0x01), Jump (0x0F), BranchZ (0x10), BranchCmp (0x11), Call (0x12), Return (0x13), LoopDecBr (0x1E)
  # - Immediate & Memory: LoadConst (0x02), LoadImm (0x03), LoadMem (0x04), StoreMem (0x05)
  # - Arithmetic & Logic: Add (0x06), Sub (0x07), Mul (0x08), DivMod (0x09), Bitwise (0x0A), Shift (0x0B), FloatAlu (0x0E), FusedMadd (0x1F)
  # - Inspection & Comparison: Compare (0x0C), Test (0x0D)
  # - PS2 Acceleration: Vec2Math (0x15), Vec2Prop (0x16), ColorOp (0x17), SimdMmi (0x18), Collection (0x19), Ps2Hw (0x1C), InlineAsm (0x1D)
  # - Concurrency: FiberOp (0x1A), ChannelOp (0x1B), CallNative (0x14)
  enum Opcode : UInt8
    # 0x00: System control, VM termination, hardware barriers, debug hooks
    Sys         = 0x00
    # 0x01: Register copy, wide SIMD transfer, and conditional moves
    Move        = 0x01
    # 0x02: Load pre-compiled constant from .cbc constant pool at index imm16
    LoadConst   = 0x02
    # 0x03: Immediate literal load into register
    LoadImm     = 0x03
    # 0x04: Memory read: R[dst] = Memory[R[base] + R[offset]]
    LoadMem     = 0x04
    # 0x05: Memory write: Memory[R[base] + R[offset]] = R[src]
    StoreMem    = 0x05
    # 0x06: 32-bit integer arithmetic and fast-path string concatenation
    Add         = 0x06
    # 0x07: 32-bit integer subtraction and two's complement negation
    Sub         = 0x07
    # 0x08: Integer multiplication with LO/HI hardware register harvesting
    Mul         = 0x08
    # 0x09: Guarded division and modulo
    DivMod      = 0x09
    # 0x0A: Bitwise logical operations
    Bitwise     = 0x0A
    # 0x0B: Variable and immediate bit shifts, rotations, and leading-zero detection
    Shift       = 0x0B
    # 0x0C: Relational condition evaluation; writes boolean result (1 or 0) to R[dst]
    Compare     = 0x0C
    # 0x0D: Fast unary register inspection and polymorphic type checking
    Test        = 0x0D
    # 0x0E: Single-precision IEEE-754 floating point arithmetic via Emotion Engine COP1
    FloatAlu    = 0x0E
    # 0x0F: Unconditional relative branches, function pointers, and switch-statement jump tables
    Jump        = 0x0F
    # 0x10: Single-register conditional branch with signed 16-bit offset
    BranchZ     = 0x10
    # 0x11: Fused comparison and branch (BEQ, BNE, BLT, BLE, BGT, BGE)
    BranchCmp   = 0x11
    # 0x12: Function invocation, dynamic dispatch, and zero-stack-growth tail calls
    Call        = 0x12
    # 0x13: Returns execution to caller, restoring SPRAM frame register pointers
    Return      = 0x13
    # 0x14: High-speed native service trampoline partitioned into 8 hardware domains
    CallNative  = 0x14
    # 0x15: 2D vector geometry construction and component-wise vector algebra
    Vec2Math    = 0x15
    # 0x16: 2D vector component access, mutation, magnitude, and linear interpolation
    Vec2Prop    = 0x16
    # 0x17: PS2 Graphics Synthesizer pixel formats and vertex color blending
    ColorOp     = 0x17
    # 0x18: Emotion Engine 128-bit Multimedia Extensions (MMI)
    SimdMmi     = 0x18
    # 0x19: Polymorphic dynamic/static array indexing and object instance property access
    Collection  = 0x19
    # 0x1A: Lightweight coroutine lifecycle and cooperative multitasking scheduler
    FiberOp     = 0x1A
    # 0x1B: Communicating Sequential Processes (CSP) message-passing channels
    ChannelOp   = 0x1B
    # 0x1C: Direct PS2 hardware DMA channel control and GS framebuffer management
    Ps2Hw       = 0x1C
    # 0x1D: Low-level privileged coprocessor access, VU0 microcode, and CPU performance audit
    InlineAsm   = 0x1D
    # 0x1E: Fused loop decrement/increment and branch accelerator
    LoopDecBr   = 0x1E
    # 0x1F: Fused Multiply-Accumulate and 2D vector dot product accelerator
    FusedMadd   = 0x1F
  end

  # Legacy Distinct Opcode Specifiers for Compiler (0x20..0x3F)
  enum LegacyOpcode : UInt8
    Nop         = 0x20
    Halt        = 0x21
    LoadNil     = 0x22
    LoadBool    = 0x23
    LoadInt     = 0x24
    Neg         = 0x25
    Div         = 0x26
    Mod         = 0x27
    BitAnd      = 0x28
    BitOr       = 0x29
    BitXor      = 0x2A
    BitNot      = 0x2B
    ShiftLeft   = 0x2C
    ShiftRight  = 0x2D
    Eq          = 0x2E
    Ne          = 0x2F
    Lt          = 0x30
    Le          = 0x31
    Gt          = 0x32
    Ge          = 0x33
    JumpIfTrue  = 0x34
    JumpIfFalse = 0x35
    Vec2New     = 0x36
    Vec2Add     = 0x37
    Vec2GetX    = 0x38
    Vec2GetY    = 0x39
    Vec2SetX    = 0x3A
    Vec2SetY    = 0x3B
    ColorNew    = 0x3C
    SpawnFiber  = 0x3D
    Yield       = 0x3E
    ResumeFiber = 0x3F
  end

  # Sub-opcode definitions for all 32 primary opcodes (3 bits each: 0..7)
  enum SysSubOp : UInt8
    Nop           = 0
    Halt          = 1
    Break         = 2
    Sync          = 3
    FlushICache   = 4
    FlushDCache   = 5
    WatchdogReset = 6
    ProfileMark   = 7
  end

  enum MoveSubOp : UInt8
    Move32  = 0
    Move64  = 1
    Move128 = 2
    Cmovz   = 3
    Cmovn   = 4
    Swap    = 5
  end

  enum LoadConstSubOp : UInt8
    String   = 0
    Float32  = 1
    Symbol   = 2
    Int64    = 3
    Vec2     = 4
    Color    = 5
    Blob     = 6
    ClassRef = 7
  end

  enum LoadImmSubOp : UInt8
    Nil      = 0
    Bool     = 1
    Int16    = 2
    UInt16   = 3
    Upper16  = 4
    Zero     = 5
    MinusOne = 6
  end

  enum MemSubOp : UInt8
    LB       = 0
    LBU      = 1
    LH       = 2
    LHU      = 3
    LW       = 4
    LWC1     = 5
    LD       = 6
    LQ       = 7
    SB       = 0
    SH       = 1
    SW       = 2
    SWC1     = 3
    SD       = 4
    SQ       = 5
    SwSpram  = 6
    SqSpram  = 7
  end

  enum AddSubOp : UInt8
    AddI32  = 0
    AdduI32 = 1
    AddSat  = 2
    AddStr  = 3
    AddImm8 = 4
  end

  enum SubSubOp : UInt8
    SubI32  = 0
    SubuI32 = 1
    SubSat  = 2
    NegI32  = 3
    SubImm8 = 4
  end

  enum MulSubOp : UInt8
    MulLo   = 0
    MulHi   = 1
    MuluHi  = 2
    MulSat  = 3
    MulImm8 = 4
  end

  enum DivModSubOp : UInt8
    DivS32 = 0
    ModS32 = 1
    DivU32 = 2
    ModU32 = 3
  end

  enum BitwiseSubOp : UInt8
    And    = 0
    Or     = 1
    Xor    = 2
    Nor    = 3
    AndNot = 4
    Xnor   = 5
  end

  enum ShiftSubOp : UInt8
    Sll  = 0
    Srl  = 1
    Sra  = 2
    Rotl = 3
    Rotr = 4
    Clz  = 5
  end

  enum CompareSubOp : UInt8
    Eq    = 0
    Ne    = 1
    Lt    = 2
    Le    = 3
    Gt    = 4
    Ge    = 5
    StrEq = 6
    PtrEq = 7
  end

  enum TestSubOp : UInt8
    IsNil     = 0
    IsNotNil  = 1
    IsZero    = 2
    IsNotZero = 3
    IsTruthy  = 4
    IsFalsy   = 5
    CheckTag  = 6
    TestBit   = 7
  end

  enum FloatAluSubOp : UInt8
    Fadd   = 0
    Fsub   = 1
    Fmul   = 2
    Fdiv   = 3
    Fneg   = 4
    Fabs   = 5
    Fsqrt  = 6
    FcvtSW = 7
  end

  enum JumpSubOp : UInt8
    JumpRel24 = 0
    JumpRel16 = 1
    JumpReg   = 2
    JumpTable = 3
  end

  enum BranchZSubOp : UInt8
    Truthy  = 0
    Falsy   = 1
    Zero    = 2
    Nonzero = 3
    Pos     = 4
    Neg     = 5
  end

  enum BranchCmpSubOp : UInt8
    Beq = 0
    Bne = 1
    Blt = 2
    Ble = 3
    Bgt = 4
    Bge = 5
  end

  enum CallSubOp : UInt8
    Direct           = 0
    Indirect         = 1
    TailcallDirect   = 2
    TailcallIndirect = 3
  end

  enum ReturnSubOp : UInt8
    Val   = 0
    Nil   = 1
    Void  = 2
    Multi = 3
  end

  enum CallNativeSubOp : UInt8
    SysKernel    = 0
    SysGsDraw    = 1
    SysSpu2Audio = 2
    SysPadInput  = 3
    SysVideoPlay = 4
    SysHud       = 5
    SysIoFs      = 6
    SysUserC     = 7
  end

  enum Vec2MathSubOp : UInt8
    New   = 0
    Add   = 1
    Sub   = 2
    Mul   = 3
    Div   = 4
    Scale = 5
    Dot   = 6
    Cross = 7
  end

  enum Vec2PropSubOp : UInt8
    GetX      = 0
    GetY      = 1
    SetX      = 2
    SetY      = 3
    Len       = 4
    LenSq     = 5
    Normalize = 6
    Lerp      = 7
  end

  enum ColorSubOp : UInt8
    Rgba32   = 0
    Rgba16   = 1
    Unpack   = 2
    Lerp     = 3
    Modulate = 4
    Premul   = 5
  end

  enum SimdMmiSubOp : UInt8
    Paddb  = 0
    Paddw  = 1
    Psubw  = 2
    Pmulth = 3
    Pmaxw  = 4
    Pminw  = 5
    Pextw  = 6
    Ppacw  = 7
  end

  enum CollectionSubOp : UInt8
    ArrayGet  = 0
    ArraySet  = 1
    ArrayLen  = 2
    ArrayPush = 3
    ArrayPop  = 4
    FieldGet  = 5
    FieldSet  = 6
    HashGet   = 7
  end

  enum FiberSubOp : UInt8
    Spawn  = 0
    Yield  = 1
    Resume = 2
    Status = 3
    Kill   = 4
    Id     = 5
    Sleep  = 6
  end

  enum ChannelSubOp : UInt8
    Create   = 0
    Send     = 1
    Recv     = 2
    TryRecv  = 3
    Count    = 4
    Capacity = 5
    Close    = 6
  end

  enum Ps2HwSubOp : UInt8
    DmaSendGif    = 0
    DmaSendVif1   = 1
    DmaWait       = 2
    GsSyncVblank  = 3
    GsSwapBuffers = 4
    Spu2KeyOn     = 5
    PadRead       = 6
  end

  enum InlineAsmSubOp : UInt8
    Cop0Mfc0       = 0
    Cop0Mtc0       = 1
    Cop2Vu0Macro   = 2
    SpramFastPtr   = 3
    PerfCountStart = 4
    PerfCountStop  = 5
  end

  enum LoopDecBrSubOp : UInt8
    DecBrNz  = 0
    DecBrGez = 1
    IncBrLt  = 2
  end

  enum FusedMaddSubOp : UInt8
    MaddI32        = 0
    MsubI32        = 1
    MaddF32        = 2
    MsubF32        = 3
    DotProductVec2 = 4
  end

  # Fixed-width 32-bit Little-Endian Citrine-32 VM instruction word.
  #
  # Bitfield Layout:
  # - [31:27] Opcode (5 bits, 0x00..0x1F)
  # - [26:24] SubOp  (3 bits, 0..7)
  # - [23:16] Dst / RegA / CondReg (8 bits)
  # - [15:8]  RegA / RegB (8 bits)
  # - [7:0]   RegB / Offset8 (8 bits)
  # - [15:0]  Immediate / Branch Offset (16 bits)
  # - [23:0]  Unconditional Jump Offset (24 bits)
  struct Instruction
    getter raw : UInt32

    def initialize(@raw : UInt32)
    end

    # Encodes a 3-register RRR format instruction with primary opcode and sub-opcode.
    def self.encode_rrr(op : Opcode, subop : UInt8, dst : UInt8, a : UInt8, b : UInt8) : Instruction
      val = (op.value.to_u32 << 27) | ((subop.to_u32 & 0x07_u32) << 24) | (dst.to_u32 << 16) | (a.to_u32 << 8) | b.to_u32
      new(val)
    end

    # Encodes an immediate R_IMM format instruction.
    def self.encode_r_imm(op : Opcode, subop : UInt8, dst : UInt8, imm : UInt16) : Instruction
      val = (op.value.to_u32 << 27) | ((subop.to_u32 & 0x07_u32) << 24) | (dst.to_u32 << 16) | imm.to_u32
      new(val)
    end

    # Encodes a relative conditional branch BRANCH_REL format instruction.
    def self.encode_branch_rel(op : Opcode, subop : UInt8, reg : UInt8, offset : Int16) : Instruction
      u_offset = (offset.to_i32 & 0xFFFF).to_u16
      val = (op.value.to_u32 << 27) | ((subop.to_u32 & 0x07_u32) << 24) | (reg.to_u32 << 16) | u_offset.to_u32
      new(val)
    end

    # Encodes an unconditional jump with 24-bit relative signed reach (covering full 32MB PS2 memory).
    def self.encode_jump_rel24(offset : Int32) : Instruction
      u_offset = (offset & 0xFFFFFF).to_u32
      val = (Opcode::Jump.value.to_u32 << 27) | ((JumpSubOp::JumpRel24.value.to_u32 & 0x07_u32) << 24) | u_offset
      new(val)
    end

    # Encodes a fused compare-and-branch instruction (BRANCH_FUSED format).
    def self.encode_branch_cmp(cmp_op : BranchCmpSubOp | UInt8, a : UInt8, b : UInt8, offset : Int8) : Instruction
      subop = cmp_op.is_a?(BranchCmpSubOp) ? cmp_op.value : cmp_op
      u_offset = (offset.to_i32 & 0xFF).to_u32
      val = (Opcode::BranchCmp.value.to_u32 << 27) | ((subop.to_u32 & 0x07_u32) << 24) | (a.to_u32 << 16) | (b.to_u32 << 8) | u_offset
      new(val)
    end

    # Encodes a fused loop decrement/increment and branch instruction (BRANCH_DEC format).
    def self.encode_loop_dec_br(mode : LoopDecBrSubOp | UInt8, reg : UInt8, offset : Int16, limit_reg : UInt8 = 0_u8) : Instruction
      subop = mode.is_a?(LoopDecBrSubOp) ? mode.value : mode
      u_offset = (offset.to_i32 & 0xFFFF).to_u16
      val = (Opcode::LoopDecBr.value.to_u32 << 27) | ((subop.to_u32 & 0x07_u32) << 24) | (reg.to_u32 << 16) | u_offset
      new(val)
    end

    # Encodes a fused multiply-accumulate or vector dot product instruction (RRR_FUSED format).
    def self.encode_fused_madd(type : FusedMaddSubOp | UInt8, dst : UInt8, a : UInt8, b : UInt8) : Instruction
      subop = type.is_a?(FusedMaddSubOp) ? type.value : type
      val = (Opcode::FusedMadd.value.to_u32 << 27) | ((subop.to_u32 & 0x07_u32) << 24) | (dst.to_u32 << 16) | (a.to_u32 << 8) | b.to_u32
      new(val)
    end

    # Encodes a LoadNil instruction (R_IMM format with SubOp LoadImmSubOp::Nil)
    def self.encode_load_nil(dest : UInt8) : Instruction
      encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Nil.value, dest, 0_u16)
    end

    # Encodes a LoadBool instruction (R_IMM format with SubOp LoadImmSubOp::Bool)
    def self.encode_load_bool(dest : UInt8, val : Bool | UInt16 | Int32) : Instruction
      b_val = val.is_a?(Bool) ? val : (val != 0)
      encode_r_imm(Opcode::LoadImm, LoadImmSubOp::Bool.value, dest, b_val ? 1_u16 : 0_u16)
    end

    # Encodes a LoadInt instruction (R_IMM format with SubOp LoadImmSubOp::Int16 or UInt16)
    def self.encode_load_int(dest : UInt8, val : Int) : Instruction
      subop = if val >= 0 && val > 0x7FFF && val <= 0xFFFF
                LoadImmSubOp::UInt16.value
              else
                LoadImmSubOp::Int16.value
              end
      encode_r_imm(Opcode::LoadImm, subop, dest, (val.to_i64 & 0xFFFF).to_u16)
    end

    # Encodes a LoadUInt instruction (R_IMM format with SubOp LoadImmSubOp::UInt16)
    def self.encode_load_uint(dest : UInt8, val : Int) : Instruction
      encode_r_imm(Opcode::LoadImm, LoadImmSubOp::UInt16.value, dest, (val.to_i64 & 0xFFFF).to_u16)
    end

    # Encodes a Compare instruction (RRR format with SubOp CompareSubOp)
    def self.encode_cmp(cmp_op : CompareSubOp, dest : UInt8, a : UInt8, b : UInt8) : Instruction
      encode_rrr(Opcode::Compare, cmp_op.value, dest, a, b)
    end

    # Encodes a Vec2 constructor (RRR format)
    def self.encode_vec2_new(dest : UInt8, x : UInt8, y : UInt8) : Instruction
      encode_rrr(Opcode::Vec2Math, Vec2MathSubOp::New.value, dest, x, y)
    end

    # Encodes Vec2 property reads
    def self.encode_vec2_get_x(dest : UInt8, obj : UInt8) : Instruction
      encode_rrr(Opcode::Vec2Prop, Vec2PropSubOp::GetX.value, dest, obj, 0_u8)
    end

    def self.encode_vec2_get_y(dest : UInt8, obj : UInt8) : Instruction
      encode_rrr(Opcode::Vec2Prop, Vec2PropSubOp::GetY.value, dest, obj, 0_u8)
    end

    # Encodes Vec2 property writes
    def self.encode_vec2_set_x(obj : UInt8, val : UInt8) : Instruction
      encode_rrr(Opcode::Vec2Prop, Vec2PropSubOp::SetX.value, obj, val, 0_u8)
    end

    def self.encode_vec2_set_y(obj : UInt8, val : UInt8) : Instruction
      encode_rrr(Opcode::Vec2Prop, Vec2PropSubOp::SetY.value, obj, val, 0_u8)
    end

    # Encodes Fiber yield and spawn
    def self.encode_yield : Instruction
      encode_rrr(Opcode::FiberOp, FiberSubOp::Yield.value, 0_u8, 0_u8, 0_u8)
    end

    def self.encode_spawn_fiber(dest : UInt8, func_idx : UInt16 | Int32) : Instruction
      encode_r_imm(Opcode::FiberOp, FiberSubOp::Spawn.value, dest, func_idx.to_u16)
    end

    # Backward-compatible 3-register encoder mapping to new 5-bit opcode + 3-bit subop.
    def self.encode_abc(op : Opcode | LegacyOpcode, dst : UInt8, a : UInt8, b : UInt8, subop : UInt8 = 0_u8) : Instruction
      # Map legacy opcodes if needed
      real_op, real_subop = map_legacy_op(op, subop)
      encode_rrr(real_op, real_subop, dst, a, b)
    end

    # Backward-compatible immediate encoder mapping to new 5-bit opcode + 3-bit subop.
    def self.encode_ab_imm(op : Opcode | LegacyOpcode, dst : UInt8, imm : UInt16, subop : UInt8 = 0_u8) : Instruction
      real_op, real_subop = map_legacy_op(op, subop)
      encode_r_imm(real_op, real_subop, dst, imm)
    end

    # Backward-compatible branch encoder mapping to new 5-bit opcode + 3-bit subop.
    def self.encode_branch(op : Opcode | LegacyOpcode, reg : UInt8, offset : Int16, subop : UInt8 = 0_u8) : Instruction
      real_op, real_subop = map_legacy_op(op, subop)
      if real_op == Opcode::Jump && real_subop == JumpSubOp::JumpRel24.value
        encode_jump_rel24(offset.to_i32)
      else
        encode_branch_rel(real_op, real_subop, reg, offset)
      end
    end

    # Encodes a conditional branch if falsy (zero or nil)
    def self.encode_jump_if_false(reg : UInt8, offset : Int16) : Instruction
      encode_branch_rel(Opcode::BranchZ, BranchZSubOp::Falsy.value, reg, offset)
    end

    # Encodes a conditional branch if truthy (non-zero and non-nil)
    def self.encode_jump_if_true(reg : UInt8, offset : Int16) : Instruction
      encode_branch_rel(Opcode::BranchZ, BranchZSubOp::Truthy.value, reg, offset)
    end

    # Helper mapping legacy opcode values to [Primary Opcode, SubOp] pairs
    private def self.map_legacy_op(op : Opcode | LegacyOpcode, default_subop : UInt8) : Tuple(Opcode, UInt8)
      case op
      when LegacyOpcode::JumpIfFalse
        {Opcode::BranchZ, BranchZSubOp::Falsy.value}
      when LegacyOpcode::JumpIfTrue
        {Opcode::BranchZ, BranchZSubOp::Truthy.value}
      when LegacyOpcode::LoadNil
        {Opcode::LoadImm, LoadImmSubOp::Nil.value}
      when LegacyOpcode::LoadBool
        {Opcode::LoadImm, LoadImmSubOp::Bool.value}
      when LegacyOpcode::LoadInt
        {Opcode::LoadImm, default_subop == 0_u8 ? LoadImmSubOp::Int16.value : default_subop}
      when LegacyOpcode::Div
        {Opcode::DivMod, DivModSubOp::DivS32.value}
      when LegacyOpcode::Mod
        {Opcode::DivMod, DivModSubOp::ModS32.value}
      when LegacyOpcode::Neg
        {Opcode::Sub, SubSubOp::NegI32.value}
      when LegacyOpcode::BitAnd
        {Opcode::Bitwise, BitwiseSubOp::And.value}
      when LegacyOpcode::BitOr
        {Opcode::Bitwise, BitwiseSubOp::Or.value}
      when LegacyOpcode::BitXor
        {Opcode::Bitwise, BitwiseSubOp::Xor.value}
      when LegacyOpcode::BitNot
        {Opcode::Bitwise, BitwiseSubOp::Nor.value}
      when LegacyOpcode::ShiftLeft
        {Opcode::Shift, ShiftSubOp::Sll.value}
      when LegacyOpcode::ShiftRight
        {Opcode::Shift, ShiftSubOp::Sra.value}
      when LegacyOpcode::Eq
        {Opcode::Compare, CompareSubOp::Eq.value}
      when LegacyOpcode::Ne
        {Opcode::Compare, CompareSubOp::Ne.value}
      when LegacyOpcode::Lt
        {Opcode::Compare, CompareSubOp::Lt.value}
      when LegacyOpcode::Le
        {Opcode::Compare, CompareSubOp::Le.value}
      when LegacyOpcode::Gt
        {Opcode::Compare, CompareSubOp::Gt.value}
      when LegacyOpcode::Ge
        {Opcode::Compare, CompareSubOp::Ge.value}
      when LegacyOpcode::Vec2New
        {Opcode::Vec2Math, Vec2MathSubOp::New.value}
      when LegacyOpcode::Vec2Add
        {Opcode::Vec2Math, Vec2MathSubOp::Add.value}
      when LegacyOpcode::Vec2GetX
        {Opcode::Vec2Prop, Vec2PropSubOp::GetX.value}
      when LegacyOpcode::Vec2GetY
        {Opcode::Vec2Prop, Vec2PropSubOp::GetY.value}
      when LegacyOpcode::Vec2SetX
        {Opcode::Vec2Prop, Vec2PropSubOp::SetX.value}
      when LegacyOpcode::Vec2SetY
        {Opcode::Vec2Prop, Vec2PropSubOp::SetY.value}
      when LegacyOpcode::ColorNew
        {Opcode::ColorOp, ColorSubOp::Rgba32.value}
      when LegacyOpcode::SpawnFiber
        {Opcode::FiberOp, FiberSubOp::Spawn.value}
      when LegacyOpcode::Yield
        {Opcode::FiberOp, FiberSubOp::Yield.value}
      when LegacyOpcode::ResumeFiber
        {Opcode::FiberOp, FiberSubOp::Resume.value}
      when LegacyOpcode::Halt
        {Opcode::Sys, SysSubOp::Halt.value}
      when LegacyOpcode::Nop
        {Opcode::Sys, SysSubOp::Nop.value}
      when Opcode::Jump
        {Opcode::Jump, JumpSubOp::JumpRel24.value}
      when Opcode::LoadImm
        {Opcode::LoadImm, default_subop == 0_u8 ? LoadImmSubOp::Int16.value : default_subop}
      when Opcode
        {op, default_subop}
      else
        {Opcode::Sys, SysSubOp::Nop.value}
      end
    end

    # Decodes and returns the 5-bit primary Opcode (0x00..0x1F).
    def opcode : Opcode
      Opcode.from_value(((@raw >> 27) & 0x1F_u32).to_u8)
    end

    # Decodes and returns the 3-bit SubOp field (0..7).
    def subop : UInt8
      ((@raw >> 24) & 0x07_u32).to_u8
    end

    # Decodes and returns the 8-bit destination or primary register index ($r0..$r255).
    def dst : UInt8
      ((@raw >> 16) & 0xFF_u32).to_u8
    end

    # Decodes and returns the 8-bit first source register index ($r0..$r255).
    def a : UInt8
      ((@raw >> 8) & 0xFF_u32).to_u8
    end

    # Decodes and returns the 8-bit second source register index ($r0..$r255).
    def b : UInt8
      (@raw & 0xFF_u32).to_u8
    end

    # Decodes and returns the 16-bit unsigned immediate value.
    def imm16 : UInt16
      (@raw & 0xFFFF_u32).to_u16
    end

    # Decodes and returns the 8-bit signed branch offset for fused branch instructions.
    def offset8 : Int8
      raw_val = (@raw & 0xFF_u32).to_i32
      (raw_val >= 0x80 ? raw_val - 0x100 : raw_val).to_i8
    end

    # Decodes and returns the 16-bit signed relative branch PC offset.
    def branch_offset : Int16
      raw_val = imm16.to_i32
      (raw_val >= 0x8000 ? raw_val - 0x10000 : raw_val).to_i16
    end

    # Decodes and returns the 24-bit signed relative unconditional jump PC offset.
    def jump_offset24 : Int32
      raw_val = (@raw & 0xFFFFFF_u32).to_i32
      raw_val >= 0x800000 ? raw_val - 0x1000000 : raw_val
    end

    # Maps Citrine-32 instruction to legacy opcode number for simulation and tooling compatibility
    def legacy_opcode_number : Int32
      case opcode
      when Opcode::Sys
        subop == SysSubOp::Halt.value ? 70 : 0
      when Opcode::Move
        1
      when Opcode::LoadConst
        5
      when Opcode::LoadImm
        case subop
        when LoadImmSubOp::Nil.value then 2
        when LoadImmSubOp::Bool.value then 3
        else 4
        end
      when Opcode::Add
        10
      when Opcode::Sub
        subop == SubSubOp::NegI32.value ? 15 : 11
      when Opcode::Mul
        12
      when Opcode::DivMod
        subop == DivModSubOp::ModS32.value ? 14 : 13
      when Opcode::Bitwise
        case subop
        when BitwiseSubOp::And.value then 16
        when BitwiseSubOp::Or.value then 17
        when BitwiseSubOp::Xor.value then 18
        when BitwiseSubOp::Nor.value then 28
        else 16
        end
      when Opcode::Shift
        case subop
        when ShiftSubOp::Sll.value then 19
        else 27
        end
      when Opcode::Compare
        case subop
        when CompareSubOp::Eq.value then 30
        when CompareSubOp::Ne.value then 31
        when CompareSubOp::Lt.value then 32
        when CompareSubOp::Le.value then 33
        when CompareSubOp::Gt.value then 34
        when CompareSubOp::Ge.value then 35
        else 30
        end
      when Opcode::Jump
        40
      when Opcode::BranchZ
        subop == BranchZSubOp::Falsy.value ? 42 : 41
      when Opcode::BranchCmp
        73
      when Opcode::LoopDecBr
        74
      when Opcode::FusedMadd
        75
      when Opcode::Call
        50
      when Opcode::Return
        51
      when Opcode::CallNative
        52
      when Opcode::Vec2Math
        subop == Vec2MathSubOp::Add.value ? 25 : 20
      when Opcode::Vec2Prop
        case subop
        when Vec2PropSubOp::GetX.value then 21
        when Vec2PropSubOp::GetY.value then 22
        when Vec2PropSubOp::SetX.value then 23
        when Vec2PropSubOp::SetY.value then 24
        else 21
        end
      when Opcode::ColorOp
        26
      when Opcode::InlineAsm
        72
      when Opcode::FiberOp
        76
      when Opcode::ChannelOp
        77
      when Opcode::FloatAlu
        78
      else
        0
      end
    end

    # Maps a native function ID to its 3-bit hardware domain (0..7)
    def self.native_domain(native_id) : UInt8
      case native_id.to_i32
      when 10..29, 34, 100..119
        CallNativeSubOp::SysGsDraw.value # 1: Graphics & GL
      when 35..39, 220..225
        CallNativeSubOp::SysSpu2Audio.value # 2: SPU2 Audio & CD-DA
      when 40..49
        CallNativeSubOp::SysPadInput.value # 3: DualShock 2 Input
      when 90..98
        CallNativeSubOp::SysVideoPlay.value # 4: Fluorite Video
      when 60, 70, 71
        CallNativeSubOp::SysHud.value # 5: HUD & Log
      when 120..149
        CallNativeSubOp::SysIoFs.value # 6: Collections & IO
      when 210..219
        CallNativeSubOp::SysUserC.value # 7: User C & Coprocessor
      else
        CallNativeSubOp::SysKernel.value # 0: Kernel & Core
      end
    end

    # Helper returning raw 32-bit machine word for CallNative
    def self.call_native_raw(dst, base, native_id) : UInt32
      dom = native_domain(native_id)
      (Opcode::CallNative.value.to_u32 << 27) | ((dom.to_u32 & 0x07_u32) << 24) |
        ((dst.to_u32 & 0xFF_u32) << 16) | ((base.to_u32 & 0xFF_u32) << 8) | (native_id.to_u32 & 0xFF_u32)
    end

    def self.encode_call_native(dst, base, native_id) : Instruction
      new(call_native_raw(dst, base, native_id))
    end
  end
end
