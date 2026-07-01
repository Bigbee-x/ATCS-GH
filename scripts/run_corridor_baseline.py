#!/usr/bin/env python3
"""
ATCS-GH | Corridor Fixed-Timer Baseline
═════════════════════════════════════════
Runs the 3-junction corridor with fixed-timing signals (no AI).
Provides the performance baseline for comparing against multi-agent DQN.

All 3 junctions use the same protected-left fixed-timing plan (mirrors the
single-junction run_baseline.py "protected" preset). All-green is banned —
permissive lefts deadlock the junction box — so through and left arrows never
green together:
  NS through 40s → y3 → NS left 15s → y3 → EW through 25s → y3 → EW left 10s → y3
  (102s cycle)

Usage:
    python scripts/run_corridor_baseline.py
    python scripts/run_corridor_baseline.py --gui          # Visual mode
    python scripts/run_corridor_baseline.py --offset 22    # Green-wave offset
"""

import os
import sys
import csv
import time
import shutil
import argparse
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))

import numpy as np

# Bootstrap SUMO
from corridor_env import (
    _bootstrap_sumo, JUNCTIONS, JUNCTION_IDS, PHASE_NAMES,
    NS_THROUGH, NS_LEFT, NS_YELLOW, EW_THROUGH, EW_LEFT, EW_YELLOW,
    SIM_DURATION, DECISION_INTERVAL,
)

SUMO_HOME = _bootstrap_sumo()
import traci
import traci.exceptions

SIM_DIR     = PROJECT_ROOT / "simulation"
CONFIG_FILE = SIM_DIR / "corridor.sumocfg"
LOG_DIR     = PROJECT_ROOT / "logs"


