#!/usr/bin/env python3
"""Turn a Music Kit .lod monitor into a host script replaying libdsp DSPBoot().

Script lines (hex, one per line): op<<24 | data24
  01 TX word   02 RX expect   03 ICR write   04 RX: the one DM_IDLE, then
  no more words   05 host command $80|vec, wait HC clear   06 wait ISR bits
  clear   07 wait ISR bits set   08 check x:<addr> == next line   09 RX any
  (print)   0A RX until message opcode == data   00 end

With a third argument "xfer" the script stops after DM_IDLE and replays the
array transfers of MK dsptest (libdsp DSPWriteIntArray / DSPReadIntArray,
driver path, as MK 4.2 in raw mode does them): HM_SAY_SOMETHING, three
HM_HOST_W writes (x:5, x:5, x:6, checked in the DSP's X RAM), then
HM_HOST_R x:5 with the sys_call host command ($16, SC_R_REQ_0), R_REQ,
HF1, four words of pseudo-DMA read, HC_HOST_R_DONE and its R_DONE message.
Host commands are issued only after TRDY, as libdsp and the kernel do.
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

def symbols(fn):
    sym = {}
    for line in open(fn):
        t = line.split()
        if len(t) == 3 and t[1] == 'I':
            try: sym[t[0].upper()] = int(t[2], 16)
            except ValueError: pass
    return sym

def main(fn, out, mode='', icr_base=0x01):
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
    if mode != 'xfer':
        for _ in range(64):
            s.append(4 << 24)          # DSP messages (expect one DM_IDLE $0F0000)
    else:
        sym = symbols(fn)
        OP = lambda op, v=0: s.append((op << 24) | (v & 0xffffff))
        HM = 0x880000                  # untimed host message marker
        def hc(vec): OP(7, 0x04); OP(5, vec)          # wait TRDY, then HC
        def hm(op, *args):
            for a in args: TX(a)
            TX(HM | sym[op]); hc(0x13); OP(6, 0x08)   # XHM, wait HF2 clear
        RX(sym['DM_IDLE'] << 16)
        hm('HM_SAY_SOMETHING'); OP(9)                 # DM_IAA + version
        for addr, val in ((5, 0xfff800), (5, 0x123456), (6, 0xabcdef)):
            hm('HM_HOST_W', 1, addr, 1)               # x:addr, skip 1
            TX(val); hc(0x14); OP(6, 0x08)            # data, HC_HOST_W_DONE
            OP(8, addr); s.append(val)
        ICR(icr_base)                                 # DSPClearHF1
        hm('HM_HOST_R', 1, 5, 1)
        hc(0x16); TX(sym['SC_R_REQ_0'])               # sys_call: read request
        RX(sym['DM_HOST_R_REQ'] << 16)                # channel 0
        ICR(icr_base | 0x10)                          # DSPSetHF1
        RX(0x123456); RX(0xabcdef); OP(9); OP(9)      # pseudo-DMA words
        hc(0x12)                                      # HC_HOST_R_DONE
        OP(0x0a, sym['DM_HOST_R_DONE'])               # [garbage,] R_DONE
        ICR(icr_base)
    s.append(0)
    with open(out, 'w') as f:
        for v in s:
            f.write('%08x\n' % v)
    print('%s: %d script entries, boot %d words, segs %s' %
          (out, len(s), len(boot[2]), [(x[0], hex(x[1]), len(x[2])) for x in segs]))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else '')
