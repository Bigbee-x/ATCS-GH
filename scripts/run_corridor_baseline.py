#!/usr/bin/env python3
"""
ATCS-GH | Corridor Fixed-Timer Baseline
═════════════════════════════════════════
Runs the 3-junction corridor with fixed-timing signals (no AI).
Provides the performance baseline for comparing against multi-agent DQN.

All 3 junctions use the same fixed-timing plan:
  NS green: 60s → yellow: 3s → EW green: 30s → yellow: 3s → repeat

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
    NS_ALL, EW_ALL, NS_YELLOW, EW_YELLOW,
    SIM_DURATION, DECISION_INTERVAL,
)

SUMO_HOME = _bootstrap_sumo()
import traci
import traci.exceptions

SIM_DIR     = PROJECT_ROOT / "simulation"
CONFIG_FILE = SIM_DIR / "corridor.sumocfg"
LOG_DIR     = PROJECT_ROOT / "logs"


def run_baseline(gui: bool = False, offset: float = 0.0,
                 seed: int = 42) -> dict:
    """Run fixed-timer baseline for corridor.

    Args:
        gui: Use SUMO GUI
        offset: Green-wave offset in seconds between consecutive junctions.
                0 = all junctions switch simultaneously (no coordination).
                ~22 = ideal green wave for 300m at 50 km/h.
        seed: SUMO random seed
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
    traci.start(cmd)

    # Fixed timing parameters
    NS_GREEN_DUR = 60
    EW_GREEN_DUR = 30
    YELLOW_DUR   = 3
    CYCLE_LEN    = NS_GREEN_DUR + YELLOW_DUR + EW_GREEN_DUR + YELLOW_DUR  # 96s

    # Per-junction timing state
    class TLState:
        def __init__(self, jid: str, phase_offset: float):
            self.jid = jid
            self.cfg = JUNCTIONS[jid]
            self.timer = -int(phase_offset)  # negative = delayed start
            self.phase = "ns_green"
            self.phase_timer = 0

        def update(self):
            self.timer += 1
            cycle_pos = self.timer % CYCLE_LEN
            if cycle_pos < 0:
                # Haven't started yet (offset delay)
                sig = self.cfg.phase_signals[NS_ALL]
                traci.trafficlight.setRedYellowGreenState(self.cfg.tl_id, sig)
                return

            if cycle_pos < NS_GREEN_DUR:
                sig = self.cfg.phase_signals[NS_ALL]
                self.phase = "ns_green"
            elif cycle_pos < NS_GREEN_DUR + YELLOW_DUR:
                sig = self.cfg.phase_signals[NS_YELLOW]
                self.phase = "ns_yellow"
            elif cycle_pos < NS_GREEN_DUR + YELLOW_DUR + EW_GREEN_DUR:
                sig = self.cfg.phase_signals[EW_ALL]
                self.phase = "ew_green"
            else:
                sig = self.cfg.phase_signals[EW_YELLOW]
                self.phase = "ew_yellow"

            traci.trafficlight.setRedYellowGreenState(self.cfg.tl_id, sig)

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


def main():
    parser = argparse.ArgumentParser(description="Corridor fixed-timer baseline")
    parser.add_argument("--gui", action="store_true", help="Use SUMO GUI")
    parser.add_argument("--offset", type=float, default=0.0,
                        help="Green-wave offset in seconds (default: 0)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--seeds", type=int, default=1,
                        help="Number of seeds to average over")
    args = parser.parse_args()

    print("=" * 65)
    print("  ATCS-GH Corridor Baseline (Fixed Timer)")
    print(f"  Offset: {args.offset}s | Seeds: {args.seeds}")
    print("=" * 65)

    all_results = []
    for i in range(args.seeds):
        seed = args.seed + i * 100
        print(f"\n--- Seed {seed} ---")
        r = run_baseline(gui=args.gui, offset=args.offset, seed=seed)
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


if __name__ == "__main__":
    main()
