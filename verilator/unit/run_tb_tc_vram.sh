#!/usr/bin/env bash
# Unit test of rtl/tc_vram.sv's CPU beat port against the DDR3 model:
# ack accounting, read-back through the kept line, DDR3 contents, and the
# clk_sys cost of a VRAM longword store with the scan-out idle and running.
# Build outputs go to $TMPDIR, never into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/tb_tc_vram"
mkdir -p "$OUT"

RTL=("$ROOT/rtl/tc_dpram_dc.sv" "$ROOT/rtl/tc_vtiming.sv" "$ROOT/rtl/tc_vram.sv")
TB=("$ROOT/verilator/ddr3_model.sv" "$ROOT/verilator/unit/tb_tc_vram.sv")

echo "== lint (verilator)"
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	-Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-SYNCASYNCNET -Wno-PROCASSINIT \
	--top-module tc_vram "${RTL[@]}"

echo "== verilator"
LOG="$OUT/run.log"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY \
	--top-module tb_tc_vram -Mdir "$OUT/obj" -o Vtb "${RTL[@]}" "${TB[@]}" >"$OUT/build.log" 2>&1 \
	|| { cat "$OUT/build.log"; exit 1; }
set +e
"$OUT/obj/Vtb" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -ne 0 ] || ! grep -q '^PASS tb_tc_vram' "$LOG"; then
	echo "tb_tc_vram: FAILED (exit $rc)"
	exit 1
fi
echo "tb_tc_vram: OK"
