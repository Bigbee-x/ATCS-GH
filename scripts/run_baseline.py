#!/usr/bin/env python3
"""
ATCS-GH Phase 1 | Baseline Fixed-Timer Simulation
══════════════════════════════════════════════════
Runs a 2-hour morning rush hour simulation of an Accra 4-way junction
using a standard fixed-timer traffic light (our baseline to beat in Phase 2).

What this script does:
  1. Launches SUMO (headless or GUI) and connects via TraCI
  2. Overrides the auto-generated TL with a 45s / 3s fixed timer
  3. Steps through 7,200 simulation seconds collecting metrics
  4. Saves results to data/baseline_results.csv
  5. Prints a formatted terminal performance report

Usage:
    python scripts/run_baseline.py           # headless (fast)
    python scripts/run_baseline.py --gui     # with SUMO visual GUI

Phase 2 note:
    To build the AI controller, replace configure_fixed_timer() with an RL
    agent and call traci.trafficlight.setPhase(TL_ID, phase) each step.
    The MetricsLogger interface is identical — just swap the controller.
"""

import os
import sys
import time
import shutil
import argparse
from datetime import datetime
from pathlib import Path


# ── SUMO / TraCI Setup ────────────────────────────────────────────────────────

def setup_sumo() -> str:
    """
    Locate SUMO_HOME, add TraCI tools to sys.path, and return the SUMO home dir.
    Exits with a clear error message if SUMO is not found.
    """
    sumo_home = os.environ.get("SUMO_HOME")

    if sumo_home is None:
        # Check pip-installed eclipse-sumo package first (most reliable on modern macOS)
        try:
            import sumo as _sumo_pkg
            candidate = _sumo_pkg.SUMO_HOME
            if os.path.isdir(candidate):
                sumo_home = candidate
                os.environ["SUMO_HOME"] = candidate
                print(f"[SUMO] Found pip-installed eclipse-sumo at: {candidate}")
        except ImportError:
            pass

    if sumo_home is None:
        # Auto-detect common macOS install locations
        candidates = [
            "/opt/homebrew/opt/sumo/share/sumo",  # Homebrew dlr-ts tap
            "/opt/homebrew/share/sumo",            # M1/M2/M3 Homebrew alt
            "/usr/local/share/sumo",               # Intel Homebrew
            "/usr/local/opt/sumo/share/sumo",      # Intel Homebrew (alt)
            "/usr/share/sumo",                     # Linux
        ]
        for path in candidates:
            if os.path.isdir(path):
                sumo_home = path
                os.environ["SUMO_HOME"] = path
                print(f"[SUMO] Auto-detected SUMO at: {path}")
                break

    if sumo_home is None:
        print("\n[ERROR] SUMO not found.")
        print("  Install: brew install sumo")
        print("  Then:    export SUMO_HOME=/opt/homebrew/share/sumo")
        print("           Run scripts/build_network.py first.")
        sys.exit(1)

    tools = os.path.join(sumo_home, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)

    return sumo_home


SUMO_HOME = setup_sumo()

try:
    import traci
    import traci.exceptions
except ImportError as e:
    print(f"[ERROR] Cannot import TraCI: {e}")
    print(f"  Check that {SUMO_HOME}/tools/ exists and contains traci/")
    sys.exit(1)

# Import our metrics logger (sibling module)
sys.path.insert(0, str(Path(__file__).parent))
from metrics_logger import MetricsLogger


# ── Configuration Constants ───────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SIM_DIR      = PROJECT_ROOT / "simulation"
DATA_DIR     = PROJECT_ROOT / "data"

CONFIG_FILE  = SIM_DIR / "intersection.sumocfg"
NETWORK_FILE = SIM_DIR / "intersection.net.xml"
OUTPUT_CSV   = DATA_DIR / "baseline_results.csv"

TL_ID           = "J0"     # Traffic light junction ID (must match nodes.nod.xml)
SIM_DURATION    = 7200     # 2 hours in simulation seconds
STEP_LENGTH     = 1.0      # Seconds per simulation step
YELLOW_DURATION = 3        # Yellow clearance phase (seconds)

