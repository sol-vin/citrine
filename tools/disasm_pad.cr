require "../src/citrine/iso/pad_runtime_payload"

bytes = Citrine::ISO::PadRuntimePayload.bytes
base = Citrine::ISO::PadRuntimePayload::VADDR

def disasm_block(bytes, base, start_off, size)
  (start_off...start_off + size).step(4) do |pc|
    w = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[pc, 4])
    op = w >> 26
    rs = (w >> 21) & 0x1f
    rt = (w >> 16) & 0x1f
    rd = (w >> 11) & 0x1f
    imm_raw = (w & 0xffff).to_i32
    simm = imm_raw >= 0x8000 ? imm_raw - 0x10000 : imm_raw
    target = w & 0x3ffffff
    
    extra = ""
    case op
    when 0x00
      funct = w & 0x3f
      case funct
      when 0x08 then extra = "jr r%d" % rs
      when 0x09 then extra = "jalr r%d, r%d" % [rd, rs]
      when 0x20 then extra = "add r%d, r%d, r%d" % [rd, rs, rt]
      when 0x21 then extra = "addu r%d, r%d, r%d" % [rd, rs, rt]
      when 0x24 then extra = "and r%d, r%d, r%d" % [rd, rs, rt]
      when 0x25 then extra = "or r%d, r%d, r%d" % [rd, rs, rt]
      else extra = "special funct=0x%02x" % funct
      end
    when 0x02 then extra = "j 0x%08x" % (target << 2)
    when 0x03 then extra = "jal 0x%08x" % (target << 2)
    when 0x04 then extra = "beq r%d, r%d, 0x%08x" % [rs, rt, base + pc + 4 + (simm * 4)]
    when 0x05 then extra = "bne r%d, r%d, 0x%08x" % [rs, rt, base + pc + 4 + (simm * 4)]
    when 0x08 then extra = "addi r%d, r%d, %d" % [rt, rs, simm]
    when 0x09 then extra = "addiu r%d, r%d, %d" % [rt, rs, simm]
    when 0x0f then extra = "lui r%d, 0x%04x" % [rt, imm_raw]
    when 0x23 then extra = "lw r%d, %d(r%d)" % [rt, simm, rs]
    when 0x2b then extra = "sw r%d, %d(r%d)" % [rt, simm, rs]
    end
    
    puts "0x%08x: 0x%08x  %-30s" % [base + pc, w, extra]
  end
end

# Find where "cdrom0:\\S.IRX" is referenced or find string in payload
s_irx_idx = bytes.to_s.index("S.IRX")
puts "S.IRX found in bytes at offset: #{s_irx_idx}"

# Let's inspect around 0x1d00..0x1e00
disasm_block(bytes, base, 0x1d00, 0x100)
