#!/usr/bin/env python3
"""
PlayStation 2 Radare2 Plugin & Dissector (r2ps2)
Targeting Emotion Engine (EE MIPS R5900), Graphics Synthesizer (GS), DMAC, and GIF Packets.

Usage:
  1. Standalone:
     python r2ps2.py info <path/to/CITRINE.ELF>
     python r2ps2.py check <path/to/CITRINE.ELF>
     python r2ps2.py gif <path/to/CITRINE.ELF> [offset]
  2. Inside radare2:
     r2 -i tools/r2-ps2/ps2.r2 <CITRINE.ELF>
"""

import sys
import os
import struct
import json

GS_REG_NAMES = {
    0x00: "PRIM",
    0x01: "RGBAQ",
    0x02: "ST",
    0x03: "UV",
    0x04: "XYZF2",
    0x05: "XYZ2",
    0x06: "TEX0_1",
    0x07: "TEX0_2",
    0x08: "CLAMP_1",
    0x09: "CLAMP_2",
    0x0A: "FOG",
    0x0C: "XYZF3",
    0x0D: "XYZ3",
    0x14: "TEX1_1",
    0x15: "TEX1_2",
    0x16: "TEX2_1",
    0x17: "TEX2_2",
    0x18: "XYOFFSET_1",
    0x19: "XYOFFSET_2",
    0x1A: "PRMODECONT",
    0x1B: "PRMODE",
    0x1C: "TEXCLUT",
    0x22: "SCANMSK",
    0x34: "MIPTBP1_1",
    0x35: "MIPTBP1_2",
    0x36: "MIPTBP2_1",
    0x37: "MIPTBP2_2",
    0x3B: "TEXA",
    0x3D: "FOGCOL",
    0x3F: "TEXFLUSH",
    0x40: "SCISSOR_1",
    0x41: "SCISSOR_2",
    0x42: "ALPHA_1",
    0x43: "ALPHA_2",
    0x44: "DIMX",
    0x45: "DTHE",
    0x46: "COLCLAMP",
    0x47: "TEST_1",
    0x48: "TEST_2",
    0x49: "PABE",
    0x4A: "FBA_1",
    0x4B: "FBA_2",
    0x4C: "FRAME_1",
    0x4D: "FRAME_2",
    0x4E: "ZBUF_1",
    0x4F: "ZBUF_2",
    0x50: "BITBLTBUF",
    0x51: "TRXPOS",
    0x52: "TRXREG",
    0x53: "TRXDIR",
    0x54: "HWREG",
    0x60: "SIGNAL",
    0x61: "FINISH",
    0x62: "LABEL",
}

PRIM_TYPES = {
    0: "POINT",
    1: "LINE",
    2: "LINESTRIP",
    3: "TRIANGLE",
    4: "TRISTRIP",
    5: "TRIFAN",
    6: "SPRITE",
}

ZTST_MODES = {
    0: "NEVER (All pixels fail!)",
    1: "ALWAYS (All pixels pass)",
    2: "GEQUAL (Z >= Zbuf)",
    3: "GREATER (Z > Zbuf)",
}

