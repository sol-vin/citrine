module Citrine
  enum Opcode : UInt8
    Nop         =  0
    Move        =  1
    LoadNil     =  2
    LoadBool    =  3
    LoadInt     =  4
    LoadConst   =  5
    Add         = 10
    Sub         = 11
    Mul         = 12
    Div         = 13
    Mod         = 14
    Neg         = 15
    Vec2New     = 20
    Vec2GetX    = 21
    Vec2GetY    = 22
    Vec2SetX    = 23
    Vec2SetY    = 24
    Vec2Add     = 25
    ColorNew    = 26
    Eq          = 30
    Ne          = 31
    Lt          = 32
    Le          = 33
    Gt          = 34
    Ge          = 35
    Jump        = 40
    JumpIfTrue  = 41
    JumpIfFalse = 42
    Call        = 50
    Return      = 51
    CallNative  = 52
    SpawnFiber  = 60
    Yield       = 61
    ResumeFiber = 62
    Halt        = 70
  end

  struct Instruction
    getter raw : UInt32

    def initialize(@raw : UInt32)
    end

    def self.encode_abc(op : Opcode, dst : UInt8, a : UInt8, b : UInt8) : Instruction
      val = (op.value.to_u32 << 24) | (dst.to_u32 << 16) | (a.to_u32 << 8) | b.to_u32
      new(val)
    end

    def self.encode_ab_imm(op : Opcode, dst : UInt8, imm : UInt16) : Instruction
      val = (op.value.to_u32 << 24) | (dst.to_u32 << 16) | imm.to_u32
      new(val)
    end

    def self.encode_branch(op : Opcode, reg : UInt8, offset : Int16) : Instruction
      u_offset = (offset.to_i32 & 0xFFFF).to_u16
      val = (op.value.to_u32 << 24) | (reg.to_u32 << 16) | u_offset.to_u32
      new(val)
    end

    def opcode : Opcode
      Opcode.from_value((@raw >> 24).to_u8)
    end

    def dst : UInt8
      ((@raw >> 16) & 0xFF_u32).to_u8
    end

    def a : UInt8
      ((@raw >> 8) & 0xFF_u32).to_u8
    end

    def b : UInt8
      (@raw & 0xFF_u32).to_u8
    end

    def imm16 : UInt16
      (@raw & 0xFFFF_u32).to_u16
    end

    def branch_offset : Int16
      raw_val = imm16.to_i32
      (raw_val >= 0x8000 ? raw_val - 0x10000 : raw_val).to_i16
    end
  end
end
