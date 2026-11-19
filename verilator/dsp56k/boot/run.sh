#!/usr/bin/env bash
# Replay libdsp DSPBoot() with the Music Kit 4.2 mkmon_A_8k monitor against
# rtl/tc_dsp56k.sv (byte-wide host accesses, as the NS 3.3 kernel driver).
#   bash run.sh            RTL as built without DSP56K_DSPBLK: expect PASS
#                          (boot acks, DM_IDLE $0F0000, then no more words)
#                          then the dsptest array transfers (lod2script.py
#                          xfer): host-message writes to x:5/x:6, and the
#                          HOST_R pseudo-DMA read back: expect PASS
#   bash run.sh FI_SUB_IGNORED | FI_SUB_SWAP
#                          AGU subtract fault (fi/dsp56k_agu.sv): the boot
#                          acks pass, then $000000 forever, as on hardware
#                          with DSP56K_DSPBLK=1
set -euo pipefail
cd "$(dirname "$0")"
R=../../../rtl
LOD=${LOD:-../../../../sources/MusicKit42-dl/x/usr/local/lib/dsp/monitor/mkmon_A_8k.lod}
python3 lod2script.py "$LOD" mkmon_A_8k_flood.script > /dev/null
python3 lod2script.py "$LOD" mkmon_A_8k_xfer.script xfer > /dev/null
if [ $# -gt 0 ]; then
	FILES=("$R/tc_dsp56k.sv" $(ls $R/dsp56k/*.sv | grep -v dsp56k_agu.sv) fi/dsp56k_agu.sv); DEF="+define+$1"; OBJ=obj_$1
else
	FILES=("$R/tc_dsp56k.sv" $R/dsp56k/*.sv); DEF=""; OBJ=obj_dir
fi
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style $DEF -I$R/dsp56k tb_dspboot.sv \
	"${FILES[@]}" --top-module tb_dspboot -j 8 -Mdir $OBJ > $OBJ.log 2>&1 || { tail -20 $OBJ.log; exit 1; }
echo "== boot, DM_IDLE"
$OBJ/Vtb_dspboot +script=mkmon_A_8k_flood.script +bytemode=1 | grep -v -e '^ICR' -e '^- ' -e 'no more DSP'
[ $# -gt 0 ] && exit 0
echo "== array transfers (dsptest x:5 write / read)"
$OBJ/Vtb_dspboot +script=mkmon_A_8k_xfer.script +bytemode=1 | grep -v -e '^ICR' -e '^- ' | sed -n '/0f0000/,$p'
