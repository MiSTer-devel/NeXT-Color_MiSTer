#!/usr/bin/env bash
# Unit test of rtl/tc_scc.sv + rtl/z8530_scc.sv (Z8530 SCC): the ROM POST
# loopback, a 9600-baud character on serial port A, RX + INT_SCC; then the
# NeXTSTEP zs driver emulation (tb_tc_scc_zs.sv), full duplex.
# Build outputs go to $TMPDIR, never into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/tb_tc_scc"
mkdir -p "$OUT"

RTL=("$ROOT/rtl/z8530_scc.sv" "$ROOT/rtl/tc_scc.sv")
TB="$ROOT/verilator/unit/tb_tc_scc.sv"

echo "== lint (verilator)"
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	-Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-SYNCASYNCNET -Wno-PROCASSINIT \
	--top-module tc_scc "${RTL[@]}"

echo "== verilator"
LOG="$OUT/run.log"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY \
	--top-module tb_tc_scc -Mdir "$OUT/obj" -o Vtb "${RTL[@]}" "$TB" >"$OUT/build.log" 2>&1 \
	|| { cat "$OUT/build.log"; exit 1; }
set +e
"$OUT/obj/Vtb" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -ne 0 ] || ! grep -q '^PASS tb_tc_scc' "$LOG"; then
	echo "tb_tc_scc: FAILED (exit $rc)"
	exit 1
fi
echo "tb_tc_scc: OK"

echo "== verilator (clk_sys 25 MHz)"
LOG="$OUT/run25.log"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY -GCLK_HZ=25000000 \
	--top-module tb_tc_scc -Mdir "$OUT/obj25" -o Vtb "${RTL[@]}" "$TB" >"$OUT/build25.log" 2>&1 \
	|| { cat "$OUT/build25.log"; exit 1; }
set +e
"$OUT/obj25/Vtb" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ] || ! grep -q '^PASS tb_tc_scc' "$LOG"; then
	echo "tb_tc_scc (25 MHz): FAILED (exit $rc)"
	exit 1
fi
echo "tb_tc_scc (25 MHz): OK"

echo "== verilator (zs driver emulation)"
LOG="$OUT/run_zs.log"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY \
	--top-module tb_tc_scc_zs -Mdir "$OUT/obj_zs" -o Vtb "${RTL[@]}" "$ROOT/verilator/unit/tb_tc_scc_zs.sv" >"$OUT/build_zs.log" 2>&1 \
	|| { cat "$OUT/build_zs.log"; exit 1; }
set +e
"$OUT/obj_zs/Vtb" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ] || ! grep -q '^PASS tb_tc_scc_zs' "$LOG"; then
	echo "tb_tc_scc_zs: FAILED (exit $rc)"
	exit 1
fi
echo "tb_tc_scc_zs: OK"
