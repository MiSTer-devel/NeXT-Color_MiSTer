# GHDL equivalence check for the ascal HDMI timing fix

This testbench checks commit `e454794`, which pipelines two HDMI-clock paths in
`sys/ascal.vhd`. It compares the upstream logic with the patched logic. See
[docs/ascal-timing-fix.md](../../docs/ascal-timing-fix.md).

The testbench stands alone. It holds copies of the OSWEEP counter logic (old
and new) and of `bound()`. It does not instantiate `ascal.vhd`.

| File | What |
|---|---|
| `tb_eq.vhd` | The real check. It compares `poly_final` with `poly_bound(poly_sum)` over 200k random inputs, then runs the old and new counters for 3M clocks with random `o_ce`, VRR sync and mode changes. Expected result: `poly mismatches: 0` and `counter mismatch cycles: 0`. |
| `tb_mut.vhd` | Mutant: `o_veol` uses `+2`. It must report counter mismatches (about 2.06M). |
| `tb_mut2.vhd` | Mutant: `o_heol` uses `+1` in place of `+2`. It must report counter mismatches (about 2.90M). |

The testbench resyncs the new model from the old one after each mode change.
On the cycle `htotal` changes, the patched counter can wrap one pixel off,
and that is expected.

## Run

You need GHDL with VHDL-2008 (tested with GHDL 6.0.0 on macOS). Each
testbench takes a few seconds. Run them from a scratch directory so the build
files stay out of the repo:

```bash
cd "$(mktemp -d)" && for t in tb_eq tb_mut tb_mut2; do ghdl -a --std=08 /path/to/repo/sim/ghdl_ascal/$t.vhd && ghdl -e --std=08 $t && ./$t 2>&1 | grep -E 'poly mismatches|counter mismatch cycles'; done
```

Result on 2026-11-18:

```
tb_eq   poly mismatches: 0   counter mismatch cycles: 0        hcpt=0 cycles 178122
tb_mut  poly mismatches: 0   counter mismatch cycles: 2057527  hcpt=0 cycles 178122
tb_mut2 poly mismatches: 0   counter mismatch cycles: 2903778  hcpt=0 cycles 178122
```

The mutants change only the counter logic, so they still report 0 poly
mismatches. On macOS, `ld` may warn "built for newer 'macOS' version". The
warning is harmless.

To confirm that `ascal.vhd` itself still compiles:

```bash
ghdl -a --std=08 -fsynopsys sys/ascal.vhd
```

GHDL prints `-Whide` warnings for this. Ignore them.

If `ascal.vhd` is synced from upstream again, update process `POLD` in all
three testbenches to match the new upstream OSWEEP logic, and update `PNEW` to
match the re-applied patch.