# ── Timer presets ────────────────────────────────────────────────────────────
# Naive:  equal green split (45/45) — the original Phase 1 baseline
# Tuned:  demand-proportional split (60/30) — a fair comparison for Phase 2
#
# Achimota demand analysis from routes.rou.xml:
#   N/S approaches (Achimota Forest Rd): ~1,520 veh/hr (67%)  →  60s green
#   E/W approaches (Aggrey + Guggisberg): ~  750 veh/hr (33%)  →  30s green
#   Total cycle: 60 + 3 + 30 + 3 = 96s (unchanged)
TIMER_PRESETS = {
    "naive": {"ns_green": 45, "ew_green": 45, "label": "45s/45s equal split"},
    "tuned": {"ns_green": 60, "ew_green": 30, "label": "60s/30s demand-proportional"},
}

# Human-readable phase names indexed by SUMO phase index (0–3)
PHASE_NAMES = {0: "NS_GREEN", 1: "NS_YELLOW", 2: "EW_GREEN", 3: "EW_YELLOW"}

# Explicit signal strings for the baseline fixed timer (15 connections).
# Connection order from net.xml:
#   0-3:  ACH_N2J (N→W right, N→S through×2, N→E left)
#   4-6:  AGG_E2J (E→N right, E→W through, E→S left)
#   7-10: ACH_S2J (S→E right, S→N through×2, S→W left)
#   11-14: GUG_W2J (W→S right, W→E through×2, W→N left)
#
# Baseline gives ALL movements green in their direction simultaneously
# (no separate protected left-turn phases — that's the AI's advantage).
BASELINE_SIGNALS = {
    "NS_GREEN":  "GGGGrrrGGGGrrrr",   # N/S all green, E/W red
    "NS_YELLOW": "yyyyrrryyyyrrrr",    # N/S yellow, E/W red
    "EW_GREEN":  "rrrrGGGrrrrGGGG",    # E/W all green, N/S red
    "EW_YELLOW": "rrrryyyrrrryyyy",    # E/W yellow, N/S red
}


# ── SUMO Binary Detection ─────────────────────────────────────────────────────

def find_sumo_binary(gui: bool = False) -> str:
    """Return path to 'sumo' or 'sumo-gui' binary."""
    name = "sumo-gui" if gui else "sumo"

    # Try SUMO_HOME/bin first (most reliable)
    candidate = os.path.join(SUMO_HOME, "bin", name)
    if os.path.isfile(candidate):
        return candidate

    # Fall back to PATH
    found = shutil.which(name)
    if found:
        return found

    # Homebrew common locations
    for base in ["/opt/homebrew/bin", "/usr/local/bin"]:
        p = os.path.join(base, name)
        if os.path.isfile(p):
            return p

    print(f"[ERROR] '{name}' binary not found.")
    print("  Is SUMO installed? Run: brew install sumo")
    sys.exit(1)


# ── Traffic Light Configuration ───────────────────────────────────────────────

def configure_fixed_timer(tl_id: str,
                          ns_green: int = 45,
                          ew_green: int = 45,
                          program_label: str = "fixed_timer") -> list:
    """
    Override the auto-generated traffic light with an explicit 4-phase fixed timer.

    We define the signal strings directly rather than relying on SUMO's
    auto-generated phases, which may contain extra sub-phases for protected
    left turns.

    Phase structure:
      Phase 0: NS_GREEN  — ns_green seconds  (all N/S movements green)
      Phase 1: NS_YELLOW — 3 seconds          (N/S clearing)
      Phase 2: EW_GREEN  — ew_green seconds   (all E/W movements green)
      Phase 3: EW_YELLOW — 3 seconds          (E/W clearing)

    Args:
        tl_id:         Traffic light junction ID.
        ns_green:      Green duration for N/S phase (seconds).
        ew_green:      Green duration for E/W phase (seconds).
        program_label: Name for this TL program in SUMO.

    Returns:
        List of configured Phase objects (for logging/debugging).
    """
    phase_plan = [
        ("NS_GREEN",  ns_green,       BASELINE_SIGNALS["NS_GREEN"]),
        ("NS_YELLOW", YELLOW_DURATION, BASELINE_SIGNALS["NS_YELLOW"]),
        ("EW_GREEN",  ew_green,       BASELINE_SIGNALS["EW_GREEN"]),
        ("EW_YELLOW", YELLOW_DURATION, BASELINE_SIGNALS["EW_YELLOW"]),
    ]

    new_phases = []
    for _name, dur, state in phase_plan:
        new_phases.append(traci.trafficlight.Phase(dur, state))

    new_logic = traci.trafficlight.Logic(
        programID         = program_label,
        type              = 0,             # 0 = static (not actuated)
        currentPhaseIndex = 0,
        phases            = new_phases,
        subParameter      = {},
    )

    traci.trafficlight.setProgramLogic(tl_id, new_logic)
    traci.trafficlight.setProgram(tl_id, program_label)

    cycle = sum(p.duration for p in new_phases)
    print(f"[TL]  Fixed timer '{program_label}' set on junction '{tl_id}' "
          f"({len(new_phases)} phases, {cycle}s cycle)")
    for i, (name, _dur, _state) in enumerate(phase_plan):
        p = new_phases[i]
        print(f"      Phase {i} ({name:12s}): {p.duration:3.0f}s  state={p.state}")

    return new_phases


