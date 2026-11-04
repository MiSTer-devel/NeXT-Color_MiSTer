#!/usr/bin/env python3
"""Hand-assembled 68040 program for tb_fl.sv (no m68k assembler on the
build hosts).  Writes prog.hex: one byte per line, $readmemh, loaded at
offset 0 of the bench's 1 MB RAM (mirrored over the whole address space).

The program mimics NeXTSTEP's syscall path: TRAP #0 -> a handler that
builds a frame, stores callp at -12(a6), then
    movea.l -$c(a6),a0 ; movea.l 4(a0),a0 ; jsr (a0)
(unix_syscall at 0x040a5652).  The bench flushes lines (SNOOP = 2) and
raises level-4 interrupts at random; a JSR that lands in the table
(callp + 4) is the bug.
"""
import sys

BASE = 0x04000000
TABLE = 0x04010000      # 8 entries of {nargs, func}
DATA = 0x04018000       # the functions' scratch lines
MBOX = 0x02000000       # mailbox (noncachable, DTT1)
SSP = 0x0407F000
MMU = int(sys.argv[2]) if len(sys.argv) > 2 else 1
PT = 0x04040000         # 4 page tables (VA $04000000-$040FFFFF), 256 bytes each
ROOT = 0x04044000       # root table; the pointer table follows
PTR = 0x04044200
UTH = 0x04014008       # the 'uthread' a store goes to before the dispatch
NF = 8

mem = bytearray(0x50000)
labels, fix = {}, []
pc = 0


def org(a):
    global pc
    pc = a - BASE


def w(*ws):
    global pc
    for x in ws:
        mem[pc] = (x >> 8) & 0xFF
        mem[pc + 1] = x & 0xFF
        pc += 2


def l(x):
    w((x >> 16) & 0xFFFF, x & 0xFFFF)


def lab(n):
    labels[n] = pc + BASE


def lref(n):            # absolute long to a label
    fix.append(('abs', pc, n))
    l(0)


def bra16(op, n):       # Bcc.W label
    w(op)
    fix.append(('rel', pc, n))
    w(0)


def movel_imm_d(v, d): w(0x203C | (d << 9)); l(v)
def movea_imm_a(v, a): w(0x207C | (a << 9)); l(v)
def movec_d(d, cr): w(0x4E7B, (d << 12) | cr)
def movel_d_abs(d, a): w(0x23C0 | d); l(a)              # move.l Dd,(a).l
def movel_imm_abs(v, a): w(0x23FC); l(v); l(a)          # move.l #v,(a).l
def movel_abs_d(a, d): w(0x2039 | (d << 9)); l(a)       # move.l (a).l,Dd


# ---- vectors
org(BASE)
l(SSP)
l(0)                    # reset PC: fixed below
for v in range(2, 256):
    l(0)


def vec(n, name):
    fix.append(('abs', n * 4, name))


fix.append(('abs', 4, 'start'))
for v in range(2, 256):
    vec(v, 'other_h')
vec(4, 'ill_h')
vec(28, 'irq_h')        # level 4 autovector
vec(32, 'trap_h')       # TRAP #0

# ---- start
org(BASE + 0x400)
lab('start')
movel_imm_d(BASE, 0); movec_d(0, 0x801)                 # VBR
if MMU:
    movel_imm_d(ROOT, 0); movec_d(0, 0x806); movec_d(0, 0x807)   # URP, SRP
    w(0xF518)                                               # pflusha
    movel_imm_d(0x8000, 0); movec_d(0, 0x003)               # TC: E, 4K pages
else:
    movel_imm_d(0x0400C020, 0); movec_d(0, 0x006)       # DTT0 $04xxxxxx copyback
movel_imm_d(0x0200C040, 0); movec_d(0, 0x007)           # DTT1 $02xxxxxx noncachable
if not MMU:
    movel_imm_d(0x0400C000, 0); movec_d(0, 0x004)       # ITT0 $04xxxxxx cachable
movel_imm_d(0x80008000, 0); movec_d(0, 0x002)           # CACR DE IE
w(0x7E00)                                               # moveq #0,d7
w(0x46FC, 0x2000)                                       # move.w #$2000,sr
lab('loop')
w(0x4E40)                                               # trap #0
w(0x5287)                                               # addq.l #1,d7
# dirty a table line: nargs of entry (d7*3)&7
w(0x2007)                                               # move.l d7,d0
w(0xD087, 0xD087)                                       # add.l d7,d0 (x2)  -> 3*d7
w(0x0280); l(7)                                         # andi.l #7,d0
w(0xE788)                                               # lsl.l #3,d0
movea_imm_a(TABLE, 1)
w(0x2387, 0x0000)                                       # move.l d7,(0,a1,d0.w) -- nargs field
movel_d_abs(7, MBOX)                                    # progress
if MMU:
    # every 4th trip: drop the ATCs (a context switch), so the walks run
    w(0x2007)                                           # move.l d7,d0
    w(0x0280); l(3)                                     # andi.l #3,d0
    fix.append(('rel', pc + 2, 'nopf')); w(0x6600, 0)   # bne.w nopf
    w(0xF518)                                           # pflusha
    lab('nopf')