def run_baseline(gui: bool = False, offset: float = 0.0,
                 seed: int = 42, route: str | None = None) -> dict:
    """Run fixed-timer baseline for corridor.

    Args:
        gui: Use SUMO GUI
        offset: Green-wave offset in seconds between consecutive junctions.
                0 = all junctions switch simultaneously (no coordination).
                ~22 = ideal green wave for 300m at 50 km/h.
        seed: SUMO random seed
        route: optional route-file path; overrides the one in corridor.sumocfg
               (so a single config can baseline morning / evening / off-peak).
    """
    # Start SUMO
    binary = "sumo-gui" if gui else "sumo"
    bin_path = os.path.join(SUMO_HOME, "bin", binary)
    if not os.path.isfile(bin_path):
        bin_path = shutil.which(binary) or shutil.which("sumo")

    cmd = [
        bin_path, "-c", str(CONFIG_FILE),
        "--step-length", "1.0",
        "--no-warnings", "--quit-on-end",
        "--seed", str(seed),
    ]
    if route:
        cmd += ["-r", str(route)]   # override the route-file in the .sumocfg
    traci.start(cmd)

    # Protected-left fixed-timing plan (mirrors run_baseline.py "protected"
    # preset: NS 40/15, EW 25/10, 3s yellows). Through and left arrows never
    # co-green; all-green (NS_ALL/EW_ALL) is banned — permissive lefts deadlock
    # the junction box. PHASE_PLAN = ordered (phase_constant, duration_seconds).
    YELLOW_DUR = 3
    PHASE_PLAN = [
        (NS_THROUGH, 40),
        (NS_YELLOW,  YELLOW_DUR),
        (NS_LEFT,    15),
        (NS_YELLOW,  YELLOW_DUR),
        (EW_THROUGH, 25),
        (EW_YELLOW,  YELLOW_DUR),
        (EW_LEFT,    10),
        (EW_YELLOW,  YELLOW_DUR),
    ]
    CYCLE_LEN = sum(dur for _, dur in PHASE_PLAN)  # 102s

    # Per-junction timing state
    class TLState:
        def __init__(self, jid: str, phase_offset: float):
            self.jid = jid
            self.cfg = JUNCTIONS[jid]
            # Negative start = green-wave offset. Python's % wraps it back into
            # [0, CYCLE_LEN), so J1/J2 simply run offset / 2·offset behind J0.
            self.timer = -int(phase_offset)
            self.phase = PHASE_NAMES[NS_THROUGH]

        def update(self):
            self.timer += 1
            cycle_pos = self.timer % CYCLE_LEN   # always in [0, CYCLE_LEN)
            acc = 0
            for phase_const, dur in PHASE_PLAN:
                if cycle_pos < acc + dur:
                    traci.trafficlight.setRedYellowGreenState(
                        self.cfg.tl_id, self.cfg.phase_signals[phase_const])
                    self.phase = PHASE_NAMES[phase_const]
                    return
                acc += dur

    # Create TL states with offsets
    tl_states = [
        TLState("J0", 0),
        TLState("J1", offset),
        TLState("J2", offset * 2),
    ]

    # Install AI control to prevent auto-advancing
    for jid in JUNCTION_IDS:
        cfg = JUNCTIONS[jid]
        logics = traci.trafficlight.getAllProgramLogics(cfg.tl_id)
        if logics:
            orig = logics[0]
            long_phases = [
                traci.trafficlight.Phase(1_000_000, p.state)
                for p in orig.phases
            ]
            ai_logic = traci.trafficlight.Logic(
                "baseline_control", 0, 0, long_phases, {}
            )
            traci.trafficlight.setProgramLogic(cfg.tl_id, ai_logic)
            traci.trafficlight.setProgram(cfg.tl_id, "baseline_control")

    # ── Simulation loop ──────────────────────────────────────────────────────
    total_arrived = 0
    wait_samples = {jid: [] for jid in JUNCTION_IDS}
    queue_samples = {jid: [] for jid in JUNCTION_IDS}

    for sim_step in range(1, SIM_DURATION + 1):
        # Update TL timing for each junction
        for tls in tl_states:
            tls.update()

        traci.simulationStep()
        total_arrived += traci.simulation.getArrivedNumber()

        # Sample metrics every DECISION_INTERVAL
        if sim_step % DECISION_INTERVAL == 0:
            for jid in JUNCTION_IDS:
                cfg = JUNCTIONS[jid]
                total_q = 0
                total_w = 0.0
                n_edges = len(cfg.incoming_edges)
                for edge in cfg.incoming_edges:
                    try:
                        n_lanes = traci.edge.getLaneNumber(edge)
                        for idx in range(1, n_lanes):
                            total_q += traci.lane.getLastStepHaltingNumber(f"{edge}_{idx}")
                            total_w += traci.lane.getWaitingTime(f"{edge}_{idx}")
                    except traci.exceptions.TraCIException:
                        pass
                queue_samples[jid].append(total_q)
                wait_samples[jid].append(total_w / max(n_edges, 1))

        if traci.simulation.getMinExpectedNumber() == 0:
            break

    traci.close()

    # ── Results ──────────────────────────────────────────────────────────────
    results = {
        "total_arrived": total_arrived,
        "sim_steps": sim_step,
    }
    all_waits = []
    for jid in JUNCTION_IDS:
        avg_w = float(np.mean(wait_samples[jid])) if wait_samples[jid] else 0.0
        avg_q = float(np.mean(queue_samples[jid])) if queue_samples[jid] else 0.0
        results[f"{jid}_avg_wait"] = avg_w
        results[f"{jid}_avg_queue"] = avg_q
        all_waits.extend(wait_samples[jid])

    results["corridor_avg_wait"] = float(np.mean(all_waits)) if all_waits else 0.0
    return results


BASELINE_CSV = PROJECT_ROOT / "data" / "corridor_baselines.csv"
CSV_FIELDS = ["label", "corridor_avg_wait_s", "J0_wait_s", "J1_wait_s", "J2_wait_s",
              "J0_queue", "J1_queue", "J2_queue", "arrived", "demand_vehph",
              "factor", "seed"]
# Stable display order; unknown labels sort to the end.
_CSV_ORDER = {"corridor_morning": 0, "corridor_evening": 1, "corridor_offpeak": 2}


def _route_demand_vehph(route_path: Path) -> float:
    """Sum of all vehsPerHour flows in a route file (excludes pedestrian perHour)."""
    import re
    txt = Path(route_path).read_text()
    return sum(float(v) for v in re.findall(r'vehsPerHour="([\d.]+)"', txt))


