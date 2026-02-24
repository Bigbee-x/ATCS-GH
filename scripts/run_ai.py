#!/usr/bin/env python3
"""
ATCS-GH Phase 2 | AI Controller — Inference Runner
════════════════════════════════════════════════════
Runs the trained DQN agent on the same 2-hour morning rush scenario
used for the Phase 1 baseline, producing an identical report format
for direct comparison.

Key differences from run_baseline.py:
  • Traffic light is controlled by the DQN agent (not a fixed timer)
  • Agent makes a phase decision every DECISION_INTERVAL seconds
  • Emergency preemption is active (hardcoded safety layer)
  • MetricsLogger still runs at 1-second resolution for precise metrics

Usage:
    python scripts/run_ai.py                              # use trained_model.pth
    python scripts/run_ai.py --model ai/best_model.pth   # use best checkpoint
    python scripts/run_ai.py --gui                        # open SUMO-GUI window
"""

import os
import sys
import time
import shutil
import argparse
from datetime import datetime
from pathlib import Path


# ── SUMO / TraCI setup ────────────────────────────────────────────────────────

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

from dqn_agent    import DQNAgent
from metrics_logger import MetricsLogger

# Also import phase/edge constants from traffic_env
from traffic_env import (
    TL_ID, INCOMING_EDGES, EMERGENCY_TYPE,
    NS_GREEN, NS_YELLOW, EW_GREEN, EW_YELLOW, PHASE_NAMES,
    EDGE_TO_GREEN, STATE_SIZE, ACTION_SIZE,
    DECISION_INTERVAL, MIN_GREEN_DURATION, YELLOW_DURATION,
    MAX_QUEUE, MAX_WAIT, MAX_PHASE_T,
)


# ── Paths and constants ───────────────────────────────────────────────────────

SIM_DIR         = PROJECT_ROOT / "simulation"
DATA_DIR        = PROJECT_ROOT / "data"
CONFIG_FILE     = SIM_DIR / "intersection.sumocfg"
NETWORK_FILE    = SIM_DIR / "intersection.net.xml"
DEFAULT_MODEL   = PROJECT_ROOT / "ai" / "best_model.pth"
OUTPUT_CSV      = DATA_DIR / "ai_results.csv"

SIM_DURATION    = 7200     # seconds (matches baseline)
BASELINE_CSV    = DATA_DIR / "baseline_results.csv"


def _load_baseline_stats() -> dict:
    """
    Load baseline metrics dynamically from Phase 1 CSV.
    Falls back to hardcoded values if the CSV is missing.
    """
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


# ── Helper: build state vector ────────────────────────────────────────────────

def build_state(phase: int,
                phase_timer: int,
                in_yellow: bool) -> "np.ndarray":
    """
    Build the 17-dimensional normalised state vector directly from TraCI.
    Mirrors traffic_env.TrafficEnv._build_state().
    """
    import numpy as np

    queues = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
    waits  = np.zeros(len(INCOMING_EDGES), dtype=np.float32)

    for i, edge in enumerate(INCOMING_EDGES):
        total_q = 0
        total_w = 0.0
        n_lanes = 0
        try:
            n_lanes = traci.edge.getLaneNumber(edge)
            for idx in range(n_lanes):
                lid     = f"{edge}_{idx}"
                total_q += traci.lane.getLastStepHaltingNumber(lid)
                total_w += traci.lane.getWaitingTime(lid)
        except traci.exceptions.TraCIException:
            pass
        queues[i] = float(total_q)
        waits[i]  = float(total_w / max(n_lanes, 1))

    phase_vec = np.zeros(4, dtype=np.float32)
    phase_vec[phase] = 1.0

    t_norm = np.float32(min(phase_timer / MAX_PHASE_T, 1.0))

    # Emergency flags
    emerg = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
    for i, edge in enumerate(INCOMING_EDGES):
        try:
            for vid in traci.edge.getLastStepVehicleIDs(edge):
                if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                    emerg[i] = 1.0
                    break
        except traci.exceptions.TraCIException:
            pass

    state = np.concatenate([
        queues / MAX_QUEUE,
        waits  / MAX_WAIT,
        phase_vec,
        [t_norm],
        emerg,
    ])
    return state.astype(np.float32)


# ── Helper: emergency preemption ─────────────────────────────────────────────

def check_emergency_preemption(phase: int,
                                in_yellow: bool,
                                next_green: int | None) -> tuple[bool, int | None]:
    """
    Mirror of TrafficEnv._check_emergency_preemption().
    Returns (preempt, target_green_phase).
    """
    for edge in INCOMING_EDGES:
        try:
            for vid in traci.edge.getLastStepVehicleIDs(edge):
                if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                    continue
                target_green = EDGE_TO_GREEN[edge]
                already_serving = (
                    phase == target_green
                    or (in_yellow and next_green == target_green)
                )
                if not already_serving:
                    return True, target_green
        except traci.exceptions.TraCIException:
            pass
    return False, None


