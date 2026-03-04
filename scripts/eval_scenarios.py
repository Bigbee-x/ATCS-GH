#!/usr/bin/env python3
"""
ATCS-GH | Cross-Scenario Evaluation (Achimota/Neoplan Junction)
================================================================
Tests the trained DQN agent AND fixed-timer baseline across multiple
demand scenarios to measure generalisation.

Usage:
    python scripts/eval_scenarios.py                  # All scenarios, 3 seeds
    python scripts/eval_scenarios.py --seeds 5        # 5 seeds per scenario
    python scripts/eval_scenarios.py --ai-only        # Skip baseline runs
    python scripts/eval_scenarios.py --baseline-only  # Skip AI runs
"""

import os
import sys
import csv
import time
import shutil
import argparse
import numpy as np
from pathlib import Path

# ── SUMO / TraCI bootstrapping ────────────────────────────────────────────────

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
)

SIM_DIR      = PROJECT_ROOT / "simulation"
SCENARIO_DIR = SIM_DIR / "scenarios"
DATA_DIR     = PROJECT_ROOT / "data"
CONFIG_FILE  = SIM_DIR / "intersection.sumocfg"
DEFAULT_MODEL = PROJECT_ROOT / "ai" / "best_model.pth"
SIM_DURATION = 7200

# Baseline fixed-timer signals (same as run_baseline.py)
BASELINE_SIGNALS = {
    "NS_GREEN":  "GGGGrrrGGGGrrrr",
    "NS_YELLOW": "yyyyrrryyyyrrrr",
    "EW_GREEN":  "rrrrGGGrrrrGGGG",
    "EW_YELLOW": "rrrryyyrrrryyyy",
}
BASELINE_NS_GREEN = 60
BASELINE_EW_GREEN = 30
BASELINE_YELLOW   = 3

SEED_LIST = [42, 271, 503, 719, 997, 1231, 1567, 1811, 2039, 2281]

SCENARIO_NAMES = [
    "morning_rush",
    "evening_rush",
    "off_peak",
    "weekend_market",
    "heavy_emergency",
]


# ── SUMO binary ──────────────────────────────────────────────────────────────

def find_sumo_binary() -> str:
    for p in [os.path.join(SUMO_HOME, "bin", "sumo"),
              shutil.which("sumo"),
              "/opt/homebrew/bin/sumo", "/usr/local/bin/sumo"]:
        if p and os.path.isfile(p):
            return p
    sys.exit("[ERROR] sumo binary not found")


# ══════════════════════════════════════════════════════════════════════════════
# AI AGENT EVALUATION
# ══════════════════════════════════════════════════════════════════════════════

def build_state(phase, phase_timer, _in_yellow):
    """Build 38-dim state vector from live SUMO data."""
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
            for idx in range(n_lanes):
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
    return np.concatenate([
        lane_queues / MAX_QUEUE_LANE, lane_speeds / MAX_SPEED, lane_waits / MAX_WAIT,
        approach_queues / MAX_QUEUE, phase_vec, [t_norm], emerg,
    ]).astype(np.float32)


def _check_emergency(phase, in_yellow, next_green):
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


def _get_yellow(phase):
    return NS_YELLOW if phase in (NS_THROUGH, NS_LEFT, NS_ALL) else EW_YELLOW


def _install_ai_tl():
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


def run_ai_episode(agent: DQNAgent, seed: int, route_file: str,
                   scenario_name: str = "") -> dict:
    """Run one AI-controlled episode and return metrics."""
    sumo_cmd = [
        find_sumo_binary(),
        "-c", str(CONFIG_FILE),
        "--step-length", "1.0",
        "--no-warnings", "--quit-on-end",
        "--seed", str(seed),
        "--route-files", str(route_file),
    ]
    traci.start(sumo_cmd)
    _install_ai_tl()

    phase = NS_THROUGH
    phase_timer = 0
    in_yellow = False
    yellow_cd = 0
    next_green = NS_THROUGH
    steps_in_block = 0
    logger = MetricsLogger(
        output_path=DATA_DIR / f"ai_{scenario_name}_seed{seed}.csv"
    )

    try:
        for step_num in range(1, SIM_DURATION + 1):
            if steps_in_block == 0 and not in_yellow:
                # Emergency preemption
                emerg, target = _check_emergency(phase, in_yellow, next_green)
                if emerg and target is not None and target != phase:
                    yellow_phase = _get_yellow(phase)
                    traci.trafficlight.setRedYellowGreenState(
                        TL_ID, PHASE_SIGNALS[yellow_phase])
                    phase = yellow_phase
                    in_yellow = True
                    yellow_cd = YELLOW_DURATION
                    next_green = target
                elif not emerg:
                    state = build_state(phase, phase_timer, in_yellow)
                    action = agent.select_action(state)
                    if action != ACTION_HOLD and _can_switch(phase, phase_timer, in_yellow):
                        t_phase = ACTION_TO_PHASE.get(action, phase)
                        if t_phase != phase:
                            yellow_phase = _get_yellow(phase)
                            traci.trafficlight.setRedYellowGreenState(
                                TL_ID, PHASE_SIGNALS[yellow_phase])
                            phase = yellow_phase
                            in_yellow = True
                            yellow_cd = YELLOW_DURATION
                            next_green = t_phase

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
        "avg_wait":   round(stats["overall_avg_wait"], 2),
        "peak_queue": stats["peak_queue"],
        "completed":  stats["total_completed"],
        "throughput": round(stats["avg_throughput"], 2),
    }


