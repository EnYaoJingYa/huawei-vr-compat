import sys, re
from elftools.elf.elffile import ELFFile
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

path = sys.argv[1]
pat = sys.argv[2]
try:
    start = int(sys.argv[3], 0)
    stop = int(sys.argv[4], 0)
except Exception:
    start = stop = 0

with open(path, 'rb') as f:
    elf = ELFFile(f)
    syms = []
    for secname in ('.dynsym', '.symtab'):
        sec = elf.get_section_by_name(secname)
        if not sec:
            continue
        for s in sec.iter_symbols():
            if s.name and re.search(pat, s.name, re.I):
                syms.append((s.name, s['st_value'], s['st_size']))
    syms = sorted(set(syms), key=lambda x: x[1])
    for name, val, size in syms:
        print(f'\n===== {name} @0x{val:x} size={size} =====')
        if start:
            off, length = start, stop - start
        else:
            off, length = val, max(size, 16)
            if length > 20000:
                length = 20000
        data = None
        for seg in elf.iter_segments():
            if seg['p_type'] == 'PT_LOAD':
                if seg['p_vaddr'] <= off < seg['p_vaddr'] + seg['p_filesz']:
                    data = seg.data()[off - seg['p_vaddr']: off - seg['p_vaddr'] + length]
                    break
        if data is None:
            # maybe section-based
            for sec in elf.iter_sections():
                if sec['sh_addr'] <= off < sec['sh_addr'] + sec['sh_size']:
                    data = sec.data()[off - sec['sh_addr']: off - sec['sh_addr'] + length]
                    break
        if data is None:
            print('  <no data>')
            continue
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        md.detail = False
        for insn in md.disasm(data, off):
            print(f'  {insn.address:08x}: {insn.mnemonic:8s} {insn.op_str}')
