#!/usr/bin/env python3
"""Minimal ELF symbol/string dumper (no external deps)."""
import sys, struct, re

def u16(b,o): return struct.unpack_from('<H',b,o)[0]
def u32(b,o): return struct.unpack_from('<I',b,o)[0]
def u64(b,o): return struct.unpack_from('<Q',b,o)[0]

def parse(path, mode='sym'):
    d=open(path,'rb').read()
    if d[:4]!=b'\x7fELF': raise SystemExit('not elf')
    is64=d[4]==2
    le=d[5]==1
    if not le: raise SystemExit('be unsupported')
    e_shoff=u64(d,0x28) if is64 else u32(d,0x20)
    e_shentsize=u16(d,0x3A) if is64 else u16(d,0x2E)
    e_shnum=u16(d,0x3C) if is64 else u16(d,0x30)
    e_shstrndx=u16(d,0x3E) if is64 else u16(d,0x32)
    secs=[]
    for i in range(e_shnum):
        o=e_shoff+i*e_shentsize
        if is64:
            name,typ,flags,addr,off,size,link,info,align,entsize=struct.unpack_from('<IIQQQQIIQQ',d,o)
        else:
            name,typ,flags,addr,off,size,link,info,align,entsize=struct.unpack_from('<IIIIIIIIII',d,o)
        secs.append(dict(name=name,type=typ,flags=flags,addr=addr,off=off,size=size,link=link,info=info,entsize=entsize))
    shstr=secs[e_shstrndx]
    def sname(n): 
        e=d.index(b'\0',shstr['off']+n); return d[shstr['off']+n:e].decode('utf-8','replace')
    for s in secs: s['sname']=sname(s['name'])
    out={}
    for s in secs:
        if s['type'] in (2,11): # SYMTAB/DYNSYM
            strtab=secs[s['link']]
            res=[]
            cnt=s['size']//s['entsize']
            for i in range(cnt):
                o=s['off']+i*s['entsize']
                if is64:
                    name,info,other,shndx,value,size=struct.unpack_from('<IBBHQQ',d,o)
                else:
                    name,value,size,info,other,shndx=struct.unpack_from('<IIIBBH',d,o)
                bind=info>>4; typ=info&0xf
                if name==0: continue
                e=d.index(b'\0',strtab['off']+name)
                nm=d[strtab['off']+name:e].decode('utf-8','replace')
                res.append((nm,value,size,typ,bind,shndx))
            out[s['sname']]=res
    return d,secs,out

def main():
    path=sys.argv[1]
    pat=sys.argv[2] if len(sys.argv)>2 else None
    d,secs,out=parse(path)
    print(f'== {path} ==')
    for k,v in out.items():
        print(f'[{k}] {len(v)} symbols')
        for nm,val,size,typ,bind,shndx in v:
            if pat and not re.search(pat,nm,re.I): continue
            print(f'{val:08x} {size:6d} {typ} {bind} {nm}')
    if 'strings' in sys.argv:
        for s in secs:
            if s['type']==1 and (s['flags']&2):  # STRTAB
                blob=d[s['off']:s['off']+s['size']]
                for m in re.finditer(rb'[ -~]{4,}',blob):
                    t=m.group().decode()
                    if pat and not re.search(pat,t,re.I): continue
                    print('STR',t)

if __name__=='__main__': main()