# ══════════════════════════════════════════════════════════════════════════════
# BASELINE FIXED-TIMER EVALUATION
# ══════════════════════════════════════════════════════════════════════════════

def _configure_baseline_timer():
    """Install 4-phase fixed timer on the junction."""
    phases = [
        traci.trafficlight.Phase(BASELINE_NS_GREEN, BASELINE_SIGNALS["NS_GREEN"]),
        traci.trafficlight.Phase(BASELINE_YELLOW,    BASELINE_SIGNALS["NS_YELLOW"]),
        traci.trafficlight.Phase(BASELINE_EW_GREEN,  BASELINE_SIGNALS["EW_GREEN"]),
        traci.trafficlight.Phase(BASELINE_YELLOW,    BASELINE_SIGNALS["EW_YELLOW"]),
    ]
    logic = traci.trafficlight.Logic(
        programID="fixed_timer", type=0, currentPhaseIndex=0,
        phases=phases, subParameter={},
    )
    traci.trafficlight.setProgramLogic(TL_ID, logic)
    traci.trafficlight.setProgram(TL_ID, "fixed_timer")


def run_baseline_episode(seed: int, route_file: str,
                         scenario_name: str = "") -> dict:
    """Run one baseline fixed-timer episode and return metrics."""
    sumo_cmd = [
        find_sumo_binary(),
        "-c", str(CONFIG_FILE),
        "--step-length", "1.0",
        "--no-warnings", "--quit-on-end",
        "--seed", str(seed),
        "--route-files", str(route_file),
    ]
    traci.start(sumo_cmd)
    _configure_baseline_timer()

    logger = MetricsLogger(
        output_path=DATA_DIR / f"bl_{scenario_name}_seed{seed}.csv"
    )

    try:
        for step_num in range(1, SIM_DURATION + 1):
            traci.simulationStep()
            # Determine current baseline phase name from SUMO
            try:
                phase_idx = traci.trafficlight.getPhase(TL_ID)
                bl_phase_names = {0: "NS_GREEN", 1: "NS_YELLOW",
                                  2: "EW_GREEN", 3: "EW_YELLOW"}
                phase_name = bl_phase_names.get(phase_idx, f"phase_{phase_idx}")
            except traci.exceptions.TraCIException:
                phase_name = "unknown"
            logger.step(current_time=float(step_num), tl_phase_name=phase_name)

            if traci.simulation.getMinExpectedNumber() == 0:
                break
    finally:
        traci.close()

    logger.save()
    stats = logger.summary_stats()
    return {
        "avg_wait":   round(stats["overall_avg_wait"], 2),
        "peak_queue": stats["peak_queue"],
        "completed":  stats["total_completed"],
        "throughput": round(stats["avg_throughput"], 2),
    }


