import sys
from elftools.elf.elffile import ELFFile
path = sys.argv[1]
addrs = [int(x, 0) for x in sys.argv[2:]]
with open(path, 'rb') as f:
    e = ELFFile(f)
    syms = []
    for sec in e.iter_sections():
        if sec.name in ('.dynsym', '.symtab'):
            for s in sec.iter_symbols():
                if s.name and s['st_value']:
                    syms.append((s['st_value'], s['st_size'], s.name))
    syms.sort()
    for a in addrs:
        prev = None
        for v, sz, n in syms:
            if v <= a < v + max(sz, 1):
                prev = (v, sz, n)
                break
        print(hex(a), '->', prev)