# ── Simulation Runner ─────────────────────────────────────────────────────────

def run_simulation(gui: bool = False,
                   preset: str = "naive",
                   route_file: str | None = None) -> tuple[list[dict], dict]:
    """
    Main simulation loop.

    Launches SUMO, configures the fixed timer, collects metrics every step,
    saves the CSV, and prints the terminal report.

    Args:
        gui:    If True, launch sumo-gui (visual); else launch sumo (headless).
        preset: Timer preset name — "naive" (45/45) or "tuned" (55/35).

    Returns:
        (records list, emergency_log dict)
    """
    timer = TIMER_PRESETS[preset]
    ns_green = timer["ns_green"]
    ew_green = timer["ew_green"]
    timer_label = timer["label"]

    # Output CSV name varies by preset
    if preset == "naive":
        output_csv = OUTPUT_CSV                           # data/baseline_results.csv
    else:
        output_csv = DATA_DIR / f"baseline_{preset}_results.csv"

    # Pre-flight checks
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    if not NETWORK_FILE.exists():
        print(f"\n[ERROR] Network file not found: {NETWORK_FILE}")
        print("  Run first: python scripts/build_network.py")
        sys.exit(1)

    if not CONFIG_FILE.exists():
        print(f"\n[ERROR] Config not found: {CONFIG_FILE}")
        sys.exit(1)

    sumo_binary = find_sumo_binary(gui=gui)

    sumo_cmd = [
        sumo_binary,
        "-c",            str(CONFIG_FILE),
        "--step-length", str(STEP_LENGTH),
        "--no-warnings",
        "--quit-on-end",
    ]
    if route_file is not None:
        sumo_cmd += ["--route-files", str(route_file)]

    print("\n" + "═" * 60)
    print(f"  ATCS-GH Phase 1 — Baseline Fixed-Timer Simulation ({preset})")
    print("═" * 60)
    print(f"  Mode    : {'GUI (visual)' if gui else 'Headless (fast)'}")
    print(f"  Duration: {SIM_DURATION}s ({SIM_DURATION/3600:.0f} hours)")
    print(f"  Timer   : {timer_label}")
    print(f"  Phases  : {ns_green}s NS-green / {YELLOW_DURATION}s yellow / "
          f"{ew_green}s EW-green / {YELLOW_DURATION}s yellow")
    print(f"  Output  : {output_csv}")
    print("═" * 60)

    # Connect TraCI to SUMO
    traci.start(sumo_cmd)
    print("\n[TraCI] Connected to SUMO")

    # Install our fixed timer (overrides auto-generated TL)
    configured_phases = configure_fixed_timer(
        TL_ID,
        ns_green=ns_green,
        ew_green=ew_green,
        program_label=f"fixed_{preset}",
    )

    # Initialise metrics logger
    logger = MetricsLogger(output_path=output_csv)

    wall_start   = time.time()
    last_pct     = -1

    print(f"\n[SIM] Running {SIM_DURATION} steps... (Ctrl+C to abort)\n")

    try:
        for step_num in range(1, SIM_DURATION + 1):
            traci.simulationStep()

            current_time = traci.simulation.getTime()

            # Determine human-readable phase name
            raw_phase    = traci.trafficlight.getPhase(TL_ID)
            phase_name   = PHASE_NAMES.get(raw_phase, f"phase_{raw_phase}")

            # Collect and store metrics for this step
            logger.step(current_time=current_time, tl_phase_name=phase_name)

            # Progress indicator every 10%
            pct = int(step_num / SIM_DURATION * 100)
            if pct % 10 == 0 and pct != last_pct:
                elapsed = time.time() - wall_start
                completed = logger.total_arrived
                print(f"  [{pct:3d}%] t={step_num:5d}s  "
                      f"completed={completed:5d}  "
                      f"wall={elapsed:5.1f}s")
                last_pct = pct

            # Early exit if all vehicles have finished (saves time on light traffic)
            if traci.simulation.getMinExpectedNumber() == 0:
                print(f"\n[SIM] All vehicles completed at t={step_num}s — stopping early.")
                break

    except KeyboardInterrupt:
        print("\n[SIM] Interrupted by user.")

    finally:
        traci.close()
        total_wall = time.time() - wall_start
        print(f"[TraCI] Disconnected. Wall-clock time: {total_wall:.1f}s")

    # Save CSV results
    logger.save()

    # Print summary report
    stats = logger.summary_stats()
    print_report(
        sim_time      = int(traci.simulation.getTime()) if False else step_num,
        stats         = stats,
        preset        = preset,
        ns_green      = ns_green,
        ew_green      = ew_green,
        output_csv    = output_csv,
    )

    return logger.records, logger.emergency_log


