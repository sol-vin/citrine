module Citrine
  enum ValueType : UInt8
    Nil     = 0
    Bool    = 1
    Int32   = 2
    Float32 = 3
    Vec2    = 4
    Color   = 5
    Handle  = 6
    String  = 7
    Object  = 8
  end

  enum NativeId : UInt16
    None            =  0
    InitWindow      =  1
    CloseWindow     =  2
    WindowOpen      =  3
    SetTargetFPS    =  4
    GetFPS          =  5
    GetDeltaTime    =  6
    BeginDrawing    = 10
    EndDrawing      = 11
    ClearBackground = 12
    DrawRectangle   = 20
    DrawCircle      = 21
    DrawLine        = 22
    DrawTriangle    = 23
    DrawText        = 24
    BeginMode3D     = 25
    EndMode3D       = 26
    DrawCube        = 27
    DrawCubeWires   = 28
    DrawGrid        = 29
    LoadTexture     = 30
    DrawTexture     = 31
    DrawTextureRec  = 32
    UnloadTexture   = 33
    DrawMesh        = 34
    ButtonDown      = 40
    ButtonPressed   = 41
    ButtonReleased  = 42
    GetAnalog       = 43
    SetRumble       = 44
    LoadSound       = 50
    PlaySound       = 51
    StopSound       = 52
    SetDebugOverlay = 60
    Log             = 70
    Panic           = 99
  end

  enum Button : UInt8
    Select   =  0
    L3       =  1
    R3       =  2
    Start    =  3
    Up       =  4
    Right    =  5
    Down     =  6
    Left     =  7
    L2       =  8
    R2       =  9
    L1       = 10
    R1       = 11
    Triangle = 12
    Circle   = 13
    Cross    = 14
    Square   = 15
  end

  struct ColorVal
    property r : UInt8
    property g : UInt8
    property b : UInt8
    property a : UInt8

    def initialize(@r : UInt8, @g : UInt8, @b : UInt8, @a : UInt8 = 255_u8)
    end

    def to_u32 : UInt32
      (@r.to_u32) | (@g.to_u32 << 8) | (@b.to_u32 << 16) | (@a.to_u32 << 24)
    end
  end

  struct Vec2Val
    property x : Float32
    property y : Float32

    def initialize(@x : Float32, @y : Float32)
    end
  end
end
