#!/usr/bin/env python3
"""
ATCS-GH | Multi-Seed AI Evaluation (Achimota/Neoplan Junction)
==============================================================
Runs the trained DQN agent across multiple SUMO seeds to produce
confidence intervals for the research paper.

Usage:
    python scripts/eval_multi_seed.py                    # 5 seeds
    python scripts/eval_multi_seed.py --seeds 10         # 10 seeds
    python scripts/eval_multi_seed.py --model ai/best_model.pth
"""

import os
import sys
import csv
import time
import shutil
import argparse
import numpy as np
from pathlib import Path

# -- SUMO / TraCI setup -------------------------------------------------------

def _setup_sumo() -> str:
    home = os.environ.get("SUMO_HOME")
    if home is None:
        try:
            import sumo as _sp
            home = _sp.SUMO_HOME
            os.environ["SUMO_HOME"] = home
        except ImportError:
            pass
    if home is None:
        for c in ["/opt/homebrew/opt/sumo/share/sumo",
                  "/opt/homebrew/share/sumo",
                  "/usr/local/share/sumo",
                  "/usr/share/sumo"]:
            if os.path.isdir(c):
                home = c
                os.environ["SUMO_HOME"] = c
                break
    if home is None:
        sys.exit("[ERROR] SUMO not found.")
    tools = os.path.join(home, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    return home

SUMO_HOME = _setup_sumo()
import traci
import traci.exceptions

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from dqn_agent import DQNAgent
from metrics_logger import MetricsLogger
from traffic_env import (
    TL_ID, INCOMING_EDGES, INCOMING_LANES, EMERGENCY_TYPE,
    NS_THROUGH, NS_LEFT, NS_YELLOW, EW_THROUGH, EW_LEFT, EW_YELLOW,
    NS_ALL, EW_ALL,
    PHASE_NAMES, PHASE_SIGNALS, GREEN_PHASES,
    EDGE_TO_GREENS, ACTION_TO_PHASE, ACTION_NAMES, ACTION_HOLD,
    STATE_SIZE, ACTION_SIZE, NUM_PHASES,
    DECISION_INTERVAL, MIN_GREEN_THROUGH, MIN_GREEN_LEFT, YELLOW_DURATION,
    MAX_QUEUE, MAX_QUEUE_LANE, MAX_SPEED, MAX_WAIT, MAX_PHASE_T,
    WALKING_AREAS, MAX_PED_QUEUE,
)

SIM_DIR      = PROJECT_ROOT / "simulation"
DATA_DIR     = PROJECT_ROOT / "data"
CONFIG_FILE  = SIM_DIR / "intersection.sumocfg"
DEFAULT_MODEL = PROJECT_ROOT / "ai" / "best_model.pth"
SIM_DURATION = 7200

# -- Helpers (mirror run_ai.py) ------------------------------------------------

def find_sumo_binary() -> str:
    for p in [os.path.join(SUMO_HOME, "bin", "sumo"),
              shutil.which("sumo"),
              "/opt/homebrew/bin/sumo", "/usr/local/bin/sumo"]:
        if p and os.path.isfile(p):
            return p
    sys.exit("[ERROR] sumo binary not found")


def build_state(phase, phase_timer, _in_yellow):
    """Build 42-dim state vector from live SUMO data."""
    lane_queues = np.zeros(len(INCOMING_LANES), dtype=np.float32)
    lane_speeds = np.zeros(len(INCOMING_LANES), dtype=np.float32)
    lane_waits  = np.zeros(len(INCOMING_LANES), dtype=np.float32)
    for i, lane_id in enumerate(INCOMING_LANES):
        try:
            lane_queues[i] = float(traci.lane.getLastStepHaltingNumber(lane_id))
            lane_speeds[i] = float(traci.lane.getLastStepMeanSpeed(lane_id))
            lane_waits[i]  = float(traci.lane.getWaitingTime(lane_id))
        except traci.exceptions.TraCIException:
            pass
    approach_queues = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
    for i, edge in enumerate(INCOMING_EDGES):
        try:
            n_lanes = traci.edge.getLaneNumber(edge)
            for idx in range(1, n_lanes):  # skip lane 0 (sidewalk)
                approach_queues[i] += traci.lane.getLastStepHaltingNumber(f"{edge}_{idx}")
        except traci.exceptions.TraCIException:
            pass
    phase_vec = np.zeros(NUM_PHASES, dtype=np.float32)
    phase_vec[phase] = 1.0
    t_norm = np.float32(min(phase_timer / MAX_PHASE_T, 1.0))
    emerg = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
    for i, edge in enumerate(INCOMING_EDGES):
        try:
            for vid in traci.edge.getLastStepVehicleIDs(edge):
                if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                    emerg[i] = 1.0
                    break
        except traci.exceptions.TraCIException:
            pass
    ped_counts = np.zeros(len(WALKING_AREAS), dtype=np.float32)
    for i, wa in enumerate(WALKING_AREAS):
        try:
            ped_counts[i] = float(len(traci.edge.getLastStepPersonIDs(wa)))
        except traci.exceptions.TraCIException:
            pass
    return np.concatenate([
        lane_queues / MAX_QUEUE_LANE, lane_speeds / MAX_SPEED, lane_waits / MAX_WAIT,
        approach_queues / MAX_QUEUE, phase_vec, [t_norm], emerg,
        ped_counts / MAX_PED_QUEUE,
    ]).astype(np.float32)


def check_emergency_preemption(phase, in_yellow, next_green):
    for edge in INCOMING_EDGES:
        try:
            for vid in traci.edge.getLastStepVehicleIDs(edge):
                if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                    continue
                green_options = EDGE_TO_GREENS[edge]
                already_serving = (
                    phase in green_options
                    or (in_yellow and next_green in green_options)
                )
                if not already_serving:
                    return True, green_options[0]
        except traci.exceptions.TraCIException:
            pass
    return False, None


def _can_switch(phase, phase_timer, in_yellow):
    if in_yellow or phase not in GREEN_PHASES:
        return False
    min_green = (MIN_GREEN_LEFT if phase in (NS_LEFT, EW_LEFT) else MIN_GREEN_THROUGH)
    return phase_timer >= min_green


def _get_yellow_for_phase(phase):
    if phase in (NS_THROUGH, NS_LEFT, NS_ALL):
        return NS_YELLOW
    return EW_YELLOW


def _install_ai_tl_program():
    logics = traci.trafficlight.getAllProgramLogics(TL_ID)
    if not logics:
        return
    long_phases = [traci.trafficlight.Phase(1_000_000, p.state) for p in logics[0].phases]
    ai_logic = traci.trafficlight.Logic(
        programID="ai_control", type=0, currentPhaseIndex=0,
        phases=long_phases, subParameter={},
    )
    traci.trafficlight.setProgramLogic(TL_ID, ai_logic)
    traci.trafficlight.setProgram(TL_ID, "ai_control")
    traci.trafficlight.setRedYellowGreenState(TL_ID, PHASE_SIGNALS[NS_THROUGH])


# -- Single-seed evaluation ---------------------------------------------------

def run_one_seed(agent: DQNAgent, seed: int,
                 route_file: str | None = None) -> dict:
    """Run one 7200s evaluation episode with a given SUMO seed."""
    sumo_cmd = [
        find_sumo_binary(),
        "-c", str(CONFIG_FILE),
        "--step-length", "1.0",
        "--no-warnings",
        "--quit-on-end",
        "--seed", str(seed),
    ]
    if route_file is not None:
        sumo_cmd += ["--route-files", str(route_file)]
    traci.start(sumo_cmd)
    _install_ai_tl_program()

    phase = NS_THROUGH
    phase_timer = 0
    in_yellow = False
    yellow_cd = 0
    next_green = EW_THROUGH
    steps_in_block = 0
    logger = MetricsLogger(output_path=DATA_DIR / f"ai_eval_seed{seed}.csv")

    try:
        for step_num in range(1, SIM_DURATION + 1):
            if steps_in_block == 0:
                state = build_state(phase, phase_timer, in_yellow)
                preempt, target = check_emergency_preemption(
                    phase, in_yellow, next_green if in_yellow else None)
                if preempt and target is not None:
                    if target != phase and not in_yellow:
                        yellow_phase = _get_yellow_for_phase(phase)
                        next_green = target
                        traci.trafficlight.setRedYellowGreenState(
                            TL_ID, PHASE_SIGNALS[yellow_phase])
                        phase = yellow_phase
                        in_yellow = True
                        yellow_cd = YELLOW_DURATION
                else:
                    action = agent.select_action(state)
                    if action != ACTION_HOLD and _can_switch(phase, phase_timer, in_yellow):
                        t_phase = ACTION_TO_PHASE[action]
                        if t_phase != phase:
                            yellow_phase = _get_yellow_for_phase(phase)
                            next_green = t_phase
                            traci.trafficlight.setRedYellowGreenState(
                                TL_ID, PHASE_SIGNALS[yellow_phase])
                            phase = yellow_phase
                            in_yellow = True
                            yellow_cd = YELLOW_DURATION

            if in_yellow:
                yellow_cd -= 1
                if yellow_cd <= 0:
                    traci.trafficlight.setRedYellowGreenState(
                        TL_ID, PHASE_SIGNALS[next_green])
                    phase = next_green
                    in_yellow = False
                    phase_timer = 0

            traci.simulationStep()
            phase_timer += 1
            steps_in_block = (steps_in_block + 1) % DECISION_INTERVAL
            logger.step(current_time=float(step_num),
                        tl_phase_name=PHASE_NAMES.get(phase, f"phase_{phase}"))

            if traci.simulation.getMinExpectedNumber() == 0:
                break
    finally:
        traci.close()

    logger.save()
    stats = logger.summary_stats()
    return {
        "seed":       seed,
        "avg_wait":   stats["overall_avg_wait"],
        "peak_queue": stats["peak_queue"],
        "completed":  stats["total_completed"],
        "throughput": stats["avg_throughput"],
    }


# -- Main ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Multi-seed AI evaluation")
    parser.add_argument("--seeds", type=int, default=5, help="Number of seeds (default: 5)")
    parser.add_argument("--model", type=str, default=str(DEFAULT_MODEL))
    parser.add_argument("--scenario", type=str, default=None,
                        help="Demand scenario name (e.g. evening_rush). Uses default routes if not set.")
    args = parser.parse_args()

    model_path = Path(args.model)
    if not model_path.exists():
        sys.exit(f"[ERROR] Model not found: {model_path}")

    agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
    agent.load(model_path)
    agent.set_eval_mode()

    seed_list = [42, 271, 503, 719, 997, 1231, 1567, 1811, 2039, 2281][:args.seeds]

    print("\n" + "=" * 62)
    print("  ATCS-GH -- Multi-Seed AI Evaluation (Achimota Junction)")
    print("=" * 62)
    print(f"  Model : {model_path.name}")
    print(f"  Seeds : {args.seeds}  ->  {seed_list}")
    print("=" * 62)
    print(f"\n  {'Seed':>6}  {'Avg Wait':>9}  {'Peak Q':>7}  {'Completed':>10}  {'Throughput':>11}  {'Time':>6}")
    print("  " + "-" * 58)

    route_file = None
    if args.scenario:
        route_file = str(SIM_DIR / "scenarios" / f"{args.scenario}.rou.xml")

    results = []
    for seed in seed_list:
        t0 = time.time()
        r = run_one_seed(agent, seed, route_file=route_file)
        elapsed = time.time() - t0
        results.append(r)
        print(f"  {seed:>6}  {r['avg_wait']:>8.2f}s  {r['peak_queue']:>7}  "
              f"{r['completed']:>10,}  {r['throughput']:>8.1f} v/m  {elapsed:>5.0f}s")

    waits = [r["avg_wait"] for r in results]
    queues = [r["peak_queue"] for r in results]
    completed = [r["completed"] for r in results]

    mean_w = np.mean(waits)
    std_w = np.std(waits)

    print("\n" + "=" * 62)
    print("  SUMMARY")
    print("=" * 62)
    print(f"  Avg wait time  :  {mean_w:.2f} +/- {std_w:.2f}s  (range: {min(waits):.1f}-{max(waits):.1f})")
    print(f"  Peak queue     :  {np.mean(queues):.1f} +/- {np.std(queues):.1f}")
    print(f"  Completed vehs :  {np.mean(completed):.0f} +/- {np.std(completed):.0f}")
    print()

    baseline_csv = DATA_DIR / "baseline_results.csv"
    if baseline_csv.exists():
        import csv as _csv
        with open(baseline_csv) as f:
            rows = list(_csv.DictReader(f))
        bl_wait = sum(float(r["avg_wait_time_s"]) for r in rows) / len(rows)
        delta = (mean_w - bl_wait) / bl_wait * 100
        print(f"  Baseline avg wait : {bl_wait:.2f}s")
        print(f"  AI improvement    : {abs(delta):.1f}% {'BETTER' if delta < 0 else 'WORSE'}")

    print("=" * 62 + "\n")

    summary_path = DATA_DIR / "eval_multi_seed_summary.csv"
    with open(summary_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["seed", "avg_wait", "peak_queue", "completed", "throughput"])
        w.writeheader()
        w.writerows(results)
    print(f"  Per-seed results -> {summary_path.relative_to(PROJECT_ROOT)}")


if __name__ == "__main__":
    main()