# ── Terminal Report ───────────────────────────────────────────────────────────

def print_report(sim_time: int, stats: dict, *,
                 preset: str = "naive",
                 ns_green: int = 45,
                 ew_green: int = 45,
                 output_csv: Path = OUTPUT_CSV) -> None:
    """
    Print a formatted performance summary to the terminal.
    This is the "headline result" for Phase 1 that the AI must beat in Phase 2.
    """
    if not stats:
        print("[Report] No statistics available.")
        return

    edge_labels = {
        "ACH_N2J": "Achimota Forest Rd from Nsawam (2-lane)",
        "ACH_S2J": "Achimota Forest Rd from CBD    (2-lane)",
        "AGG_E2J": "Aggrey Street                  (2-lane)",
        "GUG_W2J": "Guggisberg Street              (1-lane)",
    }

    avg_wait    = stats["overall_avg_wait"]
    ai_target   = round(avg_wait * 0.60, 2)   # Phase 2 target: 40% reduction
    cycle       = ns_green + YELLOW_DURATION + ew_green + YELLOW_DURATION

    print("\n" + "═" * 62)
    print(f"  ATCS-GH  |  BASELINE REPORT ({preset.upper()})  |  Phase 1")
    print("═" * 62)
    print(f"  Generated : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Simulated : {sim_time}s  ({sim_time / 3600:.2f} hours)")
    print(f"  TL Timer  : {ns_green}s NS-green / {YELLOW_DURATION}s yellow "
          f"/ {ew_green}s EW-green  ({cycle}s cycle)")
    print()
    print(f"  ┌── OVERALL PERFORMANCE ────────────────────────────┐")
    print(f"  │  Vehicles completed journey  : {stats['total_completed']:>8,}           │")
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
        es = stats["edge_stats"].get(edge, {})
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
        print(f"  NOTE: Fixed timer cannot preempt for emergencies.")
        print(f"        Phase 2 AI will reduce emergency wait to ~0s.")
    else:
        print("  No emergency vehicles were tracked in this run.")

    print()
    print(f"  ── Phase 2 Target ─────────────────────────────────────")
    print(f"     Avg wait: {avg_wait:.2f}s  →  target < {ai_target:.2f}s  (40% reduction)")
    print(f"     Results saved to: {output_csv.relative_to(PROJECT_ROOT)}")
    print("═" * 62 + "\n")


# ── Entry Point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ATCS-GH Phase 1: Baseline fixed-timer simulation"
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="Launch SUMO with GUI (slower but lets you watch the simulation)",
    )
    parser.add_argument(
        "--tuned",
        action="store_true",
        help="Use demand-proportional 55s/35s green split instead of naive 45s/45s. "
             "Saves to data/baseline_tuned_results.csv",
    )
    parser.add_argument(
        "--scenario",
        type=str,
        default=None,
        help="Demand scenario name (e.g. evening_rush). Uses default routes if not set.",
    )
    args = parser.parse_args()
    preset = "tuned" if args.tuned else "naive"
    route_file = None
    if args.scenario:
        route_file = str(SIM_DIR / "scenarios" / f"{args.scenario}.rou.xml")
    run_simulation(gui=args.gui, preset=preset, route_file=route_file)