# ── Binary detection ──────────────────────────────────────────────────────────

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


# ── Main runner ───────────────────────────────────────────────────────────────

def run_ai(model_path: str | Path = DEFAULT_MODEL,
           gui: bool = False) -> None:
    """
    Run a single 2-hour episode with the trained DQN agent.

    Control loop runs at 1-second resolution (for MetricsLogger precision).
    Agent makes a phase decision every DECISION_INTERVAL seconds.
    Emergency preemption is always active.
    """
    model_path = Path(model_path)
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Pre-flight checks
    if not NETWORK_FILE.exists():
        print(f"[ERROR] Network not built. Run: python scripts/build_network.py")
        sys.exit(1)
    if not model_path.exists():
        print(f"[ERROR] Model not found: {model_path}")
        print(f"  Train first:  python scripts/train_agent.py")
        sys.exit(1)

    # Load agent
    agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
    agent.load(model_path)
    agent.set_eval_mode()   # ε=0, pure exploitation

    print("\n" + "═" * 62)
    print("  ATCS-GH Phase 2 — AI Inference Run")
    print("═" * 62)
    print(f"  Model   : {model_path}")
    print(f"  Mode    : {'GUI (visual)' if gui else 'Headless (fast)'}")
    print(f"  Duration: {SIM_DURATION}s (2 hours)")
    print(f"  Decision: every {DECISION_INTERVAL}s | min green: {MIN_GREEN_DURATION}s")
    print(f"  Output  : {OUTPUT_CSV}")
    print("═" * 62)

    # Launch SUMO
    sumo_cmd = [
        find_sumo_binary(gui),
        "-c",            str(CONFIG_FILE),
        "--step-length", "1.0",
        "--no-warnings",
        "--quit-on-end",
    ]
    traci.start(sumo_cmd)
    print("\n[TraCI] Connected")

    # Install ai_control TL program (same as in TrafficEnv)
    _install_ai_tl_program()

    # Phase control state
    phase         = NS_GREEN
    phase_timer   = 0        # seconds in current phase
    in_yellow     = False
    yellow_cd     = 0
    next_green    = EW_GREEN  # phase after current yellow ends

    # Decision step counter (agent decides every DECISION_INTERVAL steps)
    steps_in_block = 0

    # Metrics
    logger     = MetricsLogger(output_path=OUTPUT_CSV)
    wall_start = time.time()
    last_pct   = -1

    print(f"\n[SIM] Running {SIM_DURATION} steps... (Ctrl+C to abort)\n")

    try:
        for step_num in range(1, SIM_DURATION + 1):

            # ── Agent decision (every DECISION_INTERVAL seconds) ──────────────
            if steps_in_block == 0:
                state  = build_state(phase, phase_timer, in_yellow)

                # Emergency preemption check (safety layer — overrides agent)
                preempt, target_green = check_emergency_preemption(
                    phase, in_yellow, next_green if in_yellow else None
                )
                if preempt and target_green is not None:
                    action = 1 if target_green != phase else 0
                    if action == 1 and not in_yellow:
                        # Force immediate switch towards target green
                        yellow = NS_YELLOW if phase == NS_GREEN else EW_YELLOW
                        next_green = target_green
                        traci.trafficlight.setPhase(TL_ID, yellow)
                        phase     = yellow
                        in_yellow = True
                        yellow_cd = YELLOW_DURATION
                else:
                    action = agent.select_action(state)
                    # Apply agent action: switch if allowed
                    if (action == 1
                            and not in_yellow
                            and phase in (NS_GREEN, EW_GREEN)
                            and phase_timer >= MIN_GREEN_DURATION):
                        yellow     = NS_YELLOW if phase == NS_GREEN else EW_YELLOW
                        next_green = EW_GREEN  if phase == NS_GREEN else NS_GREEN
                        traci.trafficlight.setPhase(TL_ID, yellow)
                        phase     = yellow
                        in_yellow = True
                        yellow_cd = YELLOW_DURATION

            # ── Yellow transition handling ─────────────────────────────────────
            if in_yellow:
                yellow_cd -= 1
                if yellow_cd <= 0:
                    traci.trafficlight.setPhase(TL_ID, next_green)
                    phase     = next_green
                    in_yellow = False
                    phase_timer = 0

            # ── Advance simulation ─────────────────────────────────────────────
            traci.simulationStep()
            phase_timer    += 1
            steps_in_block  = (steps_in_block + 1) % DECISION_INTERVAL

            # ── Log this step (1-second resolution) ────────────────────────────
            phase_name = PHASE_NAMES.get(phase, f"phase_{phase}")
            logger.step(current_time=float(step_num), tl_phase_name=phase_name)

            # ── Progress ───────────────────────────────────────────────────────
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
    """Install the 1M-second ai_control TL program (prevents SUMO auto-advance)."""
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
    traci.trafficlight.setPhase(TL_ID, NS_GREEN)
    print("[TL]  'ai_control' program installed (AI controls all phase transitions)")


