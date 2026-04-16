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
# Connection mapping (23 link indices from intersection.net.xml):
#   pos 0-4:   ACH_N2J -> right(0), straight(1,2), left(3), uturn(4)
#   pos 5-8:   AGG_E2J -> right(5), straight(6), left(7), uturn(8)
#   pos 9-13:  ACH_S2J -> right(9), straight(10,11), left(12), uturn(13)
#   pos 14-18: GUG_W2J -> right(14), straight(15,16), left(17), uturn(18)
#   pos 19-22: crossings -> c0_N(19), c1_E(20), c2_S(21), c3_W(22)
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

# 24-character signal state strings for setRedYellowGreenState()
# Connection layout (20 vehicle + 4 crossings = 24):
#   N(0-4):  right, straight, straight, left, uturn   — ACH_N2J
#   E(5-9):  right, straight, straight, left, uturn   — AGG_E2J
#   S(10-14): right, straight, straight, left, uturn  — ACH_S2J
#   W(15-19): right, straight, straight, left, uturn  — GUG_W2J
#   Crossings(20-23): c0(N), c1(E), c2(S), c3(W)
PHASE_SIGNALS = {
    #                N----E----S----W----XWLK
    NS_THROUGH: "GGGrrrrrrrGGGrrrrrrrrGrG",  # N/S straight+right; left/EW red; EW crossings green
    NS_LEFT:    "grrGrrrrrrgrrGrrrrrrrGrG",  # N/S protected left; straight red
    NS_YELLOW:  "yyyyyrrrrryyyyyrrrrrrrrr",   # N/S yellow; all crossings red
    EW_THROUGH: "rrrrrGGGrrrrrrrGGGrrGrGr",  # E/W straight+right; left/NS red; NS crossings green
    EW_LEFT:    "rrrrrgrrGrrrrrrgrrGrGrGr",  # E/W protected left; straight red
    EW_YELLOW:  "rrrrryyyyyrrrrryyyyyrrrr",   # E/W yellow; all crossings red
    NS_ALL:     "GGGgrrrrrrGGGgrrrrrrrGrG",  # N/S through+right, left permissive (yield)
    EW_ALL:     "rrrrrGGGgrrrrrrGGGgrGrGr",  # E/W through+right, left permissive (yield)
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
ACTION_HOLD       = 0
ACTION_NS_THROUGH = 1
ACTION_NS_LEFT    = 2
ACTION_EW_THROUGH = 3
ACTION_EW_LEFT    = 4
ACTION_NS_ALL     = 5
ACTION_EW_ALL     = 6

# Map action index → target green phase
ACTION_TO_PHASE = {
    ACTION_NS_THROUGH: NS_THROUGH,
    ACTION_NS_LEFT:    NS_LEFT,
    ACTION_EW_THROUGH: EW_THROUGH,
    ACTION_EW_LEFT:    EW_LEFT,
    ACTION_NS_ALL:     NS_ALL,
    ACTION_EW_ALL:     EW_ALL,
}

ACTION_NAMES = ["HOLD", "NS_THROUGH", "NS_LEFT", "EW_THROUGH", "EW_LEFT",
                "NS_ALL", "EW_ALL"]


class ActionSanitizer:
    """Remap permissive-left phases to protected phases, alternating lefts and throughs.

    NS_ALL/EW_ALL would normally light the through-green and the left-arrow
    simultaneously — a "permissive left" that forces left-turners to yield
    to oncoming through traffic. That doesn't match the fixed-timer
    baseline (which serves lefts with a dedicated protected-left phase).

    A naive fix is to collapse NS_ALL → NS_THROUGH, but that starves lefts
    because the trained policy relied on NS_ALL to serve both movements in
    one green. Instead, we **alternate** each time an ALL-phase is picked:

        1st NS_ALL in a row → NS_LEFT    (serve the starved lefts first)
        2nd NS_ALL in a row → NS_THROUGH
        3rd NS_ALL in a row → NS_LEFT
        ...

    Same for EW_ALL ↔ {EW_THROUGH, EW_LEFT}. This preserves the agent's
    directional intent (N/S or E/W priority) while splitting the combined
    movement across two decision ticks, so both through AND protected-left
    eventually get a turn. Training is intentionally untouched so existing
    checkpoints (7-action output head) still load.
    """

    def __init__(self) -> None:
        # Start by serving lefts first when the AI picks an ALL-phase — they
        # were the starved movement under the naive collapse fix.
        self._ns_serve_left_next = True
        self._ew_serve_left_next = True

    def __call__(self, action: int) -> int:
        if action == ACTION_NS_ALL:
            remapped = ACTION_NS_LEFT if self._ns_serve_left_next else ACTION_NS_THROUGH
            self._ns_serve_left_next = not self._ns_serve_left_next
            return remapped
        if action == ACTION_EW_ALL:
            remapped = ACTION_EW_LEFT if self._ew_serve_left_next else ACTION_EW_THROUGH
            self._ew_serve_left_next = not self._ew_serve_left_next
            return remapped
        return action


# Module-level default instance — backwards-compatible shim so callers that
# import `sanitize_action` keep working without wiring up an instance.
_default_sanitizer = ActionSanitizer()


def sanitize_action(action: int) -> int:
    """Back-compat wrapper around the module-level ActionSanitizer."""
    return _default_sanitizer(action)

# ── State normalisation ───────────────────────────────────────────────────────
MAX_QUEUE      = 50.0    # vehicles per approach (per edge, all lanes summed)
MAX_QUEUE_LANE = 25.0    # vehicles per lane
MAX_SPEED      = 13.89   # 50 km/h in m/s (lane speed normalisation)
MAX_WAIT       = 600.0   # seconds — higher than baseline (399s) to allow headroom
MAX_PHASE_T    = 96.0    # one full 96-second TL cycle
MAX_PED_QUEUE  = 15.0    # max pedestrians waiting at one walking area

# ── Environment parameters ────────────────────────────────────────────────────
DECISION_INTERVAL  = 5     # SUMO seconds between agent decisions
MIN_GREEN_THROUGH  = 10    # seconds before through/all-phase switch (anti-flicker)
MIN_GREEN_LEFT     = 8     # left-turn phases serve fewer vehicles — shorter hold
YELLOW_DURATION    = 3     # seconds of yellow clearance
SIM_DURATION       = 7200  # seconds per episode (matches baseline)

# Exported constants for use by train_agent.py / run_ai.py
STATE_SIZE  = 45   # 8*3 + 4 + 8(phases) + 1 + 4(emergency) + 4(ped_wait)
ACTION_SIZE = 7

# ── Reward weights ────────────────────────────────────────────────────────────
# These are tuned so the baseline fixed-timer scores ≈ -2000 per episode
# and a near-optimal policy scores ≈ +8000 per episode, giving a clear signal.
W_QUEUE_ABS   = 0.2    # continuous penalty per vehicle in queue per decision block
W_QUEUE_DELTA = 0.5    # signed penalty/reward for queue growing/shrinking
W_ARRIVED     = 3.0    # reward per vehicle completing its journey
W_EMERGENCY   = 50.0   # penalty per decision block any emergency vehicle waits
W_FLICKER     = 10.0   # penalty for switching before MIN_GREEN_DURATION
W_BALANCE     = 4.0    # bonus for balanced queue distribution (was 1.0 — increased
                        # to prevent N/S bias due to 2-lane vs 1-lane asymmetry)
W_MAX_WAIT    = 0.4    # penalty per second any approach waits beyond the threshold
W_PED_WAIT    = 0.3    # penalty per waiting pedestrian per decision block
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
        # 1. Absolute congestion penalty (per decision block)
        r_abs   = -W_QUEUE_ABS * total_queue

        # 2. Delta: penalise net queue GROWTH only (no reward for shrinkage).
        #    Throughput bonus (r_thru) already rewards vehicles leaving.
        #    Rewarding shrinkage created a reward-hacking vulnerability where
        #    the agent could oscillate phases to harvest delta rewards without
        #    improving net throughput.
        delta   = total_queue - prev_total_queue
        r_delta = -W_QUEUE_DELTA * max(0.0, delta)   # only penalise growth

        # 3. Throughput (accumulated over the DECISION_INTERVAL steps)
        r_thru  = W_ARRIVED * n_arrived

        # 4. Emergency vehicle waiting (strong signal)
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
        #    Only kicks in above FAIR_WAIT_THRESH to allow normal cycling.
        r_max_wait = 0.0
        if wait_distribution:
            worst_wait = max(wait_distribution)
            excess     = max(0.0, worst_wait - FAIR_WAIT_THRESH)
            r_max_wait = -W_MAX_WAIT * excess

        # 8. Pedestrian waiting penalty
        r_ped = -W_PED_WAIT * n_ped_waiting

        return (r_abs + r_delta + r_thru + r_emerg
                + r_flick + r_balance + r_max_wait + r_ped)

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
        with our custom 15-character PHASE_SIGNALS strings.
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
