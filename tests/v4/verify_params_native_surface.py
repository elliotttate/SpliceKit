"""Reproduce the bounded static selector/ABI evidence. Does not launch/load FCP."""
import re
import struct
import subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
APP=Path('/Applications/Final Cut Pro.app/Contents/Frameworks')
code='\n'.join((ROOT/'Sources'/name).read_text() for name in ['SpliceKitV4Effects.m','SpliceKitV4Parameters.m','SpliceKitV4Keyframes.m'])
selectors=set(re.findall(r'@"([A-Za-z_][A-Za-z0-9_:]*)"',code))
selectors.update(['xChannel','yChannel','zChannel'])
for kind,prefix in [('DoubleValue',''),('IntValue','_'),('BoolValue','')]:
    for edge in ['min','max']:
        for domain in ['Curve','UI']:selectors.add(prefix+edge+domain+kind)
rows=[]
for framework in ['ProChannel','Flexo']:
    binary=APP/f'{framework}.framework'/framework
    p=subprocess.Popen(['otool','-arch','arm64','-ov',str(binary)],stdout=subprocess.PIPE,text=True)
    encoding=''
    for line in p.stdout:
        if line.strip().startswith('types '):encoding=line.strip().split(') ',1)[-1]
        method=re.search(r'([+-])\[([^ ]+) ([^\]]+)\]',line)
        if method and method[3] in selectors and (method[2].startswith(('CHChannel','CHCompound','FFEffect','FFHe','FFAnchored'))):
            rows.append((framework,*method.groups(),encoding))
    if p.wait():raise SystemExit(f'otool failed for {framework}')
output=ROOT/'docs/v4/params-selectors.tsv'
output.write_text('framework\tkind\tclass\tselector\tencoding\n'+'\n'.join('\t'.join(row) for row in rows)+'\n')
# Keep only the small methods that prove native curve-vs-evaluated value semantics
# and the interpolation strategy mapping, not a whole disassembly.
wanted={'-[CHChannelDouble doubleValueAtTime:]:','-[CHChannelDouble curveDoubleValueAtTime:]:',
        '-[CHChannelDouble setCurveDoubleValue:atTime:options:]:',
        '__ZN24OZInterpolatorStrategiesC2Ev:','__ZN24OZInterpolatorStrategies15getInterpolatorEj:'}
binary=APP/'ProChannel.framework/ProChannel'
p=subprocess.Popen(['otool','-arch','arm64','-tvV',str(binary)],stdout=subprocess.PIPE,text=True)
active=False;assembly=[]
for line in p.stdout:
    if line and not line[0].isspace() and line.rstrip().endswith(':'):active=line.strip() in wanted
    if active:assembly.append(line)
if p.wait():raise SystemExit('otool disassembly failed')
# Jump-table address is read from the getInterpolator assembly above for this FCP build.
# Verify the expected address instruction pair before reading its contents.
assert any('add\tx8, x8, #0xfa8' in line for line in assembly)
p=subprocess.Popen(['otool','-arch','arm64','-s','__TEXT','__const',str(binary)],stdout=subprocess.PIPE,text=True)
data={}
for line in p.stdout:
    words=line.split()
    if len(words)>1 and re.fullmatch('[0-9a-f]{16}',words[0]):
        address=int(words[0],16)
        if 0xacfa0<=address<0xad060:
            # otool renders 32-bit numbers; reconstruct each target little-endian word.
            raw=b''.join(struct.pack('<I',int(w,16)) for w in words[1:] if re.fullmatch('[0-9a-f]{8}',w))
            data.update({address+i:byte for i,byte in enumerate(raw)})
if p.wait():raise SystemExit('otool constant table failed')
values=[int.from_bytes(bytes(data[0xacfa8+8*i+j] for j in range(8)),'little') for i in range(22)]
assert values[0]==8 and values[1]==16 and values[21]==112,values
header='FCP 12.4 build 454072 / ProChannel arm64 static evidence; not live acceptance.\nCommands: otool -arch arm64 -ov / -tvV / -s __TEXT __const\nStrategy slots from constructors: 8=OZConstantInterpolator, 16=OZLinearInterpolator, 112=OZSCurveInterpolator.\ngetInterpolator table at 0xacfa8 (22 uint64 offsets):\n'+str(values)+'\nTherefore engine codes: hold=0, linear=1, S-curve ease_in_out=21.\n\n'
(ROOT/'docs/v4/params-channel-arm64.txt').write_text(header+''.join(assembly))
print(f'Wrote {len(rows)} selector ABI records and bounded interpolation/time evidence')
