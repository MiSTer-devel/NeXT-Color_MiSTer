# AP68040 in this repository

The pipelined MC68040 by Adam Polkosnik (github.com/apolkosnik/AP68040,
GPL v2 or later). It replaces the older sequential `ap040_core` tree (the
MacQuadra800 / wombat33 copy) and its `wombat_cpu` bundle.

## Where the tree came from

Upstream `apolkosnik/AP68040` `main` at `7117181` (2026-10-19), plus:

- PR #10 (`dead-job-kill`): a discarded DC2 job keeps its kill mark through
  a snoop freeze -- the NeXTSTEP "illegal instruction" panic under DMA;
- `georgemog/AP68040` `dc-writethrough` (upstream draft PR #13): the
  `DC_WRITETHROUGH` parameter, which next_ap68040 sets (DMA reads are not
  snooped on this platform).

`main` already carries the multiply/divide `md_fin` fix and its own fix
(`q_flt`) of the fetch-fault decode deadlock found on this port.

Local change: `ap68040.sv` exports `dbg_vbr`, `dbg_cacr` and `dbg_cmaint`
(as Minimig-AGA's copy does); `rtl/next_ap68040.sv` uses them.

## The NeXT side

`rtl/next_ap68040.sv` puts the core's 68040 bus (BCLK = PCLK = clk_sys,
33 MHz) onto tc_machine's CPU transaction port (the wombat_cpu contract that
wombat_bus32 and the service FSM's fast paths consume), keeps
`rtl/wombat_store_buffer.sv` for posted RAM/VRAM stores, and turns
tc_machine's DMA-write snoop strobes into alternate-master SC = 10 snoops
(the core's own snooper invalidates the cache lines). The MMU's table walks
travel the 68040 bus like any other transfer, so tc_machine's walker port is
tied off.

Area options: the upstream defaults (`FPU_PIPE`, `LOOP_PRED`, `EARLY_RES`,
`DC1_ATC`, `SKID` all 0; upstream quotes under 20,000 ALMs out of context). `NeXT-Color.qsf` turns register retiming off for the CPU instance and
synthesizes it for area.

## Tests

The core's own regression lives in its repository (`tb/run_tests.sh`, the
cputest corpus). Here: the Verilator full-machine sim (`verilator/`) runs the
v74 ROM to the `NeXT>` prompt.
