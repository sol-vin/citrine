module Citrine
  # Primitive value type tags used by the Citrine compiler and runtime type-checker.
  #
  # ```crystal
  # type_tag = Citrine::ValueType::Int32
  # puts type_tag.value # => 2
  # ```
  enum ValueType : UInt8
    # Null or uninitialized pointer representation.
    Nil     = 0
    # Boolean true/false flag.
    Bool    = 1
    # 32-bit signed two's complement integer.
    Int32   = 2
    # 32-bit IEEE 754 single-precision floating-point number.
    Float32 = 3
    # 2D floating-point vector `(x, y)`.
    Vec2    = 4
    # 32-bit packed RGBA color word.
    Color   = 5
    # Opaque hardware resource handle (texture ID, sound ID, channel ID).
    Handle  = 6
    # Pointer to null-terminated ASCII string.
    String  = 7
    # Pointer to allocated class or struct instance on heap or arena.
    Object  = 8
  end

  # Native hardware and runtime service dispatch identifiers.
  #
  # Dispatched via `Opcode::CallNative` (0x34) with arguments starting at `R[arg_base]`.
  #
  # ## Subsystem Categories
  # - **Display & Timing** (1 - 6, 65): Window setup, FPS limiter, V-Blank wait, sleep.
  # - **2D Rasterization** (10 - 24, 100): Clear, rectangles, circles, lines, triangles, text.
  # - **3D Graphics** (25 - 29, 34): 3D camera mode, cubes, wireframes, coordinate grid, meshes.
  # - **Textures & Media** (30 - 33, 90 - 95): Texture loading, blitting, Fluorite video streaming.
  # - **Audio** (35 - 37): SPU2 sample loading, voice playback, voice stopping.
  # - **DualShock 2 Input** (40 - 44): Button state, press/release edges, analog axes, dual vibration motors.
  # - **Fibers & Channels** (66 - 67, 80 - 85): Cooperative CSP concurrency, channels, capacity, non-blocking receive.
  # - **Citrine GL** (101 - 111): Immediate-mode OpenGL 1.1 API, matrix stack, vertex coloring.
  # - **Collections** (120 - 133): Dynamic arrays, static inline arrays.
  # - **Memory IO** (140 - 148): Byte buffers, formatted output, string conversion.
  # - **Object & Pointer Model** (150 - 168): Instance allocation, field access, 8-byte aligned malloc, free-list recycling.
  # - **Type Reflection** (170 - 171): `is_a?` type checks, `as` casting.
  # - **Memory Tiers & GC** (180 - 185): Context arenas (`make_vm_context`), stats, idle VSync mark-sweep.
  # - **String Subsystem** (186 - 196): Substring search, casing, stripping, concatenation, regex matching.
  #
  # ## Example Usage
  # ```crystal
  # # Triggering BeginDrawing via native call ID
  # Citrine::NativeId::BeginDrawing.value # => 10
  #
  # # Checking Button cross state
  # Citrine::NativeId::ButtonDown.value # => 40
  # ```
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
    ActionPressed   = 45
    ActionDown      = 46
    ActionReleased  = 47
    ActionRegister  = 48
    LoadSound       = 35
    PlaySound       = 36
    StopSound       = 37
    SetDebugOverlay = 60
    Sleep           = 65
    FiberId         = 66
    FiberAlive      = 67
    Log             = 70
    DebugLog        = 71
    ChannelNew      = 80
    ChannelSend     = 81
    ChannelReceive  = 82
    ChannelTryReceive = 83
    ChannelCount    = 84
    ChannelCapacity = 85
    LoadVideo       = 90
    PlayVideo       = 91
    DrawVideoFrame  = 92
    VideoFinished   = 93
    PauseVideo      = 94
    StopVideo       = 95
    Panic           = 99
    DrawQuad        = 100
    GLBegin         = 101
    GLEnd           = 102
    GLVertex        = 103
    GLColor         = 104
    GLTexCoord      = 105
    GLPushMatrix    = 106
    GLPopMatrix     = 107
    GLTranslate     = 108
    GLRotate        = 109
    GLScale         = 110
    GLLoadIdentity  = 111
    ArrayNew        = 120
    ArrayGet        = 121
    ArraySet        = 122
    ArrayPush       = 123
    ArrayPop        = 124
    ArraySize       = 125
    ArrayClear      = 126
    StaticArrayNew  = 130
    StaticArrayGet  = 131
    StaticArraySet  = 132
    StaticArraySize = 133
    MemoryIONew     = 140
    MemoryIOWriteByte = 141
    MemoryIOWrite   = 142
    MemoryIOPuts    = 143
    MemoryIOToS     = 144
    MemoryIORewind  = 145
    MemoryIOPos     = 146
    MemoryIOSize    = 147
    MemoryIOClear   = 148
    ObjectNew       = 150
    ObjectGetField  = 151
    ObjectSetField  = 152
    StructCopy      = 153
    PointerMalloc   = 160
    PointerGet      = 161
    PointerSet      = 162
    PointerOffset   = 163
    PointerAddress  = 164
    PointerNew      = 165
    BoxNew          = 166
    BoxUnbox        = 167
    PointerFree     = 168
    TypeIsA         = 170
    TypeAsCast      = 171
    ContextSet      = 180
    ContextClear    = 181
    MemoryStats     = 182
    GCCycle         = 185
    StringStrip     = 186
    StringDowncase  = 187
    StringUpcase    = 188
    StringIncludes  = 189
    RegexNew        = 190
    RegexMatch      = 191
    StringStartsWith = 192
    StringEndsWith   = 193
    StringSplit      = 194
    StringConcat     = 195
    ToString         = 196
    VU0BatchTransform = 210
    VU0BatchDot      = 211
    AudioPlayCDDA    = 220
    AudioStopCDDA    = 221
    AudioGetCDDAStatus = 222
    AudioSetVolume   = 223
    AudioSeekStream  = 224
  end

  # Type discriminator identifiers for runtime `is_a?` and `as` type introspection.
  #
  # ```crystal
  # Citrine::TypeKind::String.value # => 0xF005
  # ```
  enum TypeKind : UInt32
    Nil         = 0xF001_u32
    Bool        = 0xF002_u32
    Int32       = 0xF003_u32
    Float32     = 0xF004_u32
    String      = 0xF005_u32
    Array       = 0xF006_u32
    StaticArray = 0xF007_u32
    Pointer     = 0xF008_u32
    Box         = 0xF009_u32
    Enum        = 0xF010_u32
  end

  # Primitive rasterization topologies for Citrine GL immediate-mode rendering (`Citrine::GL.begin`).
  #
  # ```crystal
  # Citrine::GL.begin(Citrine::GLMode::Triangles)
  # Citrine::GL.color(1.0, 0.0, 0.0, 1.0)
  # Citrine::GL.vertex(0.0, 1.0, 0.0)
  # Citrine::GL.end
  # ```
  enum GLMode : UInt8
    Points        = 0
    Lines         = 1
    LineStrip     = 2
    LineLoop      = 3
    Triangles     = 4
    TriangleStrip = 5
    TriangleFan   = 6
    Quads         = 7
  end

  # Sony PlayStation 2 DualShock 2 controller buttons.
  #
  # Bit indices corresponding to the SIO2 serial peripheral interface button packet.
  #
  # ```crystal
  # if Citrine.button_pressed?(Citrine::Button::Cross)
  #   player_jump
  # end
  # ```
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

  # 32-bit packed RGBA color representation for Graphic Synthesizer registers.
  #
  # ```crystal
  # red = Citrine::ColorVal.new(255_u8, 0_u8, 0_u8)
  # puts red.to_u32 # => 0xFF0000FF
  # ```
  struct ColorVal
    property r : UInt8
    property g : UInt8
    property b : UInt8
    property a : UInt8

    def initialize(@r : UInt8, @g : UInt8, @b : UInt8, @a : UInt8 = 255_u8)
    end

    # Converts RGBA components into a 32-bit packed unsigned integer word.
    def to_u32 : UInt32
      (@r.to_u32) | (@g.to_u32 << 8) | (@b.to_u32 << 16) | (@a.to_u32 << 24)
    end
  end

  # 2D floating-point vector with single-precision coordinates.
  #
  # ```crystal
  # pos = Citrine::Vec2Val.new(320.0_f32, 224.0_f32)
  # puts pos.x # => 320.0
  # puts pos.y # => 224.0
  # ```
  struct Vec2Val
    property x : Float32
    property y : Float32

    def initialize(@x : Float32, @y : Float32)
    end
  end
end
