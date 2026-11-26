import re, glob, os, sys

pats = [p.lower() for p in [
    'pose','ctrl3','dof','slam','quat','imu','gyro','acc','mag','predict',
    'track','hmd','helmet','walle','sensor','fusion','calib','camera','display',
    'mirror','cast','virtual','surface','frame','timestamp','latency','render',
    'eye','lens','distort','projection','openxr','xr','timewarp','reproject',
]]

root = sys.argv[1] if len(sys.argv) > 1 else 'decode/com.huawei.hvrsdkserverapp/assets/arm64-v8a'
outdir = sys.argv[2] if len(sys.argv) > 2 else '分析/out'
os.makedirs(outdir, exist_ok=True)
for f in glob.glob(os.path.join(root, '*.so')):
    d = open(f, 'rb').read()
    ss = set()
    for m in re.finditer(rb'[\x20-\x7e]{5,}', d):
        t = m.group().decode('ascii')
        lt = t.lower()
        if any(p in lt for p in pats):
            ss.add(t)
    out = os.path.join(outdir, os.path.basename(f) + '.kw.txt')
    open(out, 'w', encoding='utf-8').write('\n'.join(sorted(ss)))
    print(os.path.basename(f), len(ss))
