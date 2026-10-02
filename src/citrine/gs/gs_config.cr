module Citrine
  module GS
    # Graphics Synthesizer (GS) Privileged Register Map
    GS_BASE      = 0x12000000_u32
    GS_PMODE     = 0x12000000_u32
    GS_SMODE2    = 0x12000020_u32
    GS_DISPFB1   = 0x12000070_u32
    GS_DISPLAY1  = 0x12000080_u32
    GS_DISPFB2   = 0x12000090_u32
    GS_DISPLAY2  = 0x120000A0_u32
    GS_BGCOLOR   = 0x120000E0_u32
    GS_CSR       = 0x12001000_u32
    GS_IMR       = 0x12001010_u32

    # DMAC Channel 2 (GIF) Registers
    D2_CHCR      = 0x1000A000_u32
    D2_MADR      = 0x1000A010_u32
    D2_QWC       = 0x1000A020_u32

    # Default NTSC 640x448 Field Mode Display Configuration
    # Circuit 1 enable, CRTMD=1, MMOD=1, AMOD=1, ALP=0xFF -> 0xFF65
    PMODE_NTSC_DEFAULT    = 0x000000000000FF65_u64

    # DISPFB: FBP=0, FBW=10 (640px), PSM=0 (PSMCT32), DBX=0, DBY=0 -> 0x1400
    DISPFB_NTSC_DEFAULT   = 0x0000000000001400_u64

    # DISPLAY: MAGH=3, MAGV=0, DW=2559, DH=447, DX=658, DY=50 -> 0x001bf9ff01832290
    DISPLAY_NTSC_DEFAULT  = 0x001bf9ff01832290_u64

    # Serial I/O (UART) Registers
    SIO_BASE     = 0x1000F100_u32
    SIO_LSR      = 0x1000F110_u32
    SIO_TXFIFO   = 0x1000F180_u32
    SIO_RXFIFO   = 0x1000F1C0_u32

    # GS Primitive Types (PRIM register)
    enum PrimitiveType : UInt8
      Point         = 0
      Line          = 1
      LineStrip     = 2
      Triangle      = 3
      TriangleStrip = 4
      TriangleFan   = 5
      Sprite        = 6
    end
  end
end