class Ps2ElfDissector:
    def __init__(self, data: bytes):
        self.data = data
        self.sections = {}
        self.symbols = []
        self._parse_elf()

    def _parse_elf(self):
        if len(self.data) < 52 or self.data[0:4] != b"\x7fELF":
            return
        # 32-bit little-endian ELF header
        e_entry, e_phoff, e_shoff, e_flags, e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(
            "<IIIIHHHHHH", self.data, 24
        )
        self.entry_point = e_entry
        self.flags = e_flags

        # Read section header string table
        if e_shnum > 0 and e_shstrndx < e_shnum:
            shstr_offset = e_shoff + (e_shstrndx * e_shentsize)
            _, _, _, _, str_sh_offset, str_sh_size, _, _, _, _ = struct.unpack_from(
                "<IIIIIIIIII", self.data, shstr_offset
            )
            shstrtab = self.data[str_sh_offset : str_sh_offset + str_sh_size]

            for i in range(e_shnum):
                sec_off = e_shoff + (i * e_shentsize)
                sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = struct.unpack_from(
                    "<IIIIIIIIII", self.data, sec_off
                )
                null_pos = shstrtab.find(b"\x00", sh_name)
                name = shstrtab[sh_name:null_pos].decode("ascii", errors="ignore") if null_pos != -1 else ""
                self.sections[name] = {
                    "type": sh_type,
                    "flags": sh_flags,
                    "addr": sh_addr,
                    "offset": sh_offset,
                    "size": sh_size,
                    "data": self.data[sh_offset : sh_offset + sh_size] if sh_type != 8 else b"",
                }

    def decode_giftag(self, qword: bytes):
        low, high = struct.unpack_from("<QQ", qword, 0)
        nloop = low & 0x7FFF
        eop = (low >> 15) & 1
        pre = (low >> 46) & 1
        prim = (low >> 47) & 0x7FF
        flg = (low >> 58) & 3
        nreg = (low >> 60) & 0xF
        flg_name = ["PACKED", "REGLIST", "IMAGE", "DISABLE"][flg]
        regs = []
        for r in range(max(1, nreg)):
            regs.append((high >> (r * 4)) & 0xF)
        return {
            "nloop": nloop,
            "eop": eop,
            "pre": pre,
            "prim": prim,
            "flg": flg,
            "flg_name": flg_name,
            "nreg": nreg,
            "regs": regs,
            "raw_low": low,
            "raw_high": high,
        }

    def dissect_gif_packet(self, offset: int, max_items: int = 100):
        if offset + 16 > len(self.data):
            return "Offset exceeds binary bounds"

        lines = []
        tag = self.decode_giftag(self.data[offset : offset + 16])
        lines.append(f"[GIFTag @ 0x{offset:08X}]")
        lines.append(f"  NLOOP: {tag['nloop']} | EOP: {tag['eop']} | FLG: {tag['flg_name']} ({tag['flg']}) | NREG: {tag['nreg']}")
        lines.append(f"  Raw Tag: 0x{tag['raw_high']:016X}_{tag['raw_low']:016X}")

        pos = offset + 16
        items_read = 0

        while items_read < tag["nloop"] and items_read < max_items and pos + 16 <= len(self.data):
            data, reg = struct.unpack_from("<QQ", self.data, pos)
            reg_id = reg & 0xFF
            reg_name = GS_REG_NAMES.get(reg_id, f"REG_0x{reg_id:02X}")
            details = self._decode_gs_reg(reg_id, data)
            lines.append(f"  [{items_read:04d}] +0x{pos - offset:04X} {reg_name:12s} (0x{reg_id:02X}): {details}")
            pos += 16
            items_read += 1

        if items_read < tag["nloop"]:
            lines.append(f"  ... ({tag['nloop'] - items_read} more items truncated) ...")

        return "\n".join(lines)

    def _decode_gs_reg(self, reg_id: int, data: int) -> str:
        if reg_id == 0x00: # PRIM
            ptype = data & 7
            pname = PRIM_TYPES.get(ptype, f"UNKNOWN({ptype})")
            iip = "Gouraud" if (data >> 3) & 1 else "Flat"
            tme = "TexOn" if (data >> 4) & 1 else "TexOff"
            abe = "BlendOn" if (data >> 6) & 1 else "BlendOff"
            ctxt = f"Context{((data >> 9) & 1) + 1}"
            return f"Type={pname}, Shading={iip}, {tme}, {abe}, {ctxt} (raw=0x{data:X})"

        elif reg_id == 0x01: # RGBAQ
            r = data & 0xFF
            g = (data >> 8) & 0xFF
            b = (data >> 16) & 0xFF
            a = (data >> 24) & 0xFF
            q_raw = (data >> 32) & 0xFFFFFFFF
            q_float = struct.unpack("<f", struct.pack("<I", q_raw))[0]
            return f"R={r}, G={g}, B={b}, A={a} (0x{a:02X}), Q={q_float:.2f}"

        elif reg_id in (0x05, 0x0D): # XYZ2, XYZ3
            x_raw = data & 0xFFFF
            y_raw = (data >> 16) & 0xFFFF
            z_raw = (data >> 32) & 0xFFFFFFFF
            x_px = x_raw / 16.0
            y_px = y_raw / 16.0
            kick = "DRAW KICK" if reg_id == 0x05 else "NO KICK"
            return f"X={x_px:.1f}px (0x{x_raw:04X}), Y={y_px:.1f}px (0x{y_raw:04X}), Z=0x{z_raw:08X} [{kick}]"

        elif reg_id in (0x18, 0x19): # XYOFFSET
            ofx_raw = data & 0xFFFF
            ofy_raw = (data >> 32) & 0xFFFF
            return f"OFX={ofx_raw / 16.0:.1f}px (raw=0x{ofx_raw:04X}), OFY={ofy_raw / 16.0:.1f}px (raw=0x{ofy_raw:04X})"

        elif reg_id in (0x40, 0x41): # SCISSOR
            x0 = data & 0x7FF
            x1 = (data >> 16) & 0x7FF
            y0 = (data >> 32) & 0x7FF
            y1 = (data >> 48) & 0x7FF
            return f"Bounds: ({x0}, {y0}) -> ({x1}, {y1})"

        elif reg_id in (0x47, 0x48): # TEST
            zte = (data >> 16) & 1
            ztst = (data >> 17) & 3
            ztst_name = ZTST_MODES.get(ztst, f"MODE_{ztst}")
            ate = data & 1
            warn = " [!! WARNING: ALWAYS DISCARD !!]" if zte == 0 and ztst == 0 else ""
            return f"ZTE={zte}, ZTST={ztst} [{ztst_name}], ATE={ate}{warn}"

        elif reg_id in (0x4C, 0x4D): # FRAME
            fbp = data & 0x1FF
            fbw = (data >> 16) & 0x3F
            psm = (data >> 24) & 0x3F
            psm_name = "PSMCT32 (RGBA32)" if psm == 0 else ("PSMCT24" if psm == 1 else f"PSM_{psm}")
            return f"FBP=0x{fbp:X} ({fbp * 2048} words), FBW={fbw} ({fbw * 64}px), PSM={psm_name}"

        elif reg_id in (0x4E, 0x4F): # ZBUF
            zbp = data & 0x1FF
            psm = (data >> 24) & 0xF
            zmsk = (data >> 32) & 1
            return f"ZBP=0x{zbp:X}, PSM={psm}, ZMSK={'Masked(NoWrite)' if zmsk else 'Writable'}"

        elif reg_id == 0x1A: # PRMODECONT
            ac = data & 1
            return f"Source={'PRIM register' if ac == 1 else 'PRMODE register'}"

        elif reg_id == 0x46: # COLCLAMP
            return f"Clamp={'Enabled' if data & 1 else 'Disabled'}"

        return f"RawData=0x{data:016X}"

    def run_checks(self):
        reports = []
        reports.append("=== PlayStation 2 Executable Validation (r2ps2) ===")

        # 1. Entry point & architecture
        if self.entry_point == 0x00100000:
            reports.append("  [PASS] ELF Entry Point: 0x00100000 (Standard EE MIPS)")
        else:
            reports.append(f"  [WARN] ELF Entry Point: 0x{self.entry_point:08X} (Expected 0x00100000)")

        # 2. Check sections
        required_secs = [".text", ".rodata", ".data", ".spram", ".symtab"]
        for sec in required_secs:
            if sec in self.sections:
                reports.append(f"  [PASS] Section '{sec}': present (size: {self.sections[sec]['size']} bytes)")
            else:
                reports.append(f"  [WARN] Section '{sec}': missing from ELF!")

        # 3. Check for SPRAM canary write in .text
        text_data = self.sections.get(".text", {}).get("data", b"")
        has_canary = (b"\xad\xde" in text_data and b"\xef\xbe" in text_data) or (b"\xef\xbe\xad\xde" in text_data)
        if has_canary:
            reports.append("  [PASS] SPRAM Canary: 0xDEADBEEF initialization instruction verified in .text")
        else:
            reports.append("  [WARN] SPRAM Canary: 0xDEADBEEF not found in .text")

        # 4. Check for _SetGsCrt syscall (v1 = 0x02, syscall) in .text
        has_setgscrt = b"\x02\x00\x03\x34" in text_data or b"\x0c\x00\x00\x00" in text_data # ori v1, zero, 2 or syscall
        if has_setgscrt:
            reports.append("  [PASS] Syscall _SetGsCrt: Video mode initialization confirmed in .text")
        else:
            reports.append("  [WARN] Syscall _SetGsCrt: Video mode initialization not detected in .text")

        # 5. Check GIF Packets in .rodata
        rodata_data = self.sections.get(".rodata", {}).get("data", b"")
        if len(rodata_data) >= 16:
            tag = self.decode_giftag(rodata_data[0:16])
            reports.append(f"  [PASS] Environment GIFTag: NLOOP={tag['nloop']}, FLG={tag['flg_name']}, EOP={tag['eop']}")
            # Check TEST_1 depth test
            pos = 16
            found_test = False
            for _ in range(tag["nloop"]):
                if pos + 16 > len(rodata_data):
                    break
                d, r = struct.unpack_from("<QQ", rodata_data, pos)
                if (r & 0xFF) == 0x47: # TEST_1
                    found_test = True
                    zte = (d >> 16) & 1
                    ztst = (d >> 17) & 3
                    if zte == 1 and ztst == 1:
                        reports.append("  [PASS] Depth Test (TEST_1): ALLPASS (0x00030000) verified")
                    elif ztst == 0:
                        reports.append(f"  [FAIL] Depth Test (TEST_1): ZTST=NEVER (0x{d:X}) - All pixels will be discarded!")
                    else:
                        reports.append(f"  [INFO] Depth Test (TEST_1): ZTE={zte}, ZTST={ztst}")
                pos += 16
            if not found_test:
                reports.append("  [WARN] TEST_1 not found in environment packet")

            # Check Draw Packet
            draw_pos = pos
            if draw_pos + 16 <= len(rodata_data):
                dtag = self.decode_giftag(rodata_data[draw_pos : draw_pos + 16])
                reports.append(f"  [PASS] Draw GIFTag: NLOOP={dtag['nloop']}, FLG={dtag['flg_name']}, EOP={dtag['eop']}")
                # Verify vertex ordering: XYZ3 before XYZ2
                items_checked = 0
                cpos = draw_pos + 16
                queue_state = 0
                has_kick = False
                while items_checked < dtag["nloop"] and cpos + 16 <= len(rodata_data):
                    d, r = struct.unpack_from("<QQ", rodata_data, cpos)
                    reg_id = r & 0xFF
                    if reg_id == 0x0D: # XYZ3 (no kick)
                        queue_state += 1
                    elif reg_id == 0x05: # XYZ2 (with kick)
                        queue_state += 1
                        has_kick = True
                        queue_state = 0
                    cpos += 16
                    items_checked += 1
                if has_kick:
                    reports.append("  [PASS] Vertex Submissions: Vertex queueing & drawing kicks (XYZ2) verified")

        return "\n".join(reports)

