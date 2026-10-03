# Citrine Virtual Machine & Bytecode Specification

**Version**: 1.0  
**Target Hardware**: Sony PlayStation 2 (Emotion Engine MIPS R5900 @ 294.912 MHz)  
**Binary Container**: `.cbc` (Citrine Bytecode)

---

## 1. Container Binary Format (`.cbc`)

Citrine compiled bytecode files (`.cbc`) are binary containers structured in four sequential sections:

```text
+-------------------------------------------------------+
| File Header (16 bytes)                                |
+-------------------------------------------------------+
| Constant Pool (Strings, Ints, Floats, Colors)         |
+-------------------------------------------------------+
| Function Symbol Table (Signatures, Arity, PC Offsets) |
+-------------------------------------------------------+
| Instruction Stream (32-bit Words)                     |
+-------------------------------------------------------+
```

### 1.1 Header Structure (16 bytes)

| Offset | Type | Field | Description |
|---|---|---|---|
| `0x00` | `char[4]` | `magic` | Identifier: `CBC\x01` (`0x43`, `0x42`, `0x43`, `0x01`) |
| `0x04` | `uint32` | `const_count` | Number of constant pool entries |
| `0x08` | `uint32` | `fn_count` | Number of declared functions |
| `0x0C` | `uint32` | `code_count` | Total count of 32-bit instructions |

All multi-byte numeric values are stored in **Little-Endian** byte order.

---

## 2. Instruction Word Encodings (32-bit)

Every instruction occupies exactly 4 bytes (32 bits).

### 2.1 Format ABC (Register-to-Register)
```text
 31       24 23       16 15        8 7         0
+-----------+-----------+-----------+-----------+
|  Opcode   |  Dst Reg  |   Reg A   |   Reg B   |
+-----------+-----------+-----------+-----------+
```

### 2.2 Format AB_IMM (Immediate & Dispatch)
```text
 31       24 23       16 15                    0
+-----------+-----------+-----------------------+
|  Opcode   |  Dst Reg  |    Immediate UInt16   |
+-----------+-----------+-----------------------+
```

### 2.3 Format BRANCH (Relative Control Flow)
```text
 31       24 23       16 15                    0
+-----------+-----------+-----------------------+
|  Opcode   | Cond Reg  |    Signed Int16 PC    |
+-----------+-----------+-----------------------+
```
Branch offset is relative to `PC + 1`: `target = PC + 1 + offset`.

---

## 3. Core Opcode Index

| Opcode | Hex | Dec | Format | Description |
|---|---|---|---|---|
| `Nop` | `0x00` | 0 | ABC | No operation |
| `Move` | `0x01` | 1 | ABC | `R[dst] = R[a]` |
| `LoadNil` | `0x02` | 2 | ABC | `R[dst] = Nil` |
| `LoadBool` | `0x03` | 3 | ABC | `R[dst] = (b != 0)` |
| `LoadInt` | `0x04` | 4 | AB_IMM | `R[dst] = imm16` (signed) |
| `LoadConst` | `0x05` | 5 | AB_IMM | `R[dst] = ConstPool[imm]` |
| `Add` | `0x0A` | 10 | ABC | `R[dst] = R[a] + R[b]` |
| `Sub` | `0x0B` | 11 | ABC | `R[dst] = R[a] - R[b]` |
| `Mul` | `0x0C` | 12 | ABC | `R[dst] = R[a] * R[b]` |
| `Div` | `0x0D` | 13 | ABC | `R[dst] = R[a] / R[b]` (0 guarded) |
| `Mod` | `0x0E` | 14 | ABC | `R[dst] = R[a] % R[b]` (0 guarded) |
| `Neg` | `0x0F` | 15 | ABC | `R[dst] = -R[a]` |
| `BitAnd` | `0x10` | 16 | ABC | `R[dst] = R[a] & R[b]` |
| `BitOr` | `0x11` | 17 | ABC | `R[dst] = R[a] \| R[b]` |
| `BitXor` | `0x12` | 18 | ABC | `R[dst] = R[a] ^ R[b]` |
| `ShiftLeft` | `0x13` | 19 | ABC | `R[dst] = R[a] << R[b]` |
| `ShiftRight`| `0x1B` | 27 | ABC | `R[dst] = R[a] >> R[b]` |
| `BitNot` | `0x1C` | 28 | ABC | `R[dst] = ~R[a]` |
| `Vec2New` | `0x14` | 20 | ABC | `R[dst] = Vector2(R[a], R[b])` |
| `Vec2GetX` | `0x15` | 21 | ABC | `R[dst] = R[a].x` |
| `Vec2GetY` | `0x16` | 22 | ABC | `R[dst] = R[a].y` |
| `Vec2SetX` | `0x17` | 23 | ABC | `R[dst].x = R[a]` |
| `Vec2SetY` | `0x18` | 24 | ABC | `R[dst].y = R[a]` |
| `Vec2Add` | `0x19` | 25 | ABC | `R[dst] = R[a] + R[b]` |
| `ColorNew` | `0x1A` | 26 | ABC | `R[dst] = RGBA(R[a..a+3])` |
| `Eq` | `0x1E` | 30 | ABC | `R[dst] = (R[a] == R[b])` |
| `Ne` | `0x1F` | 31 | ABC | `R[dst] = (R[a] != R[b])` |
| `Lt` | `0x20` | 32 | ABC | `R[dst] = (R[a] < R[b])` |
| `Le` | `0x21` | 33 | ABC | `R[dst] = (R[a] <= R[b])` |
| `Gt` | `0x22` | 34 | ABC | `R[dst] = (R[a] > R[b])` |
| `Ge` | `0x23` | 35 | ABC | `R[dst] = (R[a] >= R[b])` |
| `Jump` | `0x28` | 40 | BRANCH | `PC += 1 + offset` |
| `JumpIfTrue`| `0x29` | 41 | BRANCH | Branch if `R[cond]` truthy |
| `JumpIfFalse`| `0x2A`| 42 | BRANCH | Branch if `R[cond]` falsy |
| `Call` | `0x32` | 50 | AB_IMM | Call function `imm` |
| `Return` | `0x33` | 51 | ABC | Return value `R[src]` |
| `CallNative`| `0x34`| 52 | AB_IMM | Call hardware service `imm` |
| `SpawnFiber`| `0x3C`| 60 | AB_IMM | Spawn new fiber |
| `Yield` | `0x3D` | 61 | ABC | Yield fiber slice |
| `ResumeFiber`| `0x3E`| 62 | ABC | Resume fiber `R[a]` |
| `Halt` | `0x46` | 70 | ABC | Halt VM & flush output |

