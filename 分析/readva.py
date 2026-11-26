import sys
from elftools.elf.elffile import ELFFile

path = sys.argv[1]
vas = [int(x, 0) for x in sys.argv[2:]]
with open(path, 'rb') as f:
    e = ELFFile(f)
    for va in vas:
        found = False
        for s in e.iter_sections():
            if s['sh_addr'] <= va < s['sh_addr'] + s['sh_size']:
                off = va - s['sh_addr']
                d = s.data()[off:off + 32]
                print(hex(va), s.name, d.hex(), list(d))
                found = True
                break
        if not found:
            for seg in e.iter_segments():
                if seg['p_type'] == 'PT_LOAD' and seg['p_vaddr'] <= va < seg['p_vaddr'] + seg['p_filesz']:
                    off = va - seg['p_vaddr']
                    d = seg.data()[off:off + 32]
                    print(hex(va), 'SEG', d.hex(), list(d))
                    found = True
                    break
        if not found:
            print(hex(va), 'not found')