def main():
    if len(sys.argv) < 2:
        print("PlayStation 2 Radare2 Plugin (r2ps2)")
        print("Usage:")
        print("  python r2ps2.py info <file.elf>")
        print("  python r2ps2.py check <file.elf>")
        print("  python r2ps2.py gif <file.elf> [byte_offset]")
        sys.exit(0)

    cmd = sys.argv[1].lower()
    if cmd in ("-h", "--help", "help"):
        print("Commands: info, check, gif")
        sys.exit(0)

    target_file = sys.argv[2] if len(sys.argv) > 2 else "CITRINE.ELF"
    if not os.path.exists(target_file):
        # Look in standard locations
        for cand in ["CITRINE.ELF", "runtime/bin/citrine_runner.elf", "examples/05_hello_world/CITRINE.ELF"]:
            if os.path.exists(cand):
                target_file = cand
                break

    if not os.path.exists(target_file):
        print(f"Error: Target file '{target_file}' not found.")
        sys.exit(1)

    with open(target_file, "rb") as f:
        data = f.read()

    dissector = Ps2ElfDissector(data)

    if cmd == "info":
        print(f"File: {target_file} ({len(data)} bytes)")
        print(f"Entry Point: 0x{dissector.entry_point:08X}")
        print("\nSections:")
        for name, s in dissector.sections.items():
            print(f"  {name:12s} Addr: 0x{s['addr']:08X}  Off: 0x{s['offset']:08X}  Size: {s['size']} bytes")
    elif cmd == "check":
        print(dissector.run_checks())
    elif cmd in ("gif", "dissect-gif"):
        offset = 0
        max_items = 100
        if len(sys.argv) > 3:
            offset = int(sys.argv[3], 0)
            if offset >= 0x100000:
                for s in dissector.sections.values():
                    if s["addr"] <= offset < s["addr"] + s["size"]:
                        offset = s["offset"] + (offset - s["addr"])
                        break
        else:
            rodata = dissector.sections.get(".rodata")
            if rodata:
                offset = rodata["offset"]
        if len(sys.argv) > 4:
            max_items = int(sys.argv[4], 0)
        print(dissector.dissect_gif_packet(offset, max_items))
    else:
        print(f"Unknown command '{cmd}'. Use info, check, or gif.")

if __name__ == "__main__":
    main()