# ── Terminal report ───────────────────────────────────────────────────────────

def print_report(sim_time: int, stats: dict, model_path: Path) -> None:
    """
    Formatted report matching run_baseline.py output exactly,
    with an added Phase 1 vs Phase 2 comparison section.
    """
    if not stats:
        print("[Report] No statistics available.")
        return

    edge_labels = {
        "N2J": "North → (main, 2-lane)",
        "S2J": "South → (main, 2-lane)",
        "E2J": "East  → (side, 1-lane)",
        "W2J": "West  → (side, 1-lane)",
    }

    avg_wait   = stats["overall_avg_wait"]
    bl_wait    = BASELINE["avg_wait"]
    delta_pct  = (avg_wait - bl_wait) / bl_wait * 100
    direction  = "▼ BETTER" if delta_pct < 0 else "▲ WORSE"

    print("\n" + "═" * 62)
    print("  ATCS-GH  |  AI SIMULATION REPORT  |  Phase 2")
    print("═" * 62)
    print(f"  Generated  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Model      : {model_path.name}")
    print(f"  Simulated  : {sim_time}s  ({sim_time/3600:.2f} hours)")
    print(f"  Controller : DQN agent  (decision every {DECISION_INTERVAL}s)")
    print()
    print(f"  ┌── OVERALL PERFORMANCE ────────────────────────────┐")
    print(f"  │  Vehicles completed journey   : {stats['total_completed']:>8,}           │")
    print(f"  │  Average wait time (all lanes): {avg_wait:>7.2f}s           │")
    print(f"  │  Peak queue length            : {stats['peak_queue']:>8} vehicles      │")
    print(f"  │  Average throughput           : {stats['avg_throughput']:>7.1f} veh/min       │")
    print(f"  │  Peak throughput              : {stats['peak_throughput']:>7.0f} veh/min       │")
    print(f"  └───────────────────────────────────────────────────┘")
    print()

    print(f"  ┌── LANE PERFORMANCE ───────────────────────────────┐")
    print(f"  │  {'Approach':<30}  {'Avg Wait':>8}  {'Max Queue':>9}  │")
    print(f"  │  {'─'*30}  {'─'*8}  {'─'*9}  │")
    for edge, label in edge_labels.items():
        es      = stats["edge_stats"].get(edge, {})
        samples = es.get("samples", 0)
        avg_w   = round(es["total_wait"] / samples, 2) if samples > 0 else 0.0
        max_q   = es.get("max_queue", 0)
        print(f"  │  {label:<30}  {avg_w:>7.2f}s  {max_q:>9}  │")
    print(f"  └───────────────────────────────────────────────────┘")
    print()

    emerg = stats.get("emergency_log", {})
    if emerg:
        print(f"  ┌── EMERGENCY VEHICLE PERFORMANCE ──────────────────┐")
        print(f"  │  {'Vehicle':<15}  {'Route':<12}  {'Max Wait at Red':>16}  │")
        print(f"  │  {'─'*15}  {'─'*12}  {'─'*16}  │")
        for vid, info in sorted(emerg.items()):
            print(f"  │  {vid:<15}  {info['route']:<12}  {info['max_wait']:>14.1f}s  │")
        print(f"  └───────────────────────────────────────────────────┘")
        print()

    print(f"  ┌── PHASE 1 vs PHASE 2 COMPARISON ──────────────────┐")
    print(f"  │  Metric                Phase 1 (Fixed)  Phase 2 (AI)  │")
    print(f"  │  ─────────────────     ──────────────   ───────────   │")
    print(f"  │  Avg wait time         {bl_wait:>10.1f}s   "
          f"{avg_wait:>8.1f}s  │")
    print(f"  │  Peak queue            {BASELINE['peak_queue']:>12}    {stats['peak_queue']:>10}   │")
    print(f"  │  Avg throughput        {BASELINE['avg_throughput']:>9} v/m   "
          f"{stats['avg_throughput']:>7.1f} v/m  │")
    print(f"  │                                                      │")
    print(f"  │  Wait time change:  {direction}  {abs(delta_pct):>5.1f}%               │")
    print(f"  └───────────────────────────────────────────────────┘")
    print()
    print(f"  Results saved → data/ai_results.csv")
    print("═" * 62 + "\n")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ATCS-GH Phase 2: Run the trained AI traffic controller"
    )
    parser.add_argument(
        "--model", type=str, default=str(DEFAULT_MODEL),
        help=f"Path to trained model checkpoint (default: {DEFAULT_MODEL.name})"
    )
    parser.add_argument(
        "--gui", action="store_true",
        help="Launch SUMO with GUI"
    )
    args = parser.parse_args()
    run_ai(model_path=args.model, gui=args.gui)
