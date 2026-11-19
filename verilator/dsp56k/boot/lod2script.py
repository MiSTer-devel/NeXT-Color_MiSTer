#!/usr/bin/env python3
"""Turn a Music Kit .lod monitor into a host script replaying libdsp DSPBoot().

Script lines (hex, one per line): op<<24 | data24
  01 TX word   02 RX expect   03 ICR write   04 RX any (print)   00 end
Order follows dsp-17.12 DSPBoot.c: first P block (on-chip, <= 512 words),
ICR HF0, RX R0 (= count), RX 0 (diag), ICR ~HF0, then each further P block
(MS 4, la, n, data, RX la+n), X blocks (MS 1), Y (MS 2), L (MS 3, n longs,
two words per long; RX la+n), then MS_N (0).
"""
import sys

def parse(fn):
    segs = []
    cur = None
    for line in open(fn):
        t = line.split()
        if not t:
            continue
        if t[0].startswith('_'):
            cur = None
            if t[0] == '_DATA':
                cur = [t[1], int(t[2], 16), []]
                segs.append(cur)
            continue
        if cur is not None and not line.startswith(';'):
            cur[2].extend(int(w, 16) for w in t)
    return segs

def main(fn, out, icr_base=0x01):
    segs = parse(fn)
    ps = [s for s in segs if s[0] == 'P']
    s = []
    TX = lambda w: s.append((1 << 24) | (w & 0xffffff))
    RX = lambda w: s.append((2 << 24) | (w & 0xffffff))
    ICR = lambda v: s.append((3 << 24) | v)
    ICR(icr_base)                      # DSPOpenNoBoot: s_hostInterface->icr = 1
    boot = ps[0]
    assert boot[1] == 0 and len(boot[2]) <= 512
    for w in boot[2]:
        TX(w)
    ICR(icr_base | 0x08)               # DSPClearHF1, DSPSetHF0
    RX(len(boot[2]))                   # R0
    RX(0)                              # fake mem diag
    ICR(icr_base)                      # DSPClearHF0
    for p in ps[1:]:
        TX(4); TX(p[1]); TX(len(p[2]))
        for w in p[2]: TX(w)
        RX(p[1] + len(p[2]))
    for sp, ms in (('X', 1), ('Y', 2)):
        for seg in [x for x in segs if x[0] == sp]:
            TX(ms); TX(seg[1]); TX(len(seg[2]))
            for w in seg[2]: TX(w)
            RX(seg[1] + len(seg[2]))
    for seg in [x for x in segs if x[0] == 'L']:
        n = len(seg[2]) // 2
        TX(3); TX(seg[1]); TX(n)
        for w in seg[2]: TX(w)
        RX(seg[1] + n)
    TX(0)                              # DSP_MS_N
    for _ in range(4):
        s.append(4 << 24)              # DSP messages (expect DM_IDLE $0F0000)
    s.append(0)
    with open(out, 'w') as f:
        for v in s:
            f.write('%08x\n' % v)
    print('%s: %d script entries, boot %d words, segs %s' %
          (out, len(s), len(boot[2]), [(x[0], hex(x[1]), len(x[2])) for x in segs]))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
