#!/usr/bin/env python3
"""
Transfer swap test — how well does one junction's trained brain run ANOTHER
junction, with zero retraining?

The three corridor agents share an identical interface (46-dim state, 5
protected-left actions), so their checkpoints are drop-in swappable. This
harness evaluates, on the morning scenario:

    native          J0→J0, J1→J1, J2→J2   (the shipped configuration — control)
    J0_everywhere   J0's brain controls all three junctions
    J1_everywhere   J1's brain controls all three junctions
    J2_everywhere   J2's brain controls all three junctions

J0 (Achimota) is the hard junction (fixed-timer baseline 276 s vs ~76 s for
J1/J2), so "J1_everywhere"/"J2_everywhere" measure an easy-junction brain
promoted to a harder junction, and "J0_everywhere" the reverse. Greedy (ε=0),
full 7200 s, multiple seeds. Raw rows → data/transfer_swap_test.csv.

    python scripts/transfer_swap_test.py             # 3 seeds (default)
"""
from __future__ import annotations

import sys
import csv
import time
import shutil
import argparse
import statistics
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai"))
sys.path.insert(0, str(ROOT / "scripts"))

from eval_corridor import evaluate_model  # noqa: E402  (needs sys.path above)

MODEL_DIR = ROOT / "ai" / "checkpoints" / "corridor"
ROUTE = ROOT / "simulation" / "corridor_routes.rou.xml"   # morning (flagship)
OUT_CSV = ROOT / "data" / "transfer_swap_test.csv"
SEEDS = [42, 137, 1024]
BASELINE_CORRIDOR = 143.1   # protected fixed timer, morning (corridor_baselines.csv)

CONFIGS: dict[str, dict[str, str]] = {
    "native":         {"J0": "best_J0", "J1": "best_J1", "J2": "best_J2"},
    "J0_everywhere":  {"J0": "best_J0", "J1": "best_J0", "J2": "best_J0"},
    "J1_everywhere":  {"J0": "best_J1", "J1": "best_J1", "J2": "best_J1"},
    "J2_everywhere":  {"J0": "best_J2", "J1": "best_J2", "J2": "best_J2"},
}


def build_config_dir(tmp_root: Path, name: str, mapping: dict[str, str]) -> Path:
    """Materialise a model dir where best_{jid}.pth is the mapped checkpoint."""
    d = tmp_root / name
    d.mkdir(parents=True, exist_ok=True)
    for jid, src in mapping.items():
        shutil.copyfile(MODEL_DIR / f"{src}.pth", d / f"best_{jid}.pth")
    return d


def main() -> None:
    ap = argparse.ArgumentParser(description="Corridor brain swap-transfer test")
    ap.add_argument("--seeds", type=int, default=len(SEEDS),
                    help="Seeds to use from the fixed list (default all %d)" % len(SEEDS))
    args = ap.parse_args()
    seeds = SEEDS[: max(1, min(args.seeds, len(SEEDS)))]

    t0 = time.time()
    rows: list[dict] = []
    summary: dict[str, dict] = {}

    with tempfile.TemporaryDirectory(prefix="atcs_swap_") as tmp:
        tmp_root = Path(tmp)
        for name, mapping in CONFIGS.items():
            mdir = build_config_dir(tmp_root, name, mapping)
            waits: list[float] = []
            jw: dict[str, list[float]] = {"J0": [], "J1": [], "J2": []}
            for seed in seeds:
                r = evaluate_model(mdir, seed=seed, verbose=False, route=str(ROUTE))
                waits.append(r["corridor_avg_wait"])
                for jid in ("J0", "J1", "J2"):
                    jw[jid].append(r[f"{jid}_avg_wait"])
                rows.append({"config": name, "seed": seed,
                             "corridor_avg_wait_s": f"{r['corridor_avg_wait']:.2f}",
                             "J0_wait_s": f"{r['J0_avg_wait']:.2f}",
                             "J1_wait_s": f"{r['J1_avg_wait']:.2f}",
                             "J2_wait_s": f"{r['J2_avg_wait']:.2f}"})
            summary[name] = {
                "mean": statistics.mean(waits),
                "std": statistics.stdev(waits) if len(waits) > 1 else 0.0,
                "j": {jid: statistics.mean(jw[jid]) for jid in jw},
            }
            s = summary[name]
            print(f"  {name:16} corridor {s['mean']:6.1f}s ±{s['std']:4.1f}  "
                  f"(J0 {s['j']['J0']:6.1f} | J1 {s['j']['J1']:5.1f} | "
                  f"J2 {s['j']['J2']:5.1f})", flush=True)

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["config", "seed", "corridor_avg_wait_s",
                                          "J0_wait_s", "J1_wait_s", "J2_wait_s"])
        w.writeheader()
        w.writerows(rows)

    native = summary["native"]["mean"]
    print("\n  ── Transfer summary (morning scenario, %d seeds) ──" % len(seeds))
    print(f"  {'config':16} {'corridor':>9} {'vs native':>10} {'vs fixed timer':>15}")
    for name, s in summary.items():
        vs_native = (s["mean"] - native) / native * 100.0
        vs_base = (s["mean"] - BASELINE_CORRIDOR) / BASELINE_CORRIDOR * 100.0
        print(f"  {name:16} {s['mean']:8.1f}s {vs_native:>+9.1f}% {vs_base:>+14.1f}%")
    print(f"\n  Raw rows → {OUT_CSV.relative_to(ROOT)}")
    print(f"  Wall time: {(time.time() - t0) / 60.0:.1f} min")


if __name__ == "__main__":
    main()
