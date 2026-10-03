module Citrine
  # Citrine Virtual Machine Instruction Opcodes.
  #
  # Each opcode is an 8-bit unsigned integer (`UInt8`) identifying a single 32-bit VM instruction.
  #
  # ## Instruction Categories
  # - **Control Flow & Registers**: `Nop`, `Move`, `LoadNil`, `LoadBool`, `LoadInt`, `LoadConst`, `Jump`, `JumpIfTrue`, `JumpIfFalse`, `Call`, `Return`, `CallNative`, `Halt`
  # - **Integer Arithmetic & Logic**: `Add`, `Sub`, `Mul`, `Div`, `Mod`, `Neg`, `BitAnd`, `BitOr`, `BitXor`, `ShiftLeft`, `ShiftRight`, `BitNot`
  # - **2D Geometry & Color**: `Vec2New`, `Vec2GetX`, `Vec2GetY`, `Vec2SetX`, `Vec2SetY`, `Vec2Add`, `ColorNew`
  # - **Comparisons**: `Eq`, `Ne`, `Lt`, `Le`, `Gt`, `Ge`
  # - **Concurrency & Fibers**: `SpawnFiber`, `Yield`, `ResumeFiber`
  #
  # ## Example Usage
  # ```crystal
  # require "citrine/compiler/opcode"
  #
  # # Encode an Add instruction: R[0] = R[1] + R[2]
  # inst = Citrine::Instruction.encode_abc(Citrine::Opcode::Add, dst: 0_u8, a: 1_u8, b: 2_u8)
  # puts inst.opcode # => Citrine::Opcode::Add
  # puts inst.dst    # => 0
  # puts inst.a      # => 1
  # puts inst.b      # => 2
  #
  # # Encode an immediate integer load: R[4] = 42
  # load_inst = Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, dst: 4_u8, imm: 42_u16)
  # puts load_inst.imm16 # => 42
  # ```
  enum Opcode : UInt8
    # No operation; advances PC by 1.
    Nop         =  0

    # Register copy: `R[dst] = R[a]`.
    Move        =  1

    # Load nil literal: `R[dst] = Nil`.
    LoadNil     =  2

    # Load boolean literal: `R[dst] = (b != 0)`.
    LoadBool    =  3

    # Load 16-bit signed immediate integer: `R[dst] = imm16`.
    LoadInt     =  4

    # Load constant from `.cbc` constant pool at index `imm16`: `R[dst] = ConstPool[imm16]`.
    LoadConst   =  5

    # 32-bit signed integer addition: `R[dst] = R[a] + R[b]`. Also concatenates strings when operands are string pointers.
    Add         = 10

    # 32-bit signed integer subtraction: `R[dst] = R[a] - R[b]`.
    Sub         = 11

    # 32-bit signed integer multiplication: `R[dst] = R[a] * R[b]`.
    Mul         = 12

    # Guarded integer division: `R[dst] = R[a] / R[b]` (returns 0 if divisor is 0).
    Div         = 13

    # Guarded integer modulo: `R[dst] = R[a] % R[b]` (returns 0 if divisor is 0).
    Mod         = 14

    # Two's complement integer negation: `R[dst] = -R[a]`.
    Neg         = 15

    # Bitwise AND: `R[dst] = R[a] & R[b]`.
    BitAnd      = 16

    # Bitwise OR: `R[dst] = R[a] | R[b]`.
    BitOr       = 17

    # Bitwise XOR: `R[dst] = R[a] ^ R[b]`.
    BitXor      = 18

    # Logical shift left: `R[dst] = R[a] << R[b]`.
    ShiftLeft   = 19

    # Vector2 constructor: `R[dst] = Vector2.new(R[a], R[b])`.
    Vec2New     = 20

    # Extract X coordinate from Vector2: `R[dst] = R[a].x`.
    Vec2GetX    = 21

    # Extract Y coordinate from Vector2: `R[dst] = R[a].y`.
    Vec2GetY    = 22

    # Mutate X coordinate of Vector2: `R[dst].x = R[a]`.
    Vec2SetX    = 23

    # Mutate Y coordinate of Vector2: `R[dst].y = R[a]`.
    Vec2SetY    = 24

    # Component-wise Vector2 addition: `R[dst] = R[a] + R[b]`.
    Vec2Add     = 25

    # Pack 4 consecutive registers into 32-bit RGBA color word: `R[dst] = RGBA(R[a..a+3])`.
    ColorNew    = 26

    # Arithmetic shift right: `R[dst] = R[a] >> R[b]`.
    ShiftRight  = 27

    # Bitwise NOT / bit inversion: `R[dst] = ~R[a]`.
    BitNot      = 28

    # Equality check: `R[dst] = (R[a] == R[b])`. Performs string content comparison if operands are string pointers.
    Eq          = 30

    # Inequality check: `R[dst] = (R[a] != R[b])`.
    Ne          = 31

    # Signed less-than comparison: `R[dst] = (R[a] < R[b])`.
    Lt          = 32

    # Signed less-than-or-equal comparison: `R[dst] = (R[a] <= R[b])`.
    Le          = 33

    # Signed greater-than comparison: `R[dst] = (R[a] > R[b])`.
    Gt          = 34

    # Signed greater-than-or-equal comparison: `R[dst] = (R[a] >= R[b])`.
    Ge          = 35

    # Relative unconditional jump: `PC = PC + 1 + offset`.
    Jump        = 40

    # Conditional branch if truthy (not nil, not false): `if R[cond] then PC = PC + 1 + offset`.
    JumpIfTrue  = 41

    # Conditional branch if falsy (nil or false/0): `if !R[cond] then PC = PC + 1 + offset`.
    JumpIfFalse = 42

    # Function call: pushes return PC and switches frame to function at `imm16`. Result returned in `R[dst]`.
    Call        = 50

    # Function return: copies `R[src]` to caller's destination register and restores caller frame.
    Return      = 51

    # Native service call: invokes Citrine hardware subsystem `imm16` with arguments starting at `R[dst]`.
    CallNative  = 52

    # Fiber creation: creates a new lightweight fiber coroutine for function `imm16`.
    SpawnFiber  = 60

    # Yield active fiber context back to scheduler.
    Yield       = 61

    # Resume suspended fiber identified by `R[a]`.
    ResumeFiber = 62

    # Immediate halt: terminates VM execution, flushes telemetry, and parks CPU.
    Halt        = 70
  end

  # Fixed-width 32-bit Little-Endian Citrine VM instruction word.
  #
  # Citrine instructions fit cleanly into 32 bits to match MIPS R5900 bus width and cacheline alignment.
  #
  # ## Encodings
  # - **ABC**: `[Opcode:8][Dst:8][RegA:8][RegB:8]`
  # - **AB_IMM**: `[Opcode:8][Dst:8][Imm16:16]`
  # - **BRANCH**: `[Opcode:8][Cond:8][SignedOffset16:16]`
  #
  # ## Example
  # ```crystal
  # inst = Citrine::Instruction.encode_abc(Citrine::Opcode::Move, dst: 5_u8, a: 2_u8, b: 0_u8)
  # inst.opcode # => Citrine::Opcode::Move
  # inst.dst    # => 5
  # inst.a      # => 2
  # ```
  struct Instruction
    # Returns the raw 32-bit unsigned integer encoding of the instruction.
    getter raw : UInt32

    # Creates an `Instruction` from a raw 32-bit word.
    def initialize(@raw : UInt32)
    end

    # Encodes a 3-register `ABC` format instruction (`[Opcode:8][Dst:8][RegA:8][RegB:8]`).
    #
    # ```crystal
    # inst = Citrine::Instruction.encode_abc(Citrine::Opcode::Add, dst: 0_u8, a: 1_u8, b: 2_u8)
    # ```
    def self.encode_abc(op : Opcode, dst : UInt8, a : UInt8, b : UInt8) : Instruction
      val = (op.value.to_u32 << 24) | (dst.to_u32 << 16) | (a.to_u32 << 8) | b.to_u32
      new(val)
    end

    # Encodes an immediate `AB_IMM` format instruction (`[Opcode:8][Dst:8][Imm16:16]`).
    #
    # ```crystal
    # inst = Citrine::Instruction.encode_ab_imm(Citrine::Opcode::LoadInt, dst: 3_u8, imm: 100_u16)
    # ```
    def self.encode_ab_imm(op : Opcode, dst : UInt8, imm : UInt16) : Instruction
      val = (op.value.to_u32 << 24) | (dst.to_u32 << 16) | imm.to_u32
      new(val)
    end

    # Encodes a relative `BRANCH` format instruction (`[Opcode:8][Cond:8][SignedOffset16:16]`).
    #
    # ```crystal
    # inst = Citrine::Instruction.encode_branch(Citrine::Opcode::JumpIfFalse, reg: 1_u8, offset: 5_i16)
    # ```
    def self.encode_branch(op : Opcode, reg : UInt8, offset : Int16) : Instruction
      u_offset = (offset.to_i32 & 0xFFFF).to_u16
      val = (op.value.to_u32 << 24) | (reg.to_u32 << 16) | u_offset.to_u32
      new(val)
    end

    # Decodes and returns the 8-bit `Opcode` of the instruction.
    def opcode : Opcode
      Opcode.from_value((@raw >> 24).to_u8)
    end

    # Decodes and returns the 8-bit destination or primary register index (`$r0`..`$r255`).
    def dst : UInt8
      ((@raw >> 16) & 0xFF_u32).to_u8
    end

    # Decodes and returns the 8-bit first source register index (`$r0`..`$r255`).
    def a : UInt8
      ((@raw >> 8) & 0xFF_u32).to_u8
    end

    # Decodes and returns the 8-bit second source register index (`$r0`..`$r255`).
    def b : UInt8
      (@raw & 0xFF_u32).to_u8
    end

    # Decodes and returns the 16-bit unsigned immediate value.
    def imm16 : UInt16
      (@raw & 0xFFFF_u32).to_u16
    end

    # Decodes and returns the 16-bit signed relative branch PC offset.
    def branch_offset : Int16
      raw_val = imm16.to_i32
      (raw_val >= 0x8000 ? raw_val - 0x10000 : raw_val).to_i16
    end
  end
end
