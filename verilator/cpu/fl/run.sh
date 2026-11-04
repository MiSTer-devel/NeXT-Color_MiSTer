#!/usr/bin/env bash
# Build and run tb_fl.sv (next_ap68040 SNOOP = 2 against flushes and
# level-4 interrupts).  OUT=dir, then the bench's plusargs:
#   bash verilator/cpu/fl/run.sh +seed=3 +cycles=2000000
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../../.."
RTL="$ROOT/rtl"; AP="$RTL/ap68040"
OUT="${OUT:-$HERE/obj}"
mkdir -p "$OUT"
python3 "$HERE/mkprog.py" "$OUT/prog.hex" >/dev/null
if [ ! -x "$OUT/tb_fl" ] || [ -n "$(find "$RTL" "$HERE" -newer "$OUT/tb_fl" -name '*.sv' | head -1)" ]; then
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-INITIALDLY \
		-Wno-BLKLOOPINIT -Wno-MULTIDRIVEN -Wno-COMBDLY -Wno-BLKSEQ -Wno-UNOPTFLAT -Wno-LATCH \
		-Wno-SIDEEFFECT -Wno-WIDTH -Wno-CASEINCOMPLETE --timescale-override 1ns/1ps \
		--x-assign fast --x-initial fast -O2 -j 0 --unroll-count 256 ${DEFS:-} \
		+incdir+"$AP" +incdir+"$AP/fpu" +incdir+"$AP/gen" -I"$RTL" \
		--top-module tb_fl -Mdir "$OUT" -o tb_fl "$HERE/tb_fl.sv" \
		"$RTL/next_ap68040.sv" "$RTL/wombat_store_buffer.sv" \
		"$AP/ap68040_pkg.sv" "$AP/gen/ap68040_upkg.sv" "$AP/ap68040_alu.sv" "$AP/ap68040_alu_slow.sv" \
		"$AP/ap68040_muldiv.sv" "$AP/ap68040_biu.sv" "$AP/ap68040_ram.sv" "$AP/ap68040_atc.sv" \
		"$AP/ap68040_dmu.sv" "$AP/ap68040_predec.sv" "$AP/ap68040_fetch.sv" "$AP/ap68040_decode.sv" \
		"$AP/ap68040_useq.sv" "$AP/fpu/ap040_fpu.v" "$AP/ap68040_fpif.sv" "$AP/ap68040_backend.sv" \
		"$AP/ap68040_snoop.sv" "$AP/ap68040.sv" > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
fi
cd "$OUT" && ./tb_fl +prog="$OUT/prog.hex" "$@"
