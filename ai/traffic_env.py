#!/usr/bin/env python3
from __future__ import annotations
"""
ATCS-GH | Traffic Environment — Achimota/Neoplan Junction
══════════════════════════════════════════════════════════
Gym-style SUMO environment for training the DQN agent.
Calibrated to the Achimota/Neoplan Junction on the N6 Nsawam Road, Accra.
GPS: 5.6216 N, 0.2193 W  |  Part of ATMC smart signal network.

Design principles:
  - Agent decides every DECISION_INTERVAL simulation seconds (5s default).
    SUMO still runs at 1-second resolution internally.
  - A custom "ai_control" TL program (1M-second phase durations) prevents
    SUMO from ever auto-advancing phases. The agent is the sole controller.
  - Emergency preemption is a HARD SAFETY LAYER inside step().
  - SUMO seed is parameterised for varied training episodes.

State vector (42 dims):
  [lq_0..lq_6,                  7  per-lane queue counts      (/ MAX_QUEUE_LANE)
   ls_0..ls_6,                  7  per-lane mean speeds       (/ MAX_SPEED)
   lw_0..lw_6,                  7  per-lane wait times        (/ MAX_WAIT)
   q_N, q_S, q_E, q_W,         4  approach queue totals      (/ MAX_QUEUE)
   ph_0..ph_7,                  8  one-hot phase encoding (8 phases)
   t_phase,                     1  normalised time in phase   (/ MAX_PHASE_T)
   em_N, em_S, em_E, em_W,     4  emergency vehicle flags (binary)
   pw_0..pw_3]                  4  pedestrian waiting counts  (/ MAX_PED_QUEUE)

  Lanes: ACH_N2J_1/2, ACH_S2J_1/2, AGG_E2J_1/2, GUG_W2J_1/2
  (Lane 0 on each edge is the pedestrian sidewalk)

Actions (7):
  0 -> keep current phase  (HOLD)
  1 -> switch to NS_THROUGH (N/S straight + right)
  2 -> switch to NS_LEFT    (N/S protected left turn)
  3 -> switch to EW_THROUGH (E/W straight + right)
  4 -> switch to EW_LEFT    (E/W protected left turn)
  5 -> switch to NS_ALL     (N/S all movements — unprotected)
  6 -> switch to EW_ALL     (E/W all movements — unprotected)
"""

import os
import sys
import shutil
import numpy as np
from pathlib import Path


# ── SUMO / TraCI bootstrapping ────────────────────────────────────────────────

