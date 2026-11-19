#!/usr/bin/env bash
# Build and run the differential test of rtl/dsp56k/dsp56k_core.sv against
# Previous's DSP56001 interpreter (Main_MiSTer branch with support/next/dsp56k,
# e.g. ../Main_MiSTer-softdsp).
#   bash verilator/dsp56k/diff/run_diff.sh [nseeds] [ninsn] [seed0]
# Env: MAIN (Main_MiSTer checkout), OUT (build dir, default /tmp/tb_dsp56k_diff),
#      DEFS (extra verilator -D options).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MAIN="${MAIN:-$ROOT/../Main_MiSTer-softdsp}"
DSPC="$MAIN/support/next/dsp56k"
[ -f "$DSPC/dsp_cpu.c" ] || { echo "no DSP C core at $DSPC (set MAIN)"; exit 1; }
OUT="${OUT:-/tmp/tb_dsp56k_diff}"
mkdir -p "$OUT/c"
OBJS=""
for f in dsp_core dsp_cpu dsp_disasm; do
	cc -O2 -std=gnu99 -w -I"$DSPC" -c -o "$OUT/c/$f.o" "$DSPC/$f.c"
	OBJS="$OBJS $OUT/c/$f.o"
done
verilator --cc --exe --build -j 8 -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --public-flat-rw ${DEFS:-} \
	--top-module dsp56k_core -Mdir "$OUT/obj" -o tb_diff \
	-I"$ROOT/rtl/dsp56k" \
	-CFLAGS "-I$DSPC -O2" -LDFLAGS "$OBJS" \
	"$ROOT/rtl/dsp56k/dsp_ram.sv" "$ROOT/rtl/dsp56k/dsp56k_rom.sv" \
	"$ROOT/rtl/dsp56k/dsp56k_alu.sv" "$ROOT/rtl/dsp56k/dsp56k_dec.sv" "$ROOT/rtl/dsp56k/dsp56k_agu.sv" \
	"$ROOT/rtl/dsp56k/dsp56k_core.sv" \
	"$ROOT/verilator/dsp56k/diff/tb_diff.cpp" > "$OUT/build.log" 2>&1 \
	|| { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/obj/tb_diff" "$@"
