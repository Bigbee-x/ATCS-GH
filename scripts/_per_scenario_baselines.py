#!/usr/bin/env python3
"""
Foundation for fair grading (2026-06-09).

Runs the fixed-timer baseline (tuned 60/30) on EVERY scenario at full 7200s and
records each one's own avg wait + peak queue + completion. Writes
data/scenario_baselines.csv so training can grade the AI against "beat the timer
on the SAME demand" instead of a single global number (which was measured on a
benign distribution and made the heavy scenarios look like AI failures).

Also flags which scenarios are over the junction's saturation capacity (the
fixed timer itself gridlocks) — those are the recalibration candidates.
"""
import sys, csv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import run_baseline as rb        # noqa: E402  (importing is safe — __main__ guarded)

SCENARIOS = ["off_peak", "weekend_market", "evening_rush",
             "morning_rush", "heavy_emergency"]
OUT = ROOT / "data" / "scenario_baselines.csv"

rows = []
for name in SCENARIOS:
    route = str(ROOT / "simulation" / "scenarios" / f"{name}.rou.xml")
    print(f"\n{'#'*70}\n#  BASELINE: {name}\n{'#'*70}", flush=True)
    try:
        records, _ = rb.run_simulation(gui=False, preset="tuned", route_file=route)
        aw   = [r["avg_wait_time_s"] for r in records]
        q    = [r["total_queue_vehicles"] for r in records]
        comp = records[-1]["completed_vehicles"]
        mean_aw = sum(aw) / len(aw)
        peak_q  = max(q)
        # "saturated" = fixed timer can't hold it (runaway queue / huge wait)
        saturated = mean_aw > 400 or peak_q > 400
        rows.append({"scenario": name, "baseline_avg_wait_s": round(mean_aw, 1),
                     "peak_queue": int(peak_q), "completed": int(comp),
                     "saturated": "YES" if saturated else "no"})
    except Exception as e:                                 # noqa: BLE001
        print(f"[ERROR] {name}: {e}", flush=True)
        rows.append({"scenario": name, "baseline_avg_wait_s": "ERR",
                     "peak_queue": "ERR", "completed": "ERR", "saturated": "ERR"})

with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

print("\n" + "=" * 78)
print("  PER-SCENARIO FIXED-TIMER BASELINES (tuned 60/30, full 7200s)")
print("=" * 78)
print(f"  {'scenario':>17} {'baseline_wait':>14} {'peak_q':>7} {'completed':>10} {'saturated':>10}")
print("  " + "-" * 64)
for r in rows:
    print(f"  {r['scenario']:>17} {str(r['baseline_avg_wait_s'])+'s':>14} "
          f"{r['peak_queue']:>7} {r['completed']:>10} {r['saturated']:>10}")
print("=" * 78)
print(f"  written → {OUT}")
print("  'saturated = YES' → fixed timer itself gridlocks → recalibration target")
print("=" * 78)
