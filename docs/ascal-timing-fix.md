# ascal HDMI timing fix (commit e454794)

Commit `e454794` on `ap68040-bcopy` ("ascal: pipeline two HDMI-clock paths
that fail timing at 98% full") changes `sys/ascal.vhd`, the MiSTer video
scaler. It adds one register stage to two paths in the HDMI clock domain.
Output timing and pixel values do not change. The one exception is a
one-pixel difference on the cycle a video mode's `htotal` changes (see
[Behaviour difference](#behaviour-difference)).

`sys/` is MiSTer framework code, so this is a **local divergence from
upstream**. See [Keeping it when syncing sys/](#keeping-it-when-syncing-sys).

## The problem

By late 2026-11 the core was at about 41.1k of 41.9k ALMs (98 % full). At that
density 6 of 6 seed builds failed setup **only** in the HDMI clock domain
(148.5 MHz, 6.73 ns period), by -0.108 to -0.486 ns. Every other clock passed.

A survey of 70 earlier builds showed HDMI setup slack ranging from +0.64 to
-1.17 ns depending on the fitter seed. The scaler was always marginal, and at
98 % full the fitter could no longer place it close enough to meet timing.
Every failing endpoint was in `sys/ascal.vhd`, in one of two path families.
In both, logic depth was modest and most of the delay was routing.

## Path 1: horizontal polyphase filter (`o_h_poly_t` -> `o_h_poly_pix`)

**Before.** The horizontal scaler pipeline (process `HSCAL`) ran this chain in
one cycle at stage C10:

```
o_h_poly_t (DSP products, 27-bit x 6)
  -> 19-bit add (t.x0(26:8) + t.x1(26:8)) per channel
  -> bound(): saturate to 0..255 (sign bit / overflow check)
  -> o_h_poly_pix (register)
```

using `o_h_poly_pix <= poly_final(o_h_poly_t)`. Then C11 copied `o_h_poly_pix`
into `o_ldw` in the "nearest" and "polyphase" `o_hmode` cases. Of the
~5.9 ns path, about 3 ns was routing.

**After.** `poly_final` is split into two functions, with
`poly_final(t) = poly_bound(poly_sum(t))`:

- `poly_sum(t) : type_poly_sum`, the three 19-bit adds.
- `poly_bound(s) : type_pix`, the three `bound(unsigned(s.x), 15)` saturations.

C10 now registers only the sum:

```vhdl
-- C10 : Sum
o_h_poly_sum <= poly_sum(o_h_poly_t);
```

C11 does the saturate as it loads `o_ldw`:

```vhdl
o_ldw <= poly_bound(o_h_poly_sum);   -- "000" Nearest and OTHERS PolyPhase
```

C11 already wrote `o_ldw` from a mux of interpolators, so the saturate moves
into a stage with spare time and the pipeline gets no longer. `o_ldw` still
gets the same value on the same cycle.

New declarations: record `type_poly_sum` (`r,g,b : signed(18 DOWNTO 0)`) and
signal `o_h_poly_sum`. `o_h_poly_pix` is still declared but no longer driven
or read, and synthesis removes it. The **vertical** filter (`o_v_poly_t`,
`o_v_poly_pix`) still calls `poly_final` in one cycle. It did not appear in
the failing paths.

Cost: 57 extra flip-flops (3 x 19).

## Path 2: OSWEEP counters (`o_hcpt` -> `o_vcpt_pre3` / `o_vcpt`)

**Before.** In the `OSWEEP` process the end-of-line compare drove the
end-of-frame compare in the same cycle:

```vhdl
IF o_ce='1' THEN
  IF o_hcpt+1 < o_htotal THEN            -- 12-bit add + compare
    o_hcpt <= (o_hcpt+1) MOD 4096;
  ELSE
    o_hcpt <= 0;
    ...
    IF o_vcpt_pre3+1 >= o_vtotal THEN    -- second 12-bit add + compare
      o_vcpt_pre3 <= 0;
    ELSIF o_vrr_sync2 THEN
      o_vcpt_pre3 <= o_vsstart;
    ELSE
      o_vcpt_pre3 <= (o_vcpt_pre3+1) MOD 4096;
    END IF;
    o_vcpt_pre2 <= o_vcpt_pre3; ...      -- vcpt pipeline
  END IF;
END IF;
```

Two carry chains plus the enable logic of the `o_vcpt_*` registers had to
fit in one 6.73 ns cycle.

**After.** Two new boolean registers, `o_heol` and `o_veol`, hold both
compares one cycle ahead. The counter update only tests a flip-flop:

```vhdl
o_veol <= (o_vcpt_pre3+1 >= o_vtotal);
IF o_ce='1' THEN
  IF o_heol THEN o_heol <= (1 >= o_htotal);          -- o_hcpt becomes 0
  ELSE           o_heol <= (o_hcpt+2 >= o_htotal);   -- o_hcpt becomes o_hcpt+1
  END IF;
ELSE
  o_heol <= (o_hcpt+1 >= o_htotal);                  -- o_hcpt holds
END IF;

IF o_ce='1' THEN
  IF NOT o_heol THEN ... o_hcpt <= o_hcpt+1
  ELSE               ... o_hcpt <= 0;  IF o_veol THEN o_vcpt_pre3 <= 0 ...
```

At every clock `o_heol` predicts `o_hcpt_next + 1 >= o_htotal` for the value
`o_hcpt` takes after that clock. So when it is used, `o_heol` equals the old
`o_hcpt+1 >= o_htotal`.

`o_veol` is recomputed every clock from the current `o_vcpt_pre3`.
`o_vcpt_pre3` changes only at end of line, and with `htotal >= 2` there is at
least one clock between two ends of line. So `o_veol` has caught up before
its next use.

Assumption: `htotal >= 2`. With `htotal = 1` two ends of line would be
back-to-back and `o_veol` would be one line stale. No real video mode comes
near that.

Cost: 2 flip-flops plus the two compare adders, which now run in parallel
rather than in series.

## Behaviour difference

`o_htotal` and `o_vtotal` are read one clock earlier than before. The output
differs only if one of them changes in that window:

- **`htotal` change.** The first end-of-line decision after the change can
  still use the old `htotal`. If the line shrinks, the counter wraps **one
  pixel later** than upstream. If it grows and the old end of line was already
  flagged, the counter wraps at the old length once. After that wrap, both
  versions are in step again.
- **`vtotal` change** in the single clock before an end of line: the frame
  wrap uses the old `vtotal` for that one line.

Both cases happen only on a video mode switch, when the output is already
re-syncing. In steady state the counters match upstream cycle for cycle
(see [Verification](#verification)).

## Verification

A standalone GHDL testbench compares upstream and patched logic. It lives in
[`sim/ghdl_ascal/`](../sim/ghdl_ascal/README.md), and that README gives the
run commands.

- **Poly:** `bound(t0(26:8)+t1(26:8))` (the old `poly_final`) against
  saturating a registered 19-bit sum (`poly_bound(poly_sum)`). 200k random
  27-bit inputs. The first 2k are small values that land near the clamp edges.
  **0 mismatches.**
- **Counters:** the old and new OSWEEP `o_hcpt`, `o_vcpt_pre3`, `o_vcpt_pre2`,
  `o_vcpt_pre`, `o_vcpt` and `o_vcpt_sync` logic run side by side for 3M clocks
  (178k line ends), with:
  - random `o_ce` (70 %);
  - random `o_vrr_sync2` (5 %);
  - random mode changes (`htotal` 2..61, `vtotal` 1..20, `vsstart` 0..19)
    about every 2k clocks.

  After each mode change the patched model is resynced from the reference,
  because of the one-pixel difference above. **0 mismatches.**
- **Mutants** check that the testbench can fail:
  - `tb_mut`: `o_veol` uses `+2`. Caught, 2,057,527 mismatch cycles.
  - `tb_mut2`: `o_heol` uses `+1` in place of `+2` after an increment. Caught,
    2,903,778 mismatch cycles.

Re-run 2026-11-18 with GHDL 6.0.0 on macOS: same results.

The testbench holds copies of the two counter processes and `bound()`. It
does not instantiate `ascal.vhd`, so it checks the transformation, not the
file. Both versions of `ascal.vhd` were also analysed with GHDL
(`--std=08`) to confirm they compile.

## Build results

All builds use the `bcopy52h` tree (commit `4692321` plus this patch) with
clocks clk_cpu / clk_sys / clk_ram = 52 / 26 / 78 MHz, Quartus 17.0 Lite.

| Seed | HDMI setup slack (before -> after) | Other | ALMs | rbf md5 |
|---|---|---|---|---|
| 7 | -0.271 -> **+0.122** ns | hold +0.112 | 41,126 | ca5f3776 |
| 4 | -0.108 -> **+0.123** ns | clk_cpu +0.694, hold +0.174 | 41,111 | cc1edbf6 |

All clocks pass setup and hold on both seeds. The same seeds failed without
the patch, so the gain comes from the change, not from a lucky placement.

Hardware: the seed 4 build (cc1edbf6) boots on a MiSTer.

After the patch the old `o_h_poly_*` and `o_hcpt` paths drop out of the HDMI
top list. The new worst HDMI paths are:

- `o_acpt4` -> `o_hpixs` (seed 7)
- `o_hacc` -> ascal registers (seed 4)

These are the next candidates if HDMI goes negative again as the device
fills.

## Finding the worst HDMI paths

[`scripts/hdmi_paths.tcl`](../scripts/hdmi_paths.tcl) (a copy of
`~/Development/hdmi_paths.tcl` on the Quartus box) loads a finished compile
and lists setup paths into the HDMI output clock:

```tcl
project_open NeXT-Color -revision NeXT-Color
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set clk [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
report_timing -setup -npaths 200 -detail summary   -to_clock $clk -file hdmi_setup_summary.rpt
report_timing -setup -npaths 3   -detail full_path -to_clock $clk -file hdmi_setup_full.rpt
delete_timing_netlist
project_close
```

Run it from the project directory after the compile finishes (takes about
14 s):

```bash
cd <project dir> && <quartus>/bin/quartus_sta -t scripts/hdmi_paths.tcl
```

- `hdmi_setup_summary.rpt` lists the 200 worst paths (slack, from, to). Group
  them by source register to find path families.
- `hdmi_setup_full.rpt` has the full cell and interconnect breakdown of the 3
  worst. Compare IC (routing) with CELL delay: mostly routing on a full device
  points to adding a pipeline stage, as here, rather than cutting logic.

To report another clock, change the `get_clocks` name. `report_clocks` in
`quartus_sta` lists the names.

**Never run `quartus_sta` while a fit is running on the box.** It has about
3.9 GB free, and a second Quartus process gets the fitter OOM-killed. Check
first with `pgrep -x quartus_fit`.

## Keeping it when syncing sys/

`sys/` comes from the MiSTer framework (Template_MiSTer), and `ascal.vhd` is
shared by every MiSTer core. This core's copy now differs from upstream in the
places marked `-- NeXT-Color:` (5 hunks, about 60 lines):

- the `o_heol` / `o_veol` signals;
- `type_poly_sum`, `o_h_poly_sum`;
- the `poly_sum` / `poly_bound` functions;
- the HSCAL C10/C11 lines;
- the OSWEEP prediction block.

When updating `sys/` from upstream:

1. Diff upstream `ascal.vhd` against `b542ed1:sys/ascal.vhd`, the original
   import. If upstream left HSCAL C10/C11 and OSWEEP alone, re-apply
   `e454794` with `git cherry-pick e454794` or by hand.
2. If upstream changed those regions, re-derive the change. Rule for OSWEEP:
   `o_heol` must equal `(o_hcpt+1 >= o_htotal)` for the `o_hcpt` value that
   is current when it is tested. Then update the counter models in
   `sim/ghdl_ascal/tb_eq.vhd` (process `POLD` = upstream) and re-run it.
3. Rebuild and check HDMI slack with `hdmi_paths.tcl`.

`Readme.md` (the `sys/` switches section) still says `sys/` is stock except
for `MISTER_DISABLE_VGA_OSD`. Add a line about this change the next time
that file is edited.

### Worth offering upstream?

Yes, probably, as a small PR to MiSTer-devel/Template_MiSTer:

- **For:** the change is small and local. It keeps scaler latency and output
  timing, adds about 59 flip-flops, and has an equivalence testbench. Other
  large cores at 90 %+ fill that miss HDMI timing by seed would gain from it.
- **Against:** upstream maintainers are careful with `ascal.vhd` because every
  core uses it. The mode-switch transient is a behaviour change, though not
  a visible one. They may also prefer a different fix. Upstream has not been
  checked for a newer `ascal.vhd` that already changes these paths.

Before offering it, check the current upstream `ascal.vhd` and build one
other core with it. Also decide whether to pipeline the vertical
`poly_final` the same way for symmetry.
