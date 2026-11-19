#!/usr/bin/env python3
"""Set the NeXT Ethernet MAC in the NeXT-Color boot0.rom from this MiSTer's eth0 MAC.

The NeXT boot ROM carries its own MAC (bytes 8-13), protected by a CRC-32 of
bytes 0-21 stored big-endian at bytes 22-25 (same scheme as Previous'
rom.c:rom_config).  A bad CRC makes the ROM hang (floppy LED flashing).
Every install of the released boot0.rom therefore has the same MAC,
00:00:0f:12:34:56, and two MiSTers running the core on one LAN clash.  This
script gives each MiSTer a unique NeXT MAC: NeXT OUI 00:00:0f + the last 3
bytes of eth0's MAC.

The core reads boot0.rom only when it is loaded, so reload the NeXT core
(or reboot the MiSTer) for a new MAC to take effect.

Usage:
  set_rom_mac.py --check            show MAC/CRC of every NeXT boot0.rom found
  set_rom_mac.py --dry-run          show what would change, write nothing
  set_rom_mac.py                    patch (backup first, atomic write)
  set_rom_mac.py --mac 12:34:57     use these 3 bytes instead of eth0's
  set_rom_mac.py --rom PATH         patch only PATH (repeatable)
  set_rom_mac.py --force            patch even if the existing CRC is bad

Python 3 standard library only (MiSTer has 3.9).
"""

import argparse
import glob
import os
import shutil
import struct
import sys
import tempfile
import time
import zlib

MAC_OFF = 8
MAC_LEN = 6
CRC_LEN_COVERED = 22
CRC_OFF = 22
HDR_LEN = 26
NEXT_OUI = bytes((0x00, 0x00, 0x0F))
ETH_ADDR = "/sys/class/net/eth0/address"

# Same order Main_MiSTer's findPrefixDir() searches for a core's games folder;
# the first boot0.rom found is the one the core actually loads.
SEARCH_ROOTS = (["/media/usb%d/games" % i for i in range(6)]
                + ["/media/network/games", "/media/fat/cifs/games",
                   "/media/fat/games"])


def fmt_mac(b):
    return ":".join("%02x" % x for x in b)


def rom_crc(buf):
    return zlib.crc32(bytes(buf[:CRC_LEN_COVERED])) & 0xFFFFFFFF


def stored_crc(buf):
    return struct.unpack(">I", bytes(buf[CRC_OFF:CRC_OFF + 4]))[0]


def parse_bytes(text, n):
    parts = text.replace("-", ":").split(":")
    if len(parts) != n:
        raise ValueError("expected %d hex bytes, got %r" % (n, text))
    return bytes(int(p, 16) for p in parts)


def eth0_tail():
    with open(ETH_ADDR) as f:
        mac = parse_bytes(f.read().strip(), 6)
    return mac[3:]


def find_roms():
    roms = []
    for root in SEARCH_ROOTS:
        for d in sorted(glob.glob(os.path.join(root, "NeXT*"))):
            p = os.path.join(d, "boot0.rom")
            if os.path.isfile(p):
                roms.append(p)
    return roms


def status_line(path, buf):
    want = stored_crc(buf)
    got = rom_crc(buf)
    ok = "OK" if want == got else "BAD (computed %08x)" % got
    return "%s: MAC %s  CRC %08x %s" % (path, fmt_mac(buf[MAC_OFF:MAC_OFF + MAC_LEN]),
                                        want, ok)


def write_atomic(path, data):
    d = os.path.dirname(os.path.abspath(path))
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(prefix=".boot0.rom.", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


WRITTEN = []


def process(path, tail, args):
    """Return 0 ok/unchanged, 1 error."""
    with open(path, "rb") as f:
        buf = bytearray(f.read())
    if len(buf) < HDR_LEN:
        print("%s: too short (%d bytes), skipped" % (path, len(buf)))
        return 1

    print(status_line(path, buf))
    if args.check:
        return 0 if stored_crc(buf) == rom_crc(buf) else 1

    old_mac = bytes(buf[MAC_OFF:MAC_OFF + MAC_LEN])
    old_crc = stored_crc(buf)
    if old_crc != rom_crc(buf) and not args.force:
        print("  existing CRC invalid, refusing (use --force to override)")
        return 1
    if old_mac[:3] != NEXT_OUI:
        print("  note: OUI %s is not NeXT 00:00:0f, replacing it" % fmt_mac(old_mac[:3]))

    new_mac = NEXT_OUI + tail
    buf[MAC_OFF:MAC_OFF + MAC_LEN] = new_mac
    new_crc = rom_crc(buf)
    buf[CRC_OFF:CRC_OFF + 4] = struct.pack(">I", new_crc)

    if new_mac == old_mac and new_crc == old_crc:
        print("  MAC already %s, nothing to do" % fmt_mac(new_mac))
        return 0

    print("  old: MAC %s  CRC %08x" % (fmt_mac(old_mac), old_crc))
    print("  new: MAC %s  CRC %08x" % (fmt_mac(new_mac), new_crc))
    if args.dry_run:
        print("  dry run, not written")
        return 0

    backup = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, backup)
    print("  backup: %s" % backup)
    write_atomic(path, bytes(buf))

    with open(path, "rb") as f:
        check = f.read()
    if check != bytes(buf) or stored_crc(check) != rom_crc(check):
        print("  ERROR: read-back mismatch; restore from %s" % backup)
        return 1
    print("  written")
    WRITTEN.append(path)
    return 0


def main():
    ap = argparse.ArgumentParser(description="Set the NeXT MAC in boot0.rom from eth0's MAC.")
    ap.add_argument("--rom", action="append", metavar="PATH",
                    help="ROM to patch (repeatable); default: every games/NeXT*/boot0.rom found")
    ap.add_argument("--mac", metavar="XX:XX:XX",
                    help="last 3 MAC bytes to use instead of eth0's")
    ap.add_argument("--dry-run", action="store_true", help="show changes, write nothing")
    ap.add_argument("--check", action="store_true", help="only print current MAC and CRC status")
    ap.add_argument("--force", action="store_true", help="patch even if the existing CRC is invalid")
    args = ap.parse_args()

    roms = args.rom or find_roms()
    if not roms:
        print("no NeXT boot0.rom found under: %s" % ", ".join(SEARCH_ROOTS))
        return 1
    if not args.rom:
        print("active ROM (first in MiSTer search order): %s" % roms[0])

    tail = None
    if not args.check:
        try:
            tail = parse_bytes(args.mac, 3) if args.mac else eth0_tail()
        except (OSError, ValueError) as e:
            print("cannot get MAC bytes: %s" % e)
            return 1
        print("target NeXT MAC: %s (%s)" % (fmt_mac(NEXT_OUI + tail),
                                            "--mac" if args.mac else "from eth0"))

    rc = 0
    for p in roms:
        rc |= process(p, tail, args)
    if WRITTEN:
        print("reload the NeXT core for the new MAC to take effect")
    return rc


if __name__ == "__main__":
    sys.exit(main())
