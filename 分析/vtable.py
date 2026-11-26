import sys, re
from elftools.elf.elffile import ELFFile
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM

path = sys.argv[1]
table = [int(x, 0) for x in sys.argv[2:]]

with open(path, 'rb') as f:
    elf = ELFFile(f)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True

    def read(va, n):
        for s in elf.iter_sections():
            if s['sh_addr'] <= va < s['sh_addr'] + s['sh_size']:
                return s.data()[va - s['sh_addr']: va - s['sh_addr'] + n]
        for seg in elf.iter_segments():
            if seg['p_type'] == 'PT_LOAD' and seg['p_vaddr'] <= va < seg['p_vaddr'] + seg['p_filesz']:
                return seg.data()[va - seg['p_vaddr']: va - seg['p_vaddr'] + n]
        return b''

    def cstr(va):
        d = read(va, 200)
        e = d.find(b'\0')
        if e < 0:
            e = len(d)
        try:
            return d[:e].decode('utf-8')
        except Exception:
            return d[:e].decode('latin-1')

    for fn in table:
        print(f'\n===== fn @0x{fn:x} =====')
        data = read(fn, 400)
        base = 0
        refs = []
        for insn in md.disasm(data, fn):
            m = insn.mnemonic
            if m == 'adrp':
                base = insn.operands[1].imm
            elif m == 'add' and base:
                try:
                    imm = insn.operands[2].imm
                    tgt = base + imm
                except Exception:
                    continue
                s = cstr(tgt)
                if len(s) >= 4 and all(32 <= ord(c) < 127 for c in s[:4]):
                    refs.append((insn.address, tgt, s))
                base = 0
            elif m in ('bl', 'b', 'ret', 'cbz', 'cbnz', 'b.eq', 'b.ne'):
                base = 0
        for a, t, s in refs[:6]:
            print(f'  {a:08x} -> 0x{t:x}  {s[:110]}')