def _upsert_baseline_row(label: str, r: dict, demand: float, factor, seed: int) -> None:
    """Insert/replace the row for `label` in corridor_baselines.csv (by label key)."""
    row = {
        "label": label,
        "corridor_avg_wait_s": f"{r['corridor_avg_wait']:.1f}",
        "J0_wait_s": f"{r['J0_avg_wait']:.1f}",
        "J1_wait_s": f"{r['J1_avg_wait']:.1f}",
        "J2_wait_s": f"{r['J2_avg_wait']:.1f}",
        "J0_queue": f"{r['J0_avg_queue']:.1f}",
        "J1_queue": f"{r['J1_avg_queue']:.1f}",
        "J2_queue": f"{r['J2_avg_queue']:.1f}",
        "arrived": int(round(r["total_arrived"])),
        "demand_vehph": f"{demand:.0f}",
        "factor": "" if factor is None else factor,
        "seed": seed,
    }
    rows = []
    if BASELINE_CSV.exists():
        with open(BASELINE_CSV) as f:
            rows = [x for x in csv.DictReader(f) if x.get("label") != label]
    rows.append(row)
    rows.sort(key=lambda x: _CSV_ORDER.get(x["label"], 99))
    BASELINE_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(BASELINE_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description="Corridor fixed-timer baseline")
    parser.add_argument("--gui", action="store_true", help="Use SUMO GUI")
    parser.add_argument("--offset", type=float, default=0.0,
                        help="Green-wave offset in seconds (default: 0)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--seeds", type=int, default=1,
                        help="Number of seeds to average over")
    parser.add_argument("--route", type=str, default=None,
                        help="Route file (overrides corridor.sumocfg; e.g. a scenario)")
    parser.add_argument("--label", type=str, default=None,
                        help="If set, upsert the result row into corridor_baselines.csv")
    parser.add_argument("--factor", type=str, default=None,
                        help="Demand factor to record in the CSV (provenance only)")
    args = parser.parse_args()

    print("=" * 65)
    print("  ATCS-GH Corridor Baseline (Fixed Timer)")
    print(f"  Offset: {args.offset}s | Seeds: {args.seeds}")
    print("=" * 65)

    all_results = []
    for i in range(args.seeds):
        seed = args.seed + i * 100
        print(f"\n--- Seed {seed} ---")
        r = run_baseline(gui=args.gui, offset=args.offset, seed=seed,
                         route=(str(Path(args.route).resolve()) if args.route else None))
        all_results.append(r)

        print(f"  Arrived: {r['total_arrived']}")
        print(f"  Corridor avg wait: {r['corridor_avg_wait']:.1f}s")
        for jid in JUNCTION_IDS:
            print(f"  {jid}: wait={r[f'{jid}_avg_wait']:.1f}s  "
                  f"queue={r[f'{jid}_avg_queue']:.1f}")

    if args.seeds > 1:
        avg_wait = np.mean([r["corridor_avg_wait"] for r in all_results])
        std_wait = np.std([r["corridor_avg_wait"] for r in all_results])
        print(f"\n=== AVERAGE over {args.seeds} seeds ===")
        print(f"  Corridor avg wait: {avg_wait:.1f}s ± {std_wait:.1f}s")

    if args.label:
        keys = ("corridor_avg_wait", "J0_avg_wait", "J1_avg_wait", "J2_avg_wait",
                "J0_avg_queue", "J1_avg_queue", "J2_avg_queue", "total_arrived")
        ravg = {k: float(np.mean([x[k] for x in all_results])) for k in keys}
        route_path = Path(args.route).resolve() if args.route else (SIM_DIR / "corridor_routes.rou.xml")
        demand = _route_demand_vehph(route_path)
        _upsert_baseline_row(args.label, ravg, demand, args.factor, args.seed)
        print(f"\n  ✓ baseline row '{args.label}' written to {BASELINE_CSV.name} "
              f"(demand {demand:.0f} veh/hr)")


if __name__ == "__main__":
    main()
