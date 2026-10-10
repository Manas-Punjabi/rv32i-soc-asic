#!/usr/bin/env python3
"""Run the ORFS flow across clock periods and tabulate PPA.

  python3 scripts/sweep.py --periods 12 13 15 20 --out results/sweep.csv

Each point is its own FLOW_VARIANT so runs never overwrite each other, and every
point must come from the same flow setup: changing DONT_USE_CELLS, the repair
margins or the memory configuration re-maps the whole design, so a table that
mixes them is meaningless (see docs/implementation.md).
The configuration actually used is recorded in each row.

Rows whose flow failed are kept with flow_ok=False rather than dropped: a period
the design cannot close at is a result, not a gap.
"""
import argparse, csv, os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from parse_reports import collect

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DESIGN = os.environ.get("DESIGN_NICKNAME", "soc_top")
WORK = os.environ.get("ORFS_WORK", os.path.expanduser("~/ASIC/rv32i-soc-asic-work"))


def run(period, util, mem_words, mem_sram, extra):
    tag = "sram" if mem_sram else "flop"
    variant = f"p{str(period).replace('.', 'p')}_u{util}_{tag}{mem_words}"
    cmd = ["make", "-C", REPO, "asic",
           f"FLOW_VARIANT={variant}",
           f"CLOCK_PERIOD={period}",
           f"CORE_UTILIZATION={util}",
           f"MEM_WORDS={mem_words}",
           f"MEM_SRAM={mem_sram}"] + list(extra)
    print(">>", " ".join(cmd), flush=True)
    ok = subprocess.run(cmd).returncode == 0

    base = os.path.join(WORK, "{}", "sky130hd", DESIGN, variant)
    row = collect(base.format("logs"), base.format("reports"))
    row.update(variant=variant, period_ns=period, util_target=util,
               mem_words=mem_words, mem_sram=mem_sram, flow_ok=ok)
    if row.get("wns_ns") is not None:
        # Achievable period is the target minus the slack, for slack of either
        # sign: positive slack means the design could run faster than the target.
        # Clamping to min(0, wns) instead would report the
        # target frequency instead of the achievable one whenever slack is
        # positive, e.g. 66.7 MHz for the 15 ns point whose period_min is 12.73.
        achievable = period - float(row["wns_ns"])
        row["fmax_mhz_est"] = round(1000.0 / achievable, 2) if achievable > 0 else None
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--periods", nargs="+", type=float, default=[12, 13, 15, 20])
    ap.add_argument("--utils", nargs="+", type=int, default=[35])
    ap.add_argument("--mem-words", type=int, default=1024)
    ap.add_argument("--mem-sram", type=int, default=1)
    ap.add_argument("--extra", nargs="*", default=[])
    ap.add_argument("--out", default="results/sweep.csv")
    a = ap.parse_args()

    rows = [run(p, u, a.mem_words, a.mem_sram, a.extra)
            for p in a.periods for u in a.utils]
    out = a.out if os.path.isabs(a.out) else os.path.join(REPO, a.out)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    keys = sorted({k for r in rows for k in r})
    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {out} ({len(rows)} runs)")
    for r in rows:
        print(f"  {r['variant']:<24} ok={r['flow_ok']} wns={r.get('wns_ns')} "
              f"area={r.get('cell_area_um2')} power={r.get('power_w')} drc={r.get('drc_errors')}")


if __name__ == "__main__":
    main()
