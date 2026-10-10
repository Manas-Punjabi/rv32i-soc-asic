#!/usr/bin/env python3
"""Plot a sweep CSV: WNS vs period and area vs achieved Fmax, per SPLIT_MUL.
Usage: plot_sweep.py results/sweep.csv docs/ppa_sweep.png
"""
import csv, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def f(x):
    try: return float(x)
    except (TypeError, ValueError): return None

rows = list(csv.DictReader(open(sys.argv[1])))
out = sys.argv[2] if len(sys.argv) > 2 else "ppa_sweep.png"
groups = {}
for r in rows:
    key = f"N={r.get('N')} SPLIT_MUL={r.get('split_mul', '0')}"
    groups.setdefault(key, []).append(r)

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2))
for key, rs in sorted(groups.items()):
    rs = sorted(rs, key=lambda r: f(r["period_ns"]))
    pts = [(f(r["period_ns"]), f(r.get("wns_ns"))) for r in rs]
    pts = [p for p in pts if p[1] is not None]
    if pts:
        ax1.plot(*zip(*pts), marker="o", label=key)
    pts = [(f(r.get("fmax_mhz_est")), f(r.get("cell_area_um2"))) for r in rs]
    pts = [p for p in pts if None not in p]
    if pts:
        ax2.scatter(*zip(*pts), label=key)
ax1.axhline(0, color="gray", lw=0.8, ls="--")
ax1.set(xlabel="Target clock period (ns)", ylabel="Setup WNS (ns)", title="Timing vs target")
ax2.set(xlabel="Estimated Fmax (MHz)", ylabel="Cell area (µm²)", title="Area vs achieved frequency")
for ax in (ax1, ax2):
    ax.grid(alpha=0.3); ax.legend(fontsize=8)
fig.tight_layout()
fig.savefig(out, dpi=150)
print(f"wrote {out}")