---

## 4. Native Services (NativeId)

Invoked via `CallNative base_reg, native_id`:

- **Window & System**: `InitWindow` (1), `CloseWindow` (2), `WindowOpen` (3), `SetTargetFPS` (4), `GetFPS` (5), `GetDeltaTime` (6), `Sleep` (65), `Panic` (99).
- **2D Graphics**: `BeginDrawing` (10), `EndDrawing` (11), `ClearBackground` (12), `DrawRectangle` (20), `DrawCircle` (21), `DrawLine` (22), `DrawTriangle` (23), `DrawText` (24), `LoadTexture` (30), `DrawTexture` (31), `DrawTextureRec` (32), `UnloadTexture` (33), `DrawQuad` (100).
- **3D Graphics**: `BeginMode3D` (25), `EndMode3D` (26), `DrawCube` (27), `DrawCubeWires` (28), `DrawGrid` (29), `DrawMesh` (34).
- **Citrine GL**: `GLBegin` (101), `GLEnd` (102), `GLVertex` (103), `GLColor` (104), `GLTexCoord` (105), `GLPushMatrix` (106), `GLPopMatrix` (107), `GLTranslate` (108), `GLRotate` (109), `GLScale` (110), `GLLoadIdentity` (111).
- **DualShock 2**: `ButtonDown` (40), `ButtonPressed` (41), `ButtonReleased` (42), `GetAnalog` (43), `SetRumble` (44).
- **SPU2 Audio & Video**: `LoadSound` (35), `PlaySound` (36), `StopSound` (37), `LoadVideo` (90), `PlayVideo` (91), `DrawVideoFrame` (92), `VideoFinished` (93), `PauseVideo` (94), `StopVideo` (95).
- **CSP Concurrency**: `FiberId` (66), `FiberAlive` (67), `ChannelNew` (80), `ChannelSend` (81), `ChannelReceive` (82), `ChannelTryReceive` (83), `ChannelCount` (84), `ChannelCapacity` (85).
- **Collections & IO**: `ArrayNew` (120), `ArrayGet` (121), `ArraySet` (122), `ArrayPush` (123), `ArrayPop` (124), `ArraySize` (125), `ArrayClear` (126), `StaticArrayNew` (130), `StaticArrayGet` (131), `StaticArraySet` (132), `StaticArraySize` (133), `MemoryIONew` (140), `MemoryIOWriteByte` (141), `MemoryIOWrite` (142), `MemoryIOPuts` (143), `MemoryIOToS` (144), `MemoryIORewind` (145), `MemoryIOPos` (146), `MemoryIOSize` (147), `MemoryIOClear` (148).
- **Memory, Contexts & Pointers**: `ObjectNew` (150), `ObjectGetField` (151), `ObjectSetField` (152), `StructCopy` (153), `PointerMalloc` (160), `PointerGet` (161), `PointerSet` (162), `PointerOffset` (163), `PointerAddress` (164), `PointerNew` (165), `BoxNew` (166), `BoxUnbox` (167), `PointerFree` (168), `TypeIsA` (170), `TypeAsCast` (171), `ContextSet` (180), `ContextClear` (181), `MemoryStats` (182), `GCCycle` (185).
- **Strings & Lean Regex**: `StringStrip` (186), `StringDowncase` (187), `StringUpcase` (188), `StringIncludes` (189), `RegexNew` (190), `RegexMatch` (191), `StringStartsWith` (192), `StringEndsWith` (193), `StringSplit` (194), `StringConcat` (195), `ToString` (196).

---

## 5. Memory Layout & Safety Canaries

```text
0x00000000 - 0x000FFFFF: PS2 EE Kernel / Bios (1 MB)
0x00100000 - 0x001FFFFF: Citrine ELF .text & .rodata (ROM executable)
0x00200000 - 0x003FFFFF: Citrine Static Buffers & Display Lists
0x00400000 - 0x0043FFFF: Tier 1 Scratch Pool (256 KB, rewound every V-Blank)
0x00440000 - 0x01FFFFFF: Tier 2 Context Arenas & Tier 3 Explicit Heap
0x70000000 - 0x70003FFF: 16 KB Scratchpad RAM (SPRAM)
  - 0x70000000: Canary Sentinel (0xDEADBEEF)
  - 0x70000004: Frame Counter & Timers
  - 0x70000010: SIO2 Controller State Buffers
```