# ══════════════════════════════════════════════════════════════════════════════
# MAIN EVALUATION HARNESS
# ══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="ATCS-GH: Cross-scenario evaluation (AI vs Baseline)"
    )
    parser.add_argument("--seeds", type=int, default=3,
                        help="Seeds per scenario (default: 3)")
    parser.add_argument("--model", type=str, default=str(DEFAULT_MODEL),
                        help="Path to trained model")
    parser.add_argument("--ai-only", action="store_true",
                        help="Only run AI agent (skip baseline)")
    parser.add_argument("--baseline-only", action="store_true",
                        help="Only run baseline (skip AI)")
    parser.add_argument("--scenarios", nargs="+", default=SCENARIO_NAMES,
                        help="Scenarios to evaluate (default: all)")
    args = parser.parse_args()

    run_ai_flag = not args.baseline_only
    run_bl_flag = not args.ai_only
    seeds = SEED_LIST[:args.seeds]
    scenarios = args.scenarios

    # Validate scenario files exist
    for name in scenarios:
        route_path = SCENARIO_DIR / f"{name}.rou.xml"
        if not route_path.exists():
            sys.exit(f"[ERROR] Scenario file not found: {route_path}\n"
                     f"  Run first: python scripts/generate_scenarios.py")

    # Load agent if needed
    agent = None
    if run_ai_flag:
        model_path = Path(args.model)
        if not model_path.exists():
            sys.exit(f"[ERROR] Model not found: {model_path}")
        agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
        agent.load(model_path)
        agent.set_eval_mode()

    n_runs = len(scenarios) * args.seeds * (int(run_ai_flag) + int(run_bl_flag))
    print("\n" + "=" * 72)
    print("  ATCS-GH -- Cross-Scenario Evaluation (Achimota/Neoplan Junction)")
    print("=" * 72)
    print(f"  Model     : {Path(args.model).name if run_ai_flag else 'N/A'}")
    print(f"  Seeds     : {args.seeds} -> {seeds}")
    print(f"  Scenarios : {len(scenarios)}")
    print(f"  Total runs: {n_runs}  (~{n_runs * 2} min estimated)")
    print("=" * 72)

    # Collect results: {scenario: {"ai": [...], "baseline": [...]}}
    all_results = {}

    for si, scenario in enumerate(scenarios):
        route_file = str(SCENARIO_DIR / f"{scenario}.rou.xml")
        all_results[scenario] = {"ai": [], "baseline": []}

        print(f"\n  [{si+1}/{len(scenarios)}] {scenario}")
        print("  " + "-" * 50)

        for seed in seeds:
            # Baseline
            if run_bl_flag:
                try:
                    t0 = time.time()
                    bl = run_baseline_episode(seed, route_file, scenario)
                    dt = time.time() - t0
                    all_results[scenario]["baseline"].append(bl)
                    print(f"    Baseline seed={seed}: {bl['avg_wait']:>7.2f}s  ({dt:.0f}s)")
                except Exception as e:
                    print(f"    Baseline seed={seed}: FAILED ({e})")
                    try:
                        traci.close()
                    except Exception:
                        pass

            # AI
            if run_ai_flag:
                try:
                    t0 = time.time()
                    ai = run_ai_episode(agent, seed, route_file, scenario)
                    dt = time.time() - t0
                    all_results[scenario]["ai"].append(ai)
                    print(f"    AI       seed={seed}: {ai['avg_wait']:>7.2f}s  ({dt:.0f}s)")
                except Exception as e:
                    print(f"    AI       seed={seed}: FAILED ({e})")
                    try:
                        traci.close()
                    except Exception:
                        pass

    # ── Results table ─────────────────────────────────────────────────────────
    print("\n" + "=" * 72)
    print("  CROSS-SCENARIO RESULTS")
    print("=" * 72)

    header = f"  {'Scenario':<20s}"
    if run_bl_flag:
        header += f"  {'Baseline (s)':>14s}"
    if run_ai_flag:
        header += f"  {'AI Agent (s)':>14s}"
    if run_bl_flag and run_ai_flag:
        header += f"  {'Change':>10s}  {'Result':>8s}"
    print(header)
    print("  " + "-" * 68)

    wins = 0
    total = 0
    csv_rows = []

    for scenario in scenarios:
        bl_data = all_results[scenario]["baseline"]
        ai_data = all_results[scenario]["ai"]

        bl_mean = np.mean([r["avg_wait"] for r in bl_data]) if bl_data else None
        bl_std  = np.std([r["avg_wait"] for r in bl_data])  if bl_data else None
        ai_mean = np.mean([r["avg_wait"] for r in ai_data]) if ai_data else None
        ai_std  = np.std([r["avg_wait"] for r in ai_data])  if ai_data else None

        row = f"  {scenario:<20s}"
        if run_bl_flag and bl_mean is not None:
            row += f"  {bl_mean:>6.1f} +/- {bl_std:>4.1f}"
        if run_ai_flag and ai_mean is not None:
            row += f"  {ai_mean:>6.1f} +/- {ai_std:>4.1f}"
        if run_bl_flag and run_ai_flag and bl_mean and ai_mean:
            delta = (ai_mean - bl_mean) / bl_mean * 100
            result = "BETTER" if delta < 0 else "WORSE"
            row += f"  {delta:>+8.1f}%  {result:>8s}"
            total += 1
            if delta < 0:
                wins += 1

        print(row)

        csv_rows.append({
            "scenario": scenario,
            "baseline_mean": round(bl_mean, 2) if bl_mean else "",
            "baseline_std": round(bl_std, 2) if bl_std else "",
            "ai_mean": round(ai_mean, 2) if ai_mean else "",
            "ai_std": round(ai_std, 2) if ai_std else "",
            "change_pct": round((ai_mean - bl_mean) / bl_mean * 100, 1) if (bl_mean and ai_mean) else "",
        })

    print("  " + "-" * 68)

    if total > 0:
        print(f"\n  Generalization Score: {wins}/{total} scenarios "
              f"({wins/total*100:.0f}%) -- AI outperforms baseline")
    print("=" * 72)

    # Save CSV
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = DATA_DIR / "scenario_eval_results.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "scenario", "baseline_mean", "baseline_std",
            "ai_mean", "ai_std", "change_pct",
        ])
        w.writeheader()
        w.writerows(csv_rows)
    print(f"\n  Results saved -> {csv_path.relative_to(PROJECT_ROOT)}")
    print()


if __name__ == "__main__":
    main()
