#!/usr/bin/env python3
"""
ATCS-GH | AI Controller -- Inference Runner (Achimota/Neoplan Junction)
=======================================================================
Runs the trained DQN agent on the 2-hour morning rush scenario,
producing a report for comparison with the fixed-timer baseline.

Usage:
    python scripts/run_ai.py                              # use best_model.pth
    python scripts/run_ai.py --model ai/best_model.pth    # specific checkpoint
    python scripts/run_ai.py --gui                        # open SUMO-GUI
"""

import os
import sys
import time
import shutil
import argparse
import numpy as np
from datetime import datetime
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
        print("[ERROR] SUMO not found. Install: pip install eclipse-sumo")
        sys.exit(1)
    tools = os.path.join(home, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    return home


SUMO_HOME = _setup_sumo()

try:
    import traci
    import traci.exceptions
except ImportError as e:
    print(f"[ERROR] Cannot import TraCI: {e}")
    sys.exit(1)

# Add project roots for local imports
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from dqn_agent     import DQNAgent
from metrics_logger import MetricsLogger

from traffic_env import (
    TL_ID, INCOMING_EDGES, INCOMING_LANES, EMERGENCY_TYPE,
    NS_THROUGH, NS_LEFT, NS_YELLOW, EW_THROUGH, EW_LEFT, EW_YELLOW,
    NS_ALL, EW_ALL,
    PHASE_NAMES, PHASE_SIGNALS, GREEN_PHASES,
    EDGE_TO_GREENS, ACTION_TO_PHASE, ACTION_NAMES, ACTION_HOLD,
    STATE_SIZE, ACTION_SIZE,
    DECISION_INTERVAL, MIN_GREEN_THROUGH, MIN_GREEN_LEFT, YELLOW_DURATION,
    MAX_QUEUE, MAX_QUEUE_LANE, MAX_SPEED, MAX_WAIT, MAX_PHASE_T,
    NUM_PHASES, WALKING_AREAS, MAX_PED_QUEUE,
)


# -- Paths and constants ------------------------------------------------------

SIM_DIR         = PROJECT_ROOT / "simulation"
DATA_DIR        = PROJECT_ROOT / "data"
CONFIG_FILE     = SIM_DIR / "intersection.sumocfg"
NETWORK_FILE    = SIM_DIR / "intersection.net.xml"
DEFAULT_MODEL   = PROJECT_ROOT / "ai" / "best_model.pth"
OUTPUT_CSV      = DATA_DIR / "ai_results.csv"

SIM_DURATION    = 7200
BASELINE_CSV    = DATA_DIR / "baseline_results.csv"


def _load_baseline_stats() -> dict:
    fallback = {"avg_wait": 399.12, "peak_queue": 185, "avg_throughput": 37.9}
    if not BASELINE_CSV.exists():
        print(f"[WARN] Baseline CSV not found ({BASELINE_CSV.name}), using fallback values.")
        return fallback
    try:
        import csv
        with open(BASELINE_CSV, "r") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
        if not rows:
            return fallback
        waits  = [float(r["avg_wait_time_s"]) for r in rows]
        queues = [int(r["total_queue_vehicles"]) for r in rows]
        thrpts = [float(r["throughput_veh_per_min"]) for r in rows]
        return {
            "avg_wait":       round(sum(waits) / len(waits), 2),
            "peak_queue":     max(queues),
            "avg_throughput":  round(sum(thrpts) / len(thrpts), 1),
        }
    except Exception as e:
        print(f"[WARN] Could not parse baseline CSV: {e}. Using fallback values.")
        return fallback


BASELINE = _load_baseline_stats()


# -- Helper: build 42-dim state vector ----------------------------------------

def build_state(phase: int,
                phase_timer: int,
                _in_yellow: bool) -> np.ndarray:
    """Build the 42-dimensional normalised state vector from TraCI."""
    # Per-lane features (7 lanes x 3 = 21 dims)
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

    # Per-approach queues (4 dims) — skip lane 0 (sidewalk)
    approach_queues = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
    for i, edge in enumerate(INCOMING_EDGES):
        try:
            n_lanes = traci.edge.getLaneNumber(edge)
            total_q = 0
            for idx in range(1, n_lanes):  # start at 1: lane 0 is sidewalk
                total_q += traci.lane.getLastStepHaltingNumber(f"{edge}_{idx}")
            approach_queues[i] = float(total_q)
        except traci.exceptions.TraCIException:
            pass

    # Phase one-hot (8 dims)
    phase_vec = np.zeros(NUM_PHASES, dtype=np.float32)
    phase_vec[phase] = 1.0

    t_norm = np.float32(min(phase_timer / MAX_PHASE_T, 1.0))

    # Emergency flags (4 dims)
    emerg = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
    for i, edge in enumerate(INCOMING_EDGES):
        try:
            for vid in traci.edge.getLastStepVehicleIDs(edge):
                if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                    emerg[i] = 1.0
                    break
        except traci.exceptions.TraCIException:
            pass

    # Pedestrian waiting counts (4 dims)
    ped_counts = np.zeros(len(WALKING_AREAS), dtype=np.float32)
    for i, wa in enumerate(WALKING_AREAS):
        try:
            ped_counts[i] = float(len(traci.edge.getLastStepPersonIDs(wa)))
        except traci.exceptions.TraCIException:
            pass

    state = np.concatenate([
        lane_queues / MAX_QUEUE_LANE,   # 7
        lane_speeds / MAX_SPEED,         # 7
        lane_waits  / MAX_WAIT,          # 7
        approach_queues / MAX_QUEUE,     # 4
        phase_vec,                       # 8
        [t_norm],                        # 1
        emerg,                           # 4
        ped_counts / MAX_PED_QUEUE,      # 4
    ])                                   # = 42
    return state.astype(np.float32)


# -- Helper: emergency preemption ---------------------------------------------

def check_emergency_preemption(phase: int,
                                in_yellow: bool,
                                next_green: int | None) -> tuple[bool, int | None]:
    """Mirror of TrafficEnv._check_emergency_preemption()."""
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


# -- Binary detection ----------------------------------------------------------

def find_sumo_binary(gui: bool = False) -> str:
    name = "sumo-gui" if gui else "sumo"
    for p in [os.path.join(SUMO_HOME, "bin", name),
              shutil.which(name),
              f"/opt/homebrew/bin/{name}",
              f"/usr/local/bin/{name}"]:
        if p and os.path.isfile(p):
            return p
    print(f"[ERROR] '{name}' binary not found")
    sys.exit(1)


# -- Phase control helpers ----------------------------------------------------

def _can_switch(phase: int, phase_timer: int, in_yellow: bool) -> bool:
    if in_yellow or phase not in GREEN_PHASES:
        return False
    min_green = (MIN_GREEN_LEFT
                 if phase in (NS_LEFT, EW_LEFT)
                 else MIN_GREEN_THROUGH)
    return phase_timer >= min_green


def _get_yellow_for_phase(phase: int) -> int:
    if phase in (NS_THROUGH, NS_LEFT, NS_ALL):
        return NS_YELLOW
    return EW_YELLOW


# -- Main runner ---------------------------------------------------------------

def run_ai(model_path: str | Path = DEFAULT_MODEL,
           gui: bool = False,
           route_file: str | None = None) -> None:
    """Run a single 2-hour episode with the trained DQN agent."""
    model_path = Path(model_path)
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    if not NETWORK_FILE.exists():
        print(f"[ERROR] Network not built. Run: python scripts/build_network.py")
        sys.exit(1)
    if not model_path.exists():
        print(f"[ERROR] Model not found: {model_path}")
        print(f"  Train first:  python scripts/train_agent.py")
        sys.exit(1)

    agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
    agent.load(model_path)
    agent.set_eval_mode()

    print("\n" + "=" * 62)
    print("  ATCS-GH -- AI Inference Run (Achimota/Neoplan Junction)")
    print("=" * 62)
    print(f"  Model   : {model_path}")
    print(f"  Mode    : {'GUI (visual)' if gui else 'Headless (fast)'}")
    print(f"  Duration: {SIM_DURATION}s (2 hours)")
    print(f"  Decision: every {DECISION_INTERVAL}s | min green: {MIN_GREEN_THROUGH}s/{MIN_GREEN_LEFT}s")
    print(f"  Output  : {OUTPUT_CSV}")
    print("=" * 62)

    sumo_cmd = [
        find_sumo_binary(gui),
        "-c",            str(CONFIG_FILE),
        "--step-length", "1.0",
        "--no-warnings",
        "--quit-on-end",
    ]
    if route_file is not None:
        sumo_cmd += ["--route-files", str(route_file)]
    traci.start(sumo_cmd)
    print("\n[TraCI] Connected")

    _install_ai_tl_program()

    # Phase control state
    phase         = NS_THROUGH
    phase_timer   = 0
    in_yellow     = False
    yellow_cd     = 0
    next_green    = EW_THROUGH

    steps_in_block = 0
    logger     = MetricsLogger(output_path=OUTPUT_CSV)
    wall_start = time.time()
    last_pct   = -1
    step_num   = 0

    print(f"\n[SIM] Running {SIM_DURATION} steps... (Ctrl+C to abort)\n")

    try:
        for step_num in range(1, SIM_DURATION + 1):

            # -- Agent decision (every DECISION_INTERVAL seconds) ------
            if steps_in_block == 0:
                state = build_state(phase, phase_timer, in_yellow)

                preempt, target_green = check_emergency_preemption(
                    phase, in_yellow, next_green if in_yellow else None
                )
                if preempt and target_green is not None:
                    if target_green != phase and not in_yellow:
                        yellow_phase = _get_yellow_for_phase(phase)
                        next_green = target_green
                        traci.trafficlight.setRedYellowGreenState(
                            TL_ID, PHASE_SIGNALS[yellow_phase])
                        phase     = yellow_phase
                        in_yellow = True
                        yellow_cd = YELLOW_DURATION
                else:
                    action = agent.select_action(state)

                    if action != ACTION_HOLD and _can_switch(phase, phase_timer, in_yellow):
                        target = ACTION_TO_PHASE[action]
                        if target != phase:
                            yellow_phase = _get_yellow_for_phase(phase)
                            next_green = target
                            traci.trafficlight.setRedYellowGreenState(
                                TL_ID, PHASE_SIGNALS[yellow_phase])
                            phase     = yellow_phase
                            in_yellow = True
                            yellow_cd = YELLOW_DURATION

            # -- Yellow transition handling ----------------------------
            if in_yellow:
                yellow_cd -= 1
                if yellow_cd <= 0:
                    traci.trafficlight.setRedYellowGreenState(
                        TL_ID, PHASE_SIGNALS[next_green])
                    phase       = next_green
                    in_yellow   = False
                    phase_timer = 0

            # -- Advance simulation ------------------------------------
            traci.simulationStep()
            phase_timer    += 1
            steps_in_block  = (steps_in_block + 1) % DECISION_INTERVAL

            phase_name = PHASE_NAMES.get(phase, f"phase_{phase}")
            logger.step(current_time=float(step_num), tl_phase_name=phase_name)

            pct = int(step_num / SIM_DURATION * 100)
            if pct % 10 == 0 and pct != last_pct:
                elapsed = time.time() - wall_start
                print(f"  [{pct:3d}%] t={step_num:5d}s  "
                      f"completed={logger.total_arrived:5d}  "
                      f"wall={elapsed:5.1f}s")
                last_pct = pct

            if traci.simulation.getMinExpectedNumber() == 0:
                print(f"\n[SIM] All vehicles done at t={step_num}s.")
                break

    except KeyboardInterrupt:
        print("\n[SIM] Interrupted.")
    finally:
        traci.close()
        print("[TraCI] Disconnected.")

    logger.save()
    stats = logger.summary_stats()
    print_report(sim_time=step_num, stats=stats, model_path=model_path)


def _install_ai_tl_program() -> None:
    """Install ai_control TL program and set initial phase."""
    logics = traci.trafficlight.getAllProgramLogics(TL_ID)
    if not logics:
        return
    long_phases = [
        traci.trafficlight.Phase(1_000_000, p.state)
        for p in logics[0].phases
    ]
    ai_logic = traci.trafficlight.Logic(
        programID="ai_control", type=0, currentPhaseIndex=0,
        phases=long_phases, subParameter={},
    )
    traci.trafficlight.setProgramLogic(TL_ID, ai_logic)
    traci.trafficlight.setProgram(TL_ID, "ai_control")
    traci.trafficlight.setRedYellowGreenState(TL_ID, PHASE_SIGNALS[NS_THROUGH])
    print("[TL]  'ai_control' program installed (AI controls all phase transitions)")


# -- Terminal report -----------------------------------------------------------

def print_report(sim_time: int, stats: dict, model_path: Path) -> None:
    if not stats:
        print("[Report] No statistics available.")
        return

    edge_labels = {
        "ACH_N2J": "Achimota Forest Rd from Nsawam (2-lane)",
        "ACH_S2J": "Achimota Forest Rd from CBD    (2-lane)",
        "AGG_E2J": "Aggrey Street                  (2-lane)",
        "GUG_W2J": "Guggisberg Street              (1-lane)",
    }

    avg_wait   = stats["overall_avg_wait"]
    bl_wait    = BASELINE["avg_wait"]
    delta_pct  = (avg_wait - bl_wait) / bl_wait * 100
    direction  = "BETTER" if delta_pct < 0 else "WORSE"

    print("\n" + "=" * 62)
    print("  ATCS-GH  |  AI REPORT  |  Achimota/Neoplan Junction")
    print("=" * 62)
    print(f"  Generated  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Model      : {model_path.name}")
    print(f"  Simulated  : {sim_time}s  ({float(sim_time)/3600:.2f} hours)")
    print(f"  Controller : DQN agent  (decision every {DECISION_INTERVAL}s)")
    print()
    print(f"  Overall avg wait  : {avg_wait:>7.2f}s")
    print(f"  Peak queue        : {stats['peak_queue']:>8} vehicles")
    print(f"  Avg throughput    : {stats['avg_throughput']:>7.1f} veh/min")
    print(f"  Vehicles completed: {stats['total_completed']:>8,}")
    print()

    print(f"  Per-approach:")
    for edge, label in edge_labels.items():
        es      = stats["edge_stats"].get(edge, {})
        samples = es.get("samples", 0)
        avg_w   = round(es["total_wait"] / samples, 2) if samples > 0 else 0.0
        max_q   = es.get("max_queue", 0)
        print(f"    {label}  wait={avg_w:.1f}s  max_q={max_q}")
    print()

    print(f"  Baseline (fixed timer) : {bl_wait:.1f}s")
    print(f"  AI controller          : {avg_wait:.1f}s")
    print(f"  Change                 : {direction} {abs(delta_pct):.1f}%")
    print()
    print(f"  Results saved -> data/ai_results.csv")
    print("=" * 62 + "\n")


# -- Entry point ---------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ATCS-GH: Run the trained AI traffic controller"
    )
    parser.add_argument(
        "--model", type=str, default=str(DEFAULT_MODEL),
        help=f"Path to trained model checkpoint (default: {DEFAULT_MODEL.name})"
    )
    parser.add_argument(
        "--gui", action="store_true",
        help="Launch SUMO with GUI"
    )
    parser.add_argument(
        "--scenario", type=str, default=None,
        help="Demand scenario name (e.g. evening_rush). Uses default routes if not set."
    )
    args = parser.parse_args()
    route_file = None
    if args.scenario:
        route_file = str(SIM_DIR / "scenarios" / f"{args.scenario}.rou.xml")
    run_ai(model_path=args.model, gui=args.gui, route_file=route_file)