bra16(0x6000, 'loop')

# ---- TRAP #0: unix_syscall's dispatch
lab('trap_h')
w(0x4E56, 0xFFE8)                                       # link a6,#-24
w(0x2007)                                               # move.l d7,d0
w(0x0280); l(NF - 1)                                    # andi.l #7,d0
w(0xE788)                                               # lsl.l #3,d0
movea_imm_a(TABLE, 1)
w(0xD3C0)                                               # adda.l d0,a1
w(0x2D49, 0xFFF4)                                       # move.l a1,-12(a6)
w(0x2D47, 0xFFF8)                                       # move.l d7,-8(a6)
# unix_syscall+0x12a..0x1c0: bsr setjmp; tst.l d0; beq; then the
# uthread's flags (u = -$14(a6), its line flushed by the bench) and the
# dispatch, as the kernel has them
movea_imm_a(UTH, 2)
w(0x2D4A, 0xFFEC)                                       # move.l a2,-20(a6)
fix.append(('rel', pc + 2, 'sj')); w(0x6100, 0)         # bsr.w sj
w(0x4A80)                                               # tst.l d0
w(0x6702)                                               # beq.b +2
w(0x4E71)                                               # nop
w(0x206E, 0xFFEC)                                       # movea.l -$14(a6),a0
w(0x117C, 0x0003, 0x0065)                               # move.b #3,$65(a0)
w(0x206E, 0xFFEC)                                       # movea.l -$14(a6),a0
w(0x4228, 0x006A)                                       # clr.b $6a(a0)
w(0x206E, 0xFFEC)                                       # movea.l -$14(a6),a0
lab('the_clr')
w(0x42A8, 0x0066)                                       # clr.l $66(a0)
w(0x206E, 0xFFF4)                                       # movea.l -12(a6),a0
w(0x2068, 0x0004)                                       # movea.l 4(a0),a0
lab('the_jsr')
w(0x4E90)                                               # jsr (a0)
w(0x4E5E)                                               # unlk a6
w(0x4E73)                                               # rte

# ---- 'setjmp': save registers into the uthread, return 0
lab('sj')
movea_imm_a(UTH + 0x100, 1)
w(0x48D1, 0xFCFC)                                       # movem.l d2-d7/a2-a7,(a1)
w(0x7000)                                               # moveq #0,d0
w(0x4E75)                                               # rts

# ---- the functions: dirty a line each, return
for k in range(NF):
    lab('f%d' % k)
    movel_d_abs(7, DATA + 16 * k)
    # evict: dirty lines in the table's sets (1 KB apart: the same set)
    for j in range(1, 6):
        movel_d_abs(7, TABLE + 16 * (k & 3) + 1024 * j + 4 * (k & 1))
    w(0x7A00 | k)                                       # moveq #k,d5
    w(0x4E75)                                           # rts

# ---- level 4: touch the table and data, acknowledge through the mailbox
lab('irq_h')
w(0x2F00)                                               # move.l d0,-(sp)
movel_abs_d(TABLE + 4, 0)
movel_d_abs(0, DATA + 0x100)
movel_abs_d(MBOX + 0xC, 0)                              # the device's status (I/O read)
movel_d_abs(0, MBOX + 0x1C)                             # a device write
movel_imm_abs(1, MBOX + 4)                              # ack: the bench drops IPL
w(0x201F)                                               # move.l (sp)+,d0
w(0x4E73)

lab('ill_h')
movel_imm_abs(0x0BAD0004, MBOX + 8)
w(0x60FE)
lab('other_h')
movel_imm_abs(0x0BAD00FF, MBOX + 8)
w(0x60FE)

end = pc

# ---- the table: {nargs, func}
org(TABLE)
for k in range(NF):
    l(k)
    fix.append(('abs', pc, 'f%d' % k))
    l(0)

# ---- translation tables: VA = PA over $04000000-$040FFFFF, copyback,
# U and M clear (the walks set them with locked updates)
if MMU:
    org(ROOT)
    for i in range(128):
        l((PTR | 0x2) if i == 2 else 0)
    org(PTR)
    for i in range(128):
        l((PT + 256 * i) | 0x2 if i < 4 else 0)
    org(PT)
    for i in range(256):
        l((0x04000000 + 4096 * i) | 0x20 | 0x1)

for kind, at, n in fix:
    v = labels[n]
    if kind == 'abs':
        mem[at:at + 4] = v.to_bytes(4, 'big')
    else:
        d = v - (at + BASE)
        mem[at:at + 2] = (d & 0xFFFF).to_bytes(2, 'big')

with open(sys.argv[1] if len(sys.argv) > 1 else 'prog.hex', 'w') as f:
    for b in mem:
        f.write('%02x\n' % b)
print('the_jsr %08x trap_h %08x end %08x the_clr %08x' % (labels['the_jsr'], labels['trap_h'], end + BASE, labels['the_clr']))
