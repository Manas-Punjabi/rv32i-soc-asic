#!/usr/bin/env python3
"""Extract PPA metrics from an OpenROAD-flow-scripts run.

Prefers ORFS JSON metrics (logs/**/*.json); falls back to regex on
reports/**/6_finish.rpt. Metric key names vary between ORFS versions,
so JSON keys are matched by pattern rather than exact name.
"""
import argparse, glob, json, os, re, sys

PATTERNS = {
    "wns_ns":          [r"^finish__timing__setup__ws$", r"finish.*setup.*ws"],
    "tns_ns":          [r"^finish__timing__setup__tns$", r"finish.*setup.*tns"],
    "hold_ws_ns":      [r"^finish__timing__hold__ws$", r"finish.*hold.*ws"],
    "cell_area_um2":   [r"^finish__design__instance__area$", r"finish.*instance__area$"],
    "util":            [r"^finish__design__instance__utilization$", r"finish.*utilization$"],
    "power_w":         [r"^finish__power__total$", r"finish.*power__total"],
    "wirelength_um":   [r"route__wirelength$", r"wirelength"],
    "drc_errors":      [r"route__drc_errors$", r"drc_errors"],
}

def load_json_metrics(logdir):
    merged = {}
    for f in sorted(glob.glob(os.path.join(logdir, "**", "*.json"), recursive=True)):
        try:
            with open(f) as fh:
                data = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            merged.update({k: v for k, v in data.items() if not isinstance(v, (dict, list))})
    return merged

def pick(metrics, pats):
    for p in pats:
        rx = re.compile(p)
        for k, v in metrics.items():
            if rx.search(k):
                return v
    return None

def from_rpt(repdir):
    out = {}
    rpts = glob.glob(os.path.join(repdir, "**", "6_finish.rpt"), recursive=True)
    if not rpts:
        return out
    txt = open(rpts[0]).read()
    for key, rx in {
        "wns_ns": r"\bwns\s+(-?[\d.]+)",
        "tns_ns": r"\btns\s+(-?[\d.]+)",
        "cell_area_um2": r"Design area\s+([\d.]+)",
        "util": r"([\d.]+)%\s+utilization",
        "power_w": r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)",
    }.items():
        m = re.search(rx, txt, re.M)
        if m:
            out[key] = float(m.group(1))
    return out

def collect(logdir, repdir):
    metrics = load_json_metrics(logdir)
    res = {k: pick(metrics, p) for k, p in PATTERNS.items()}
    for k, v in from_rpt(repdir).items():
        if res.get(k) is None:
            res[k] = v
    return res

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs", required=True, help="ORFS logs/<platform>/<design>/<variant>")
    ap.add_argument("--reports", required=True, help="ORFS reports/<platform>/<design>/<variant>")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    res = collect(a.logs, a.reports)
    if a.json:
        json.dump(res, sys.stdout, indent=2); print()
    else:
        for k, v in res.items():
            print(f"{k:16s} {v}")

if __name__ == "__main__":
    main()
