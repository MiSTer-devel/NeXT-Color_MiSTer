#!/usr/bin/env bash
# Replay libdsp DSPBoot() with the Music Kit 4.2 mkmon_A_8k monitor against
# rtl/tc_dsp56k.sv (byte-wide host accesses, as the NS 3.3 kernel driver).
#   bash run.sh            RTL as built without DSP56K_DSPBLK: expect PASS
#                          (boot acks, DM_IDLE $0F0000, then no more words)
#   bash run.sh FI_SUB_IGNORED | FI_SUB_SWAP
#                          AGU subtract fault (fi/dsp56k_agu.sv): the boot
#                          acks pass, then $000000 forever, as on hardware
#                          with DSP56K_DSPBLK=1
set -euo pipefail
cd "$(dirname "$0")"
R=../../../rtl
LOD=${LOD:-../../../../sources/MusicKit42-dl/x/usr/local/lib/dsp/monitor/mkmon_A_8k.lod}
[ -f mkmon_A_8k_flood.script ] || {
	python3 lod2script.py "$LOD" mkmon_A_8k.script
	grep -v -x -e 04000000 -e 00000000 mkmon_A_8k.script > mkmon_A_8k_flood.script
	{ for i in $(seq 64); do echo 04000000; done; echo 00000000; } >> mkmon_A_8k_flood.script
}
if [ $# -gt 0 ]; then
	FILES=("$R/tc_dsp56k.sv" $(ls $R/dsp56k/*.sv | grep -v dsp56k_agu.sv) fi/dsp56k_agu.sv); DEF="+define+$1"; OBJ=obj_$1
else
	FILES=("$R/tc_dsp56k.sv" $R/dsp56k/*.sv); DEF=""; OBJ=obj_dir
fi
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style $DEF -I$R/dsp56k tb_dspboot.sv \
	"${FILES[@]}" --top-module tb_dspboot -j 8 -Mdir $OBJ > $OBJ.log 2>&1 || { tail -20 $OBJ.log; exit 1; }
$OBJ/Vtb_dspboot +script=mkmon_A_8k_flood.script +bytemode=1 | grep -v -e '^ICR' -e '^- '
