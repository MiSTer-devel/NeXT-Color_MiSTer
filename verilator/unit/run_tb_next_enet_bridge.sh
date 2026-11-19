#!/usr/bin/env bash
# Lint rtl/next_enet_bridge.sv (verilator -Wall) and build + run
# verilator/unit/tb_next_enet_bridge.sv.  From anywhere:
#   bash verilator/unit/run_tb_next_enet_bridge.sh
# Build output goes to $OUT (default $TMPDIR/tb_next_enet_bridge).  Exit status
# is non-zero on a build error or a failed check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/tb_next_enet_bridge}"
mkdir -p "$OUT"

echo "== lint: verilator --lint-only -Wall rtl/next_enet_bridge.sv"
verilator --lint-only -Wall -Wno-fatal --top-module next_enet_bridge "$ROOT/rtl/next_enet_bridge.sv"

echo "== build tb_next_enet_bridge"
verilator --binary --timing --timescale 1ns/1ps -Wno-fatal \
	--top-module tb_next_enet_bridge -Mdir "$OUT/obj" -o tb_next_enet_bridge \
	"$ROOT/rtl/next_enet_bridge.sv" "$ROOT/verilator/unit/tb_next_enet_bridge.sv" > "$OUT/build.log" 2>&1 \
	|| { cat "$OUT/build.log"; exit 1; }

echo "== run"
"$OUT/obj/tb_next_enet_bridge"
