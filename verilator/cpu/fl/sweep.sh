#!/usr/bin/env bash
# seed sweep of tb_fl: prints the failing runs, then a count
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N=${N:-200}; CYC=${CYC:-400000}
OUT=${OUT:-$HERE/obj} bash "$HERE/run.sh" +cycles=1 >/dev/null 2>&1
nf=0; nr=0
for s in $(seq ${START:-1} $((${START:-1} + N - 1))); do
  for f in ${FL:-8 30}; do for i in ${IRQ:-0 60 400}; do for lat in 1 4; do
    r=$(cd "${OUT:-$HERE/obj}" && ./tb_fl +prog=prog.hex +seed=$s +flush=$f +irq=$i +lat=$lat +cycles=$CYC 2>&1 | grep -E "^(PASS|FAIL)" | head -1)
    nr=$((nr+1))
    case "$r" in FAIL*) nf=$((nf+1)); echo "seed=$s flush=$f irq=$i lat=$lat $r";; esac
  done; done; done
done
echo "runs $nr fails $nf"