def _bootstrap_sumo() -> str:
    """Locate SUMO and add TraCI tools to sys.path. Returns SUMO_HOME."""
    home = os.environ.get("SUMO_HOME")
    if home is None:
        try:
            import sumo as _sp
            home = _sp.SUMO_HOME
            os.environ["SUMO_HOME"] = home
        except ImportError:
            pass
    if home is None:
        for candidate in [
            "/opt/homebrew/opt/sumo/share/sumo",
            "/opt/homebrew/share/sumo",
            "/usr/local/share/sumo",
            "/usr/share/sumo",
        ]:
            if os.path.isdir(candidate):
                home = candidate
                os.environ["SUMO_HOME"] = candidate
                break
    if home is None:
        raise RuntimeError(
            "SUMO not found. Install via: pip install eclipse-sumo\n"
            "or: brew tap dlr-ts/sumo && brew install sumo"
        )
    tools = os.path.join(home, "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    return home


SUMO_HOME = _bootstrap_sumo()

try:
    import traci
    import traci.exceptions
except ImportError as e:
    raise ImportError(
        f"Cannot import traci: {e}\n"
        f"Ensure SUMO_HOME/tools is in sys.path (SUMO_HOME={SUMO_HOME})"
    ) from e


# ── Constants ─────────────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SIM_DIR      = PROJECT_ROOT / "simulation"
CONFIG_FILE  = SIM_DIR / "intersection.sumocfg"

TL_ID          = "J0"
INCOMING_EDGES = ["ACH_N2J", "ACH_S2J", "AGG_E2J", "GUG_W2J"]
INCOMING_LANES = [
    "ACH_N2J_1", "ACH_N2J_2",   # Achimota Forest Rd from Nsawam (vehicle lanes)
    "ACH_S2J_1", "ACH_S2J_2",   # Achimota Forest Rd from CBD    (vehicle lanes)
    "AGG_E2J_1", "AGG_E2J_2",   # Aggrey Street from east        (vehicle lanes)
    "GUG_W2J_1", "GUG_W2J_2",   # Guggisberg Street from west    (vehicle lanes)
]
# Note: lane index 0 on each edge is the pedestrian sidewalk
EMERGENCY_TYPE = "emergency"

# Pedestrian crossing infrastructure (from rebuilt network with sidewalks)
CROSSING_EDGES = [":J0_c0", ":J0_c1", ":J0_c2", ":J0_c3"]
WALKING_AREAS  = [":J0_w0", ":J0_w1", ":J0_w2", ":J0_w3"]

# Phase indices -- 8 phases for through + left-turn separation
# Connection mapping (16 vehicle + 4 crossing = 20 link indices).
# As of the lane-restricted rebuild, each approach has ONE through connection
# (from lane 1 only — the lane-2-straight connection was removed so that
# lane 2 is exclusively for left-turners / u-turners). Layout:
#   pos 0-3:   ACH_N2J  -> right(0), straight(1), left(2), uturn(3)
#   pos 4-7:   AGG_E2J  -> right(4), straight(5), left(6), uturn(7)
#   pos 8-11:  ACH_S2J  -> right(8), straight(9), left(10), uturn(11)
#   pos 12-15: GUG_W2J  -> right(12), straight(13), left(14), uturn(15)
#   pos 16-19: crossings -> c0_N(16), c1_E(17), c2_S(18), c3_W(19)
#
# Pedestrian crossings piggyback on vehicle phases:
#   NS phases: E/W crossings (c1,c3) green, N/S crossings (c0,c2) red
#   EW phases: N/S crossings (c0,c2) green, E/W crossings (c1,c3) red
#   Yellow/clearance: all crossings red
NS_THROUGH = 0   # N/S straight + right protected, left blocked
NS_LEFT    = 1   # N/S left protected, right permissive
NS_YELLOW  = 2   # N/S clearing
EW_THROUGH = 3   # E/W straight + right protected, left blocked
EW_LEFT    = 4   # E/W left protected, right permissive
EW_YELLOW  = 5   # E/W clearing
NS_ALL     = 6   # N/S all movements green (unprotected, matches baseline)
EW_ALL     = 7   # E/W all movements green (unprotected, matches baseline)

NUM_PHASES = 8

PHASE_NAMES = {
    0: "NS_THROUGH", 1: "NS_LEFT", 2: "NS_YELLOW",
    3: "EW_THROUGH", 4: "EW_LEFT", 5: "EW_YELLOW",
    6: "NS_ALL",     7: "EW_ALL",
}

# 20-character signal state strings for setRedYellowGreenState().
# Link layout (16 vehicle + 4 crossings = 20):
#   N(0-3):   right, straight, left, uturn   — ACH_N2J
#   E(4-7):   right, straight, left, uturn   — AGG_E2J
#   S(8-11):  right, straight, left, uturn   — ACH_S2J
#   W(12-15): right, straight, left, uturn   — GUG_W2J
#   Crossings(16-19): c0(N), c1(E), c2(S), c3(W)
PHASE_SIGNALS = {
    #                N---E---S---W---XWLK
    NS_THROUGH: "GGrrrrrrGGrrrrrrrGrG",  # N/S straight+right protected; left/uturn red; EW crossings green
    NS_LEFT:    "grGGrrrrgrGGrrrrrGrG",  # N/S protected left+uturn; right permissive; straight red
    NS_YELLOW:  "yyyyrrrryyyyrrrrrrrr",   # N/S yellow; all crossings red
    EW_THROUGH: "rrrrGGrrrrrrGGrrGrGr",  # E/W straight+right protected; left/uturn red; NS crossings green
    EW_LEFT:    "rrrrgrGGrrrrgrGGGrGr",  # E/W protected left+uturn; right permissive; straight red
    EW_YELLOW:  "rrrryyyyrrrryyyyrrrr",   # E/W yellow; all crossings red
    NS_ALL:     "GGGrrrrrGGGrrrrrrGrG",  # N/S right+straight+left protected, uturn RED (matches baseline)
    EW_ALL:     "rrrrGGGrrrrrGGGrGrGr",  # E/W right+straight+left protected, uturn RED (matches baseline)
    # NOTE: was permissive ('g') left+uturn — turners yielded to oncoming straight,
    #   stalled in the junction box and deadlocked under load. Baseline keeps uturn
    #   red and left protected for exactly this reason; aligned 2026-06-09.
}

# Green phases (non-yellow)
GREEN_PHASES = {NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT, NS_ALL, EW_ALL}

# Which edges get green in each green phase
PHASE_TO_EDGES = {
    NS_THROUGH: ["ACH_N2J", "ACH_S2J"],
    NS_LEFT:    ["ACH_N2J", "ACH_S2J"],
    EW_THROUGH: ["AGG_E2J", "GUG_W2J"],
    EW_LEFT:    ["AGG_E2J", "GUG_W2J"],
    NS_ALL:     ["ACH_N2J", "ACH_S2J"],
    EW_ALL:     ["AGG_E2J", "GUG_W2J"],
}
# Which green phases serve each incoming edge (for emergency preemption)
EDGE_TO_GREENS = {
    "ACH_N2J": [NS_THROUGH, NS_LEFT, NS_ALL],
    "ACH_S2J": [NS_THROUGH, NS_LEFT, NS_ALL],
    "AGG_E2J": [EW_THROUGH, EW_LEFT, EW_ALL],
    "GUG_W2J": [EW_THROUGH, EW_LEFT, EW_ALL],
}

# Action constants
# REALISM FIX (2026-06-11): ACTION_NS_ALL / ACTION_EW_ALL removed. The all-green
# phases greened the protected-left arrow AND oncoming through simultaneously —
# left-turners entered the junction box against oncoming traffic and blocked it.
# The real Achimota junction (and the visualizer's fixed timer) runs protected
# lefts: through and left arrows NEVER green together. The agent now works with
# the same phase vocabulary as the real junction. (NS_ALL/EW_ALL phase strings
# remain defined below only for state-encoding compatibility; they are
# unreachable through the action space.)
ACTION_HOLD       = 0
ACTION_NS_THROUGH = 1
ACTION_NS_LEFT    = 2
ACTION_EW_THROUGH = 3
ACTION_EW_LEFT    = 4

# Map action index → target green phase
ACTION_TO_PHASE = {
    ACTION_NS_THROUGH: NS_THROUGH,
    ACTION_NS_LEFT:    NS_LEFT,
    ACTION_EW_THROUGH: EW_THROUGH,
    ACTION_EW_LEFT:    EW_LEFT,
}

ACTION_NAMES = ["HOLD", "NS_THROUGH", "NS_LEFT", "EW_THROUGH", "EW_LEFT"]

# NOTE: the old ActionSanitizer / sanitize_action machinery was deleted
# (2026-06-11) along with the ALL-phase actions it existed to clean up.
# With a protected-left-only action space there is nothing to sanitize.

# ── State normalisation ───────────────────────────────────────────────────────
# AUDIT FIX (2026-06-07): Raised after the first full retrain (250 eps, mixed
# scenarios) produced a SPLIT policy — excellent on light traffic (off_peak /
# weekend, peak queues 14-44, avg wait 3-4s) but CATASTROPHIC on heavy traffic
# (morning/evening rush + heavy_emergency at 2640 veh/hr, peak queues 600-760,
# avg wait 700-880s vs an 81.8s fixed-timer baseline on the SAME demand).
#
# Root cause: with MAX_QUEUE=50, heavy-traffic queues normalise to 12-15× over
# 1.0 on EVERY approach at once. The "no clip so overflow still informs the net"
# theory failed in practice — when all dims saturate together the relative
# signal (which approach is worst) is destroyed, activations blow up, and the
# policy degenerates into gridlock. The agent did well *exactly* when queues
# stayed under 50 and failed *exactly* when they exceeded it — a perfect
# correlation pinning the cause to normaliser scale.
#
# Fix: size the caps to the actionable danger zone so the agent can perceive
# queues climbing (50→100→150) and intervene BEFORE runaway gridlock. A good
# policy keeps heavy-traffic queues well under 150 (baseline does), so this
# range stays mostly unsaturated under competent control.
# NOTE: train + inference MUST use the same normalisers — retrain after changing.
MAX_QUEUE      = 150.0   # vehicles per approach (was 50 — heavy traffic needs headroom)
MAX_QUEUE_LANE = 75.0    # vehicles per lane (was 25)
MAX_SPEED      = 13.89   # 50 km/h in m/s (lane speed normalisation)
MAX_WAIT       = 1200.0  # seconds (was 600 — heavy-traffic waits exceed 600 pre-convergence)
MAX_PHASE_T    = 96.0    # one full 96-second TL cycle
MAX_PED_QUEUE  = 15.0    # max pedestrians waiting at one walking area

# ── Environment parameters ────────────────────────────────────────────────────
DECISION_INTERVAL  = 5     # SUMO seconds between agent decisions
MIN_GREEN_THROUGH  = 10    # seconds before through/all-phase switch (anti-flicker)
MIN_GREEN_LEFT     = 8     # left-turn phases serve fewer vehicles — shorter hold
YELLOW_DURATION    = 3     # seconds of yellow clearance
SIM_DURATION       = 7200  # seconds per episode (matches baseline)

# Warm-start expert (guided exploration). The KEY lesson from the 2026-06-09
# diagnosis: heavy demand is cleared by SUSTAINED greens, not fast switching.
# A 60/30 timer gridlocks 1901 veh/hr at 811s; a 90/45 (longer green) clears the
# same demand at 22s. So the expert holds the current green until it drains
# (gap-out) or hits a max, instead of flipping on the instantaneous bigger queue.
EXPERT_GAP_QUEUE    = 3     # a direction is "empty" at/below this (gap-out)
EXPERT_NS_GREEN     = 90    # N/S through green (s) — the heavy group, ~66% of demand
EXPERT_EW_GREEN     = 45    # E/W through green (s). 90/45 is the plan proven to clear 1901
EXPERT_NS_LEFT_GREEN = 15   # protected left-arrow greens (match the viz fixed timer)
EXPERT_EW_LEFT_GREEN = 10
# Left-turn lanes (lane _2 on each edge is reserved for left + uturn)
_LEFT_LANES_NS  = ("ACH_N2J_2", "ACH_S2J_2")
_LEFT_LANES_EW  = ("AGG_E2J_2", "GUG_W2J_2")
_THRU_LANES_NS  = ("ACH_N2J_1", "ACH_S2J_1")
_THRU_LANES_EW  = ("AGG_E2J_1", "GUG_W2J_1")
                            # veh/hr at ~21s; demand-matched split, not 50/50.

# Exported constants for use by train_agent.py / run_ai.py
STATE_SIZE  = 45   # 8*3 + 4 + 8(phases) + 1 + 4(emergency) + 4(ped_wait)
ACTION_SIZE = 5   # was 7 — NS_ALL/EW_ALL removed (protected-left realism fix)

# ── Reward weights (redesigned 2026-06-09 — gridlock-trap fix) ────────────────
# Diagnosis: the previous reward used ABSOLUTE queue (-0.2·queue) and ABSOLUTE
# max-wait (-0.4·excess) penalties. Both diverge without bound once the junction
# saturates, so a heavy episode scored ≈ -1.5M while a light one scored ≈ +5k.
# Two failures resulted:
#   1. A single Q-net cannot regress targets spanning a ~300× range across
#      scenarios → destructive cross-scenario interference.
#   2. In gridlock every action's reward saturated at "hugely negative", so the
#      agent got no gradient telling it which action was *less* bad → it could
#      never learn its way out. Light traffic never saturated, so it learned
#      instantly. Hence the permanent light-genius / heavy-gridlock split.
# Redesign: every penalty is NORMALISED to a reference scale and the per-block
# reward is CLIPPED to ±REWARD_CLIP. Heavy traffic now yields a finite,
# discriminative gradient (queue 100 scores better than queue 400) and the
# cross-scenario reward spread collapses from ~300× to ~10×.
QUEUE_REF     = 40.0   # reference queue (≈ baseline peak) — congestion normaliser
WAIT_REF      = 90.0   # reference excess-wait (s) — max-wait normaliser
PED_REF       = 10.0   # reference pedestrian backlog
REWARD_CLIP   = 40.0   # per-decision-block reward saturates at ±this

W_QUEUE_ABS   = 4.0    # congestion penalty     × (total_queue / QUEUE_REF)
W_QUEUE_DELTA = 2.0    # queue-growth penalty    × (growth / QUEUE_REF)
W_ARRIVED     = 1.0    # throughput reward       × n_arrived (~0-15 per block)
W_EMERGENCY   = 8.0    # emergency-wait penalty  × n_emerg_waiting (bounded, strong)
W_FLICKER     = 2.0    # anti-flicker penalty
W_BALANCE     = 2.0    # fairness bonus          × balance∈[0,1]
W_MAX_WAIT    = 4.0    # worst-approach penalty  × min(excess / WAIT_REF, 3)
W_PED_WAIT    = 1.0    # pedestrian-wait penalty × min(n_ped / PED_REF, 2)
FAIR_WAIT_THRESH = 30.0  # seconds — acceptable wait; penalty kicks in above this


# ── Environment ───────────────────────────────────────────────────────────────

class TrafficEnv:
    """
    SUMO traffic signal environment for DQN training.

    Gym-style interface:
        state                       = env.reset(seed=42)
        state, reward, done, info   = env.step(action)
        env.close()

    SUMO process management:
        reset() kills any existing SUMO process and launches a fresh one.
        close() terminates SUMO cleanly.
        Training loops should call env.close() at the end of each episode
        (or rely on reset() to do it automatically).
    """

    # Class-level flag so the link-layout diagnostic prints once per process
    # (avoids spamming during 250-episode training runs while still surfacing
    # a verifiable record of how SUMO ordered the controlled links).
    _layout_diagnostic_printed: bool = False

    def __init__(self, gui: bool = False, verbose: bool = False,
                 route_file: str | None = None):
        self.gui        = gui
        self.verbose    = verbose
        self.route_file = route_file  # Override route file (None = use sumocfg default)

        # Internal state (reset every episode)
        self._connected        = False
        self._phase            = NS_THROUGH
        self._phase_timer      = 0        # sim-seconds since last phase change
        self._in_yellow        = False
        self._yellow_countdown = 0
        self._next_green       = NS_THROUGH
        self._sim_step         = 0        # cumulative simulation seconds
        self._prev_total_queue = 0.0      # for delta-queue reward component

        # Per-episode stats (available after episode ends)
        self.total_arrived: int   = 0
        self.episode_rewards: list[float] = []
        self.episode_queues:  list[float] = []
        self.episode_waits:   list[float] = []
        self.emergency_log:   dict[str, float] = {}  # vid → max_wait_s

    # ── Gym Interface ─────────────────────────────────────────────────────────

    def reset(self, seed: int | None = None) -> np.ndarray:
        """
        Restart the simulation and return the initial state vector.

        Args:
            seed: SUMO random seed for this episode. Vary across training
                  episodes to prevent overfitting to one vehicle sequence.
                  None = SUMO default (deterministic).
        """
        self.close()
        self._start_sumo(seed=seed)
        self._configure_tl_for_ai_control()

        # Reset all bookkeeping
        self._phase            = NS_THROUGH
        self._phase_timer      = 0
        self._in_yellow        = False
        self._yellow_countdown = 0
        self._next_green       = NS_THROUGH
        self._sim_step         = 0
        self._prev_total_queue = 0.0

        self.total_arrived    = 0
        self.episode_rewards  = []
        self.episode_queues   = []
        self.episode_waits    = []
        self.emergency_log    = {}

        # Advance one step to populate TraCI state
        traci.simulationStep()
        self._sim_step = 1

        return self._build_state()

    def step(self, action: int) -> tuple[np.ndarray, float, bool, dict]:
        """
        Apply action, advance DECISION_INTERVAL simulation seconds, return
        (next_state, reward, done, info).

        The inner loop runs DECISION_INTERVAL SUMO steps. During this time:
          • Yellow transitions are handled automatically (no agent involvement).
          • Emergency preemption may override the requested action.
          • Per-step metrics are accumulated for reward computation.

        Args:
            action: 0=HOLD, 1=NS_THROUGH, 2=NS_LEFT, 3=EW_THROUGH, 4=EW_LEFT,
                    5=NS_ALL, 6=EW_ALL

        Returns:
            next_state  — 38-dim normalised state vector
            reward      — scalar reward for this decision block
            done        — True if episode has ended
            info        — diagnostic dict (phase, arrived, queues, preempted, ...)
        """
        if not self._connected:
            raise RuntimeError("Call env.reset() before env.step()")

        # ── Safety layer: emergency preemption ───────────────────────────────
        preempted, forced_phase = self._check_emergency_preemption()
        if preempted:
            if forced_phase != self._phase and self._can_switch():
                self._initiate_switch(target_green=forced_phase)

        # ── Initiate switch if agent chose a target phase ────────────────────
        elif action != ACTION_HOLD and self._can_switch():
            target = ACTION_TO_PHASE.get(action)
            if target is not None and target != self._phase:
                self._initiate_switch(target_green=target)

        # ── Advance DECISION_INTERVAL simulation steps ────────────────────────
        # Metrics accumulated over all steps in this block
        block_arrived   = 0
        block_emerg_max = 0
        final_queues    = [0.0] * len(INCOMING_EDGES)
        final_waits     = [0.0] * len(INCOMING_EDGES)

        for _ in range(DECISION_INTERVAL):
            # Handle yellow countdown: auto-complete switch
            if self._in_yellow:
                self._yellow_countdown -= 1
                if self._yellow_countdown <= 0:
                    self._complete_switch()

            traci.simulationStep()
            self._sim_step    += 1
            self._phase_timer += 1

            # Collect per-step arrivals
            block_arrived += traci.simulation.getArrivedNumber()

            # Emergency vehicles stopped at red this step
            n_emerg = sum(
                1 for vid in traci.vehicle.getIDList()
                if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE
                and traci.vehicle.getSpeed(vid) < 0.1
            )
            block_emerg_max = max(block_emerg_max, n_emerg)

            # Track emergency vehicle max wait (for episode log)
            self._track_emergency_vehicles()

            # Check if simulation ran out of vehicles early
            if traci.simulation.getMinExpectedNumber() == 0:
                break

        # Capture per-edge metrics from the end of the block
        edge_metrics = self._collect_edge_metrics()
        for i, edge in enumerate(INCOMING_EDGES):
            final_queues[i] = edge_metrics[edge]["queue"]
            final_waits[i]  = edge_metrics[edge]["wait"]

        # ── Reward ────────────────────────────────────────────────────────────
        total_queue = float(sum(final_queues))
        self.total_arrived += block_arrived

        min_g = (MIN_GREEN_LEFT if self._phase in (NS_LEFT, EW_LEFT)
                 else MIN_GREEN_THROUGH)
        # Count pedestrians waiting at junction walking areas
        ped_counts = self._get_pedestrian_counts()
        total_ped_waiting = int(sum(ped_counts))

        reward = self._compute_reward(
            total_queue        = total_queue,
            prev_total_queue   = self._prev_total_queue,
            n_arrived          = block_arrived,
            n_emerg_waiting    = block_emerg_max,
            switched_too_soon  = (action != ACTION_HOLD and not preempted
                                  and self._phase_timer < min_g),
            queue_distribution = final_queues,
            wait_distribution  = final_waits,
            n_ped_waiting      = total_ped_waiting,
        )
        self._prev_total_queue = total_queue

        # Track episode stats
        avg_wait = float(np.mean(final_waits)) if final_waits else 0.0
        self.episode_rewards.append(reward)
        self.episode_queues.append(total_queue)
        self.episode_waits.append(avg_wait)

        # ── Termination ───────────────────────────────────────────────────────
        done = (
            self._sim_step >= SIM_DURATION
            or traci.simulation.getMinExpectedNumber() == 0
        )

        next_state = self._build_state()

        info = {
            "sim_step":      self._sim_step,
            "phase":         PHASE_NAMES.get(self._phase, "?"),
            "phase_timer":   self._phase_timer,
            "arrived_block": block_arrived,
            "total_arrived": self.total_arrived,
            "queues":        final_queues,
            "avg_wait":      avg_wait,
            "preempted":     preempted,
            "reward":        reward,
        }

        return next_state, reward, done, info

    def close(self) -> None:
        """Terminate the SUMO process and disconnect TraCI."""
        if self._connected:
            try:
                traci.close()
            except Exception:
                pass
            self._connected = False

    # ── Episode Summary Properties ────────────────────────────────────────────

    @property
    def episode_avg_wait(self) -> float:
        return float(np.mean(self.episode_waits)) if self.episode_waits else 0.0

    @property
    def episode_peak_queue(self) -> int:
        return int(max(self.episode_queues)) if self.episode_queues else 0

    @property
    def episode_total_reward(self) -> float:
        return float(sum(self.episode_rewards))

    # ── State Construction ────────────────────────────────────────────────────

    def _build_state(self) -> np.ndarray:
        """Construct the 42-dimensional normalised state vector."""
        lane_m = self._collect_lane_metrics()
        edge_m = self._collect_edge_metrics()

        # Per-lane features (7 lanes x 3 = 21 dims)
        lane_queues = np.array([lane_m[l]["queue"] for l in INCOMING_LANES], dtype=np.float32)
        lane_speeds = np.array([lane_m[l]["speed"] for l in INCOMING_LANES], dtype=np.float32)
        lane_waits  = np.array([lane_m[l]["wait"]  for l in INCOMING_LANES], dtype=np.float32)

        # Per-approach aggregate queues (4 dims)
        approach_queues = np.array([edge_m[e]["queue"] for e in INCOMING_EDGES], dtype=np.float32)

        # One-hot encode the current phase (8 dims)
        phase_vec = np.zeros(NUM_PHASES, dtype=np.float32)
        phase_vec[self._phase] = 1.0

        # Normalised time in current phase
        t_norm = np.float32(min(self._phase_timer / MAX_PHASE_T, 1.0))

        # Emergency vehicle presence per approach (binary, 4 dims)
        emerg_flags = self._get_emergency_flags()

        # Pedestrian waiting counts per walking area (4 dims)
        ped_counts = self._get_pedestrian_counts()

        state = np.concatenate([
            lane_queues / MAX_QUEUE_LANE,   # 7 values
            lane_speeds / MAX_SPEED,         # 7 values
            lane_waits  / MAX_WAIT,          # 7 values
            approach_queues / MAX_QUEUE,     # 4 values
            phase_vec,                       # 8 values
            [t_norm],                        # 1 value
            emerg_flags,                     # 4 values
            ped_counts / MAX_PED_QUEUE,      # 4 values
        ])                                   # = 42 total
        return state.astype(np.float32)

    # ── Reward Computation ────────────────────────────────────────────────────

    def _compute_reward(self,
                        total_queue:       float,
                        prev_total_queue:  float,
                        n_arrived:         int,
                        n_emerg_waiting:   int,
                        switched_too_soon: bool,
                        queue_distribution: list[float],
                        wait_distribution:  list[float] | None = None,
                        n_ped_waiting:     int = 0) -> float:
        """
        Multi-component reward function:

        1. Absolute queue penalty  — penalises sustained congestion
        2. Queue growth penalty    — penalises net queue increase (asymmetric)
        3. Throughput bonus        — rewards vehicles completing journeys
        4. Emergency penalty       — large negative when ambulance waits at red
        5. Flicker penalty         — discourages rapid phase switching
        6. Balance bonus           — rewards equal queue distribution across approaches
        7. Max-wait penalty        — penalises any single approach waiting too long
                                     (prevents E/W starvation from N/S throughput bias)
        8. Pedestrian wait penalty — penalises waiting pedestrians at crossings
        """
        # All penalties are NORMALISED to a reference scale so heavy traffic
        # produces a finite, discriminative gradient (see weight-block note).

        # 1. Congestion penalty — normalised by QUEUE_REF (was absolute → diverged)
        r_abs   = -W_QUEUE_ABS * (total_queue / QUEUE_REF)

        # 2. Delta: penalise net queue GROWTH only (no reward for shrinkage —
        #    rewarding shrinkage let the agent oscillate phases to farm reward
        #    without improving net throughput).
        delta   = total_queue - prev_total_queue
        r_delta = -W_QUEUE_DELTA * (max(0.0, delta) / QUEUE_REF)

        # 3. Throughput (accumulated over the DECISION_INTERVAL steps)
        r_thru  = W_ARRIVED * n_arrived

        # 4. Emergency vehicle waiting (strong, bounded signal)
        r_emerg = -W_EMERGENCY * n_emerg_waiting

        # 5. Flicker penalty
        r_flick = -W_FLICKER if switched_too_soon else 0.0

        # 6. Balance: lower variance in queue distribution = higher bonus
        if total_queue > 0:
            mean_q    = total_queue / max(len(queue_distribution), 1)
            std_q     = float(np.std(queue_distribution))
            balance   = max(0.0, 1.0 - std_q / (mean_q + 1.0))
            r_balance = W_BALANCE * balance
        else:
            r_balance = W_BALANCE  # zero traffic = maximum balance

        # 7. Max-wait penalty: prevent any single approach from being starved.
        #    Normalised by WAIT_REF and CAPPED so one gridlocked approach cannot
        #    dominate the whole reward (the old unbounded form did exactly that).
        r_max_wait = 0.0
        if wait_distribution:
            worst_wait = max(wait_distribution)
            excess     = max(0.0, worst_wait - FAIR_WAIT_THRESH)
            r_max_wait = -W_MAX_WAIT * min(excess / WAIT_REF, 3.0)

        # 8. Pedestrian waiting penalty — normalised + capped
        r_ped = -W_PED_WAIT * min(n_ped_waiting / PED_REF, 2.0)

        total = (r_abs + r_delta + r_thru + r_emerg
                 + r_flick + r_balance + r_max_wait + r_ped)

        # Clip so cross-scenario Q-targets stay well-conditioned and no single
        # block can blow up the return: bounds per-block reward to ±REWARD_CLIP.
        return float(max(-REWARD_CLIP, min(REWARD_CLIP, total)))

    # ── Expert / warm-start policy ────────────────────────────────────────────

    def _lane_halts(self, lanes: tuple) -> int:
        """Sum of halted vehicles on the given lanes (0 on any TraCI hiccup)."""
        total = 0
        for lane in lanes:
            try:
                total += traci.lane.getLastStepHaltingNumber(lane)
            except traci.TraCIException:
                pass
        return total

    def expert_action(self) -> int:
        """
        Protected-left actuated expert used to guide exploration (warm-start).

        Mirrors how the real Achimota junction (and the visualizer's fixed
        timer) phases traffic: through movements and the left arrow NEVER green
        together. The cycle is THROUGH (long, gap-out or max-green) → protected
        LEFT (short, skipped when no lefts wait) → other axis, with N/S getting
        the longer greens (~66% of demand). Two prior expert designs failed:
        max-pressure thrashing (gridlock from short greens) and all-green
        phases (left-turners blocking the junction box against oncoming
        through). This one holds long greens AND keeps conflicts protected.
        Emergency preemption is handled by the env's safety layer, not here.
        """
        ns_thru = self._lane_halts(_THRU_LANES_NS)
        ew_thru = self._lane_halts(_THRU_LANES_EW)
        ns_left = self._lane_halts(_LEFT_LANES_NS)
        ew_left = self._lane_halts(_LEFT_LANES_EW)
        ns_q = ns_thru + ns_left
        ew_q = ew_thru + ew_left

        if self._phase == NS_THROUGH:
            done = (self._phase_timer >= EXPERT_NS_GREEN
                    or (ns_thru <= EXPERT_GAP_QUEUE
                        and ns_left + ew_q > EXPERT_GAP_QUEUE))
            if not done:
                return ACTION_HOLD
            if ns_left > 0:
                return ACTION_NS_LEFT          # serve the waiting left arrow
            return ACTION_EW_THROUGH if ew_q > 0 else ACTION_HOLD

        if self._phase == NS_LEFT:
            done = (self._phase_timer >= EXPERT_NS_LEFT_GREEN or ns_left == 0)
            if not done:
                return ACTION_HOLD
            return ACTION_EW_THROUGH if ew_q > 0 else ACTION_NS_THROUGH

        if self._phase == EW_THROUGH:
            done = (self._phase_timer >= EXPERT_EW_GREEN
                    or (ew_thru <= EXPERT_GAP_QUEUE
                        and ew_left + ns_q > EXPERT_GAP_QUEUE))
            if not done:
                return ACTION_HOLD
            if ew_left > 0:
                return ACTION_EW_LEFT
            return ACTION_NS_THROUGH if ns_q > 0 else ACTION_HOLD

        if self._phase == EW_LEFT:
            done = (self._phase_timer >= EXPERT_EW_LEFT_GREEN or ew_left == 0)
            if not done:
                return ACTION_HOLD
            return ACTION_NS_THROUGH if ns_q > 0 else ACTION_EW_THROUGH

        # Startup / yellow / legacy ALL phase → serve the bigger axis, through first.
        return ACTION_NS_THROUGH if ns_q >= ew_q else ACTION_EW_THROUGH

    # ── Phase Control ─────────────────────────────────────────────────────────

    def _can_switch(self) -> bool:
        """True if the current green phase has run long enough to switch."""
        if self._in_yellow or self._phase not in GREEN_PHASES:
            return False
        if self._phase in (NS_LEFT, EW_LEFT):
            return self._phase_timer >= MIN_GREEN_LEFT
        return self._phase_timer >= MIN_GREEN_THROUGH

    def _initiate_switch(self, target_green: int | None = None) -> None:
        """
        Begin a phase transition: yellow → next_green.

        Args:
            target_green: Target green phase to switch to.
        """
        if target_green is None:
            return

        # Determine the yellow phase that clears the current green
        if self._phase in (NS_THROUGH, NS_LEFT, NS_ALL):
            yellow = NS_YELLOW
        else:
            yellow = EW_YELLOW

        self._next_green = target_green
        traci.trafficlight.setRedYellowGreenState(TL_ID, PHASE_SIGNALS[yellow])
        self._phase            = yellow
        self._in_yellow        = True
        self._yellow_countdown = YELLOW_DURATION

        if self.verbose:
            print(f"[ENV] t={self._sim_step:4d}s  Switch initiated → "
                  f"{PHASE_NAMES[yellow]} (3s) → {PHASE_NAMES[self._next_green]}")

    def _complete_switch(self) -> None:
        """Yellow has expired — set the next green phase."""
        traci.trafficlight.setRedYellowGreenState(TL_ID, PHASE_SIGNALS[self._next_green])
        self._phase       = self._next_green
        self._in_yellow   = False
        self._phase_timer = 0   # Reset timer when new green starts

        if self.verbose:
            print(f"[ENV] t={self._sim_step:4d}s  Phase → {PHASE_NAMES[self._next_green]}")

    # ── SUMO Management ───────────────────────────────────────────────────────

    def _start_sumo(self, seed: int | None = None) -> None:
        """Launch SUMO and establish TraCI connection."""
        binary = "sumo-gui" if self.gui else "sumo"

        # Locate binary: SUMO_HOME/bin first, then PATH
        bin_path = os.path.join(SUMO_HOME, "bin", binary)
        if not os.path.isfile(bin_path):
            bin_path = shutil.which(binary) or shutil.which("sumo")
        if not bin_path:
            raise RuntimeError(f"SUMO binary '{binary}' not found")

        cmd = [
            bin_path,
            "-c",            str(CONFIG_FILE),
            "--step-length", "1.0",
            "--no-warnings",
            "--quit-on-end",
        ]
        if self.route_file is not None:
            cmd += ["--route-files", str(self.route_file)]
        if seed is not None:
            cmd += ["--seed", str(seed)]

        traci.start(cmd)
        self._connected = True

    def _configure_tl_for_ai_control(self) -> None:
        """
        Install an 'ai_control' TL program with long-duration phases,
        then immediately set NS_THROUGH via setRedYellowGreenState().

        The long-duration program prevents SUMO from auto-advancing.
        All actual signal changes go through setRedYellowGreenState()
        with our custom 20-character PHASE_SIGNALS strings
        (16 vehicle links + 4 pedestrian crossings).
        """
        logics = traci.trafficlight.getAllProgramLogics(TL_ID)
        if not logics:
            if self.verbose:
                print(f"[ENV] WARNING: No TL logic found for '{TL_ID}'")
            return

        orig = logics[0]
        long_phases = [
            traci.trafficlight.Phase(1_000_000, p.state)
            for p in orig.phases
        ]
        ai_logic = traci.trafficlight.Logic(
            programID         = "ai_control",
            type              = 0,        # static
            currentPhaseIndex = 0,
            phases            = long_phases,
            subParameter      = {},
        )
        traci.trafficlight.setProgramLogic(TL_ID, ai_logic)
        traci.trafficlight.setProgram(TL_ID, "ai_control")

        # AUDIT FIX (2026-04-24): Print the actual TraCI controlled-link
        # layout once per process (or every reset when verbose=True) so we
        # can verify our PHASE_SIGNALS assumptions against what netconvert
        # actually produced after the lane-restricted rebuild. The comment
        # block at the top of this file claims connections are ordered
        # N → E → S → W; this print confirms or refutes it from runtime.
        if self.verbose or not TrafficEnv._layout_diagnostic_printed:
            TrafficEnv._layout_diagnostic_printed = True
            try:
                links = traci.trafficlight.getControlledLinks(TL_ID)
                print(f"[ENV] TL '{TL_ID}' controlled-link layout "
                      f"({len(links)} links — verify against PHASE_SIGNALS):")
                for i, link_set in enumerate(links):
                    if link_set:
                        from_lane, to_lane, _via = link_set[0]
                        print(f"        link[{i:2d}]: {from_lane:14s} -> {to_lane}")
                    else:
                        print(f"        link[{i:2d}]: (empty)")
            except traci.exceptions.TraCIException as exc:
                print(f"[ENV] WARNING: Could not fetch link layout: {exc}")

        # Set initial phase using direct signal state string
        traci.trafficlight.setRedYellowGreenState(TL_ID, PHASE_SIGNALS[NS_THROUGH])
        self._phase = NS_THROUGH

        if self.verbose:
            print(f"[ENV] 'ai_control' program installed  "
                  f"({len(long_phases)} phases, direct signal control)")
            for name, sig in PHASE_SIGNALS.items():
                print(f"       {PHASE_NAMES[name]:12s}: {sig}")

    # ── Metric Collection ─────────────────────────────────────────────────────

    def _collect_lane_metrics(self) -> dict[str, dict]:
        """Fetch per-lane queue, speed, and wait time from TraCI."""
        result: dict[str, dict] = {}
        for lane_id in INCOMING_LANES:
            try:
                q = traci.lane.getLastStepHaltingNumber(lane_id)
                s = traci.lane.getLastStepMeanSpeed(lane_id)
                w = traci.lane.getWaitingTime(lane_id)
            except traci.exceptions.TraCIException:
                q, s, w = 0, 0.0, 0.0
            result[lane_id] = {
                "queue": float(q),
                "speed": max(0.0, float(s)),
                "wait":  float(w),
            }
        return result

    def _collect_edge_metrics(self) -> dict[str, dict]:
        """
        Fetch per-edge queue length and average wait time from TraCI.
        Sums over all lanes on each incoming edge.
        """
        result: dict[str, dict] = {}
        for edge in INCOMING_EDGES:
            total_q = 0
            total_w = 0.0
            n_lanes = 0
            try:
                n_lanes = traci.edge.getLaneNumber(edge)
                for idx in range(n_lanes):
                    lid = f"{edge}_{idx}"
                    total_q += traci.lane.getLastStepHaltingNumber(lid)
                    total_w += traci.lane.getWaitingTime(lid)
            except traci.exceptions.TraCIException:
                pass
            result[edge] = {
                "queue": float(total_q),
                "wait":  float(total_w / max(n_lanes, 1)),
            }
        return result

    def _get_emergency_flags(self) -> np.ndarray:
        """Return binary array: 1.0 if any emergency vehicle is on each approach."""
        flags = np.zeros(len(INCOMING_EDGES), dtype=np.float32)
        for i, edge in enumerate(INCOMING_EDGES):
            try:
                for vid in traci.edge.getLastStepVehicleIDs(edge):
                    if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                        flags[i] = 1.0
                        break
            except traci.exceptions.TraCIException:
                pass
        return flags

    def _get_pedestrian_counts(self) -> np.ndarray:
        """Return pedestrian count at each of the 4 junction walking areas."""
        counts = np.zeros(len(WALKING_AREAS), dtype=np.float32)
        for i, wa in enumerate(WALKING_AREAS):
            try:
                counts[i] = float(len(traci.edge.getLastStepPersonIDs(wa)))
            except traci.exceptions.TraCIException:
                pass
        return counts

    def _check_emergency_preemption(self) -> tuple[bool, int | None]:
        """
        Check whether an emergency vehicle is approaching on a currently-red
        approach. If so, return (True, target_green_phase).

        Only preempts if the emergency vehicle is on an INCOMING edge AND
        none of the green phases for that edge are currently active.
        Prefers NS_THROUGH / EW_THROUGH for emergency vehicles.
        """
        for edge in INCOMING_EDGES:
            try:
                for vid in traci.edge.getLastStepVehicleIDs(edge):
                    if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                        continue

                    greens_for_edge = EDGE_TO_GREENS[edge]
                    already_serving = (
                        self._phase in greens_for_edge
                        or (self._in_yellow and self._next_green in greens_for_edge)
                    )
                    if not already_serving:
                        # Prefer the THROUGH phase for emergency vehicles
                        return True, greens_for_edge[0]

            except traci.exceptions.TraCIException:
                pass

        return False, None

    def _track_emergency_vehicles(self) -> None:
        """Update the per-vehicle max accumulated wait time in emergency_log."""
        for vid in traci.vehicle.getIDList():
            if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                continue
            wait = traci.vehicle.getAccumulatedWaitingTime(vid)
            prev = self.emergency_log.get(vid, 0.0)
            if wait > prev:
                self.emergency_log[vid] = wait
