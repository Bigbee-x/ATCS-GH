#!/usr/bin/env python3
"""
ATCS-GH Phase 2 | Traffic Environment
═══════════════════════════════════════
Gym-style SUMO environment for training the DQN agent.

Design principles:
  • Agent decides every DECISION_INTERVAL simulation seconds (5s default).
    SUMO still runs at 1-second resolution internally — only the decision
    frequency is reduced for training efficiency.
  • A custom "ai_control" TL program (1M-second phase durations) prevents
    SUMO from ever auto-advancing phases. The agent is the sole controller.
  • Emergency preemption is a HARD SAFETY LAYER inside step() — the agent's
    action is silently overridden when an ambulance is on a red approach.
    This guarantees the AI never learns to ignore emergencies.
  • SUMO seed is parameterised so each training episode can use a different
    seed, preventing the DQN from overfitting to one arrival sequence.

State vector (33 dims):
  [lq_0..lq_5,                  6  per-lane queue counts      (÷ MAX_QUEUE_LANE)
   ls_0..ls_5,                  6  per-lane mean speeds       (÷ MAX_SPEED)
   lw_0..lw_5,                  6  per-lane wait times        (÷ MAX_WAIT)
   q_N, q_S, q_E, q_W,         4  approach queue totals      (÷ MAX_QUEUE)
   ph_0..ph_5,                  6  one-hot phase encoding (6 phases)
   t_phase,                     1  normalised time in phase   (÷ MAX_PHASE_T)
   em_N, em_S, em_E, em_W]     4  emergency vehicle flags (binary)

  Lanes: N2J_0, N2J_1, S2J_0, S2J_1, E2J_0, W2J_0

Actions (5):
  0 → keep current phase  (HOLD)
  1 → switch to NS_THROUGH (N/S straight + right)
  2 → switch to NS_LEFT    (N/S protected left turn)
  3 → switch to EW_THROUGH (E/W straight + right)
  4 → switch to EW_LEFT    (E/W protected left turn)
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
INCOMING_EDGES = ["N2J", "S2J", "E2J", "W2J"]
INCOMING_LANES = ["N2J_0", "N2J_1", "S2J_0", "S2J_1", "E2J_0", "W2J_0"]
EMERGENCY_TYPE = "emergency"

# Phase indices — 6 phases for through + left-turn separation
# Connection mapping (18 movements from intersection.net.xml):
#   pos 0-4:   N2J → right(0), straight(1,2), left(3), uturn(4)
#   pos 5-8:   E2J → right(5), straight(6), left(7), uturn(8)
#   pos 9-13:  S2J → right(9), straight(10,11), left(12), uturn(13)
#   pos 14-17: W2J → right(14), straight(15), left(16), uturn(17)
NS_THROUGH = 0   # N/S straight + right protected, left blocked
NS_LEFT    = 1   # N/S left protected, right permissive
NS_YELLOW  = 2   # N/S clearing
EW_THROUGH = 3   # E/W straight + right protected, left blocked
EW_LEFT    = 4   # E/W left protected, right permissive
EW_YELLOW  = 5   # E/W clearing

NUM_PHASES = 6

PHASE_NAMES = {
    0: "NS_THROUGH", 1: "NS_LEFT", 2: "NS_YELLOW",
    3: "EW_THROUGH", 4: "EW_LEFT", 5: "EW_YELLOW",
}

# 18-character signal state strings for setRedYellowGreenState()
PHASE_SIGNALS = {
    NS_THROUGH: "GGGrrrrrrGGGrrrrrr",  # N/S: right+straight=G, left+uturn=r
    NS_LEFT:    "grrGgrrrrgrrGgrrrr",   # N/S: left=G, right=g(permissive)
    NS_YELLOW:  "yyyyyrrrryyyyyrrrr",   # N/S: all yellow, E/W: red
    EW_THROUGH: "rrrrrGGrrrrrrrGGrr",   # E/W: right+straight=G, left+uturn=r
    EW_LEFT:    "rrrrrgrGgrrrrrgrGg",   # E/W: left=G, right=g(permissive)
    EW_YELLOW:  "rrrrryyyyrrrrryyyy",   # E/W: all yellow, N/S: red
}

# Green phases (non-yellow)
GREEN_PHASES = {NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT}

# Which edges get green in each green phase
PHASE_TO_EDGES = {
    NS_THROUGH: ["N2J", "S2J"],
    NS_LEFT:    ["N2J", "S2J"],
    EW_THROUGH: ["E2J", "W2J"],
    EW_LEFT:    ["E2J", "W2J"],
}
# Which green phases serve each incoming edge (for emergency preemption)
EDGE_TO_GREENS = {
    "N2J": [NS_THROUGH, NS_LEFT],
    "S2J": [NS_THROUGH, NS_LEFT],
    "E2J": [EW_THROUGH, EW_LEFT],
    "W2J": [EW_THROUGH, EW_LEFT],
}

# Action constants
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

# ── State normalisation ───────────────────────────────────────────────────────
MAX_QUEUE      = 50.0    # vehicles per approach (per edge, all lanes summed)
MAX_QUEUE_LANE = 25.0    # vehicles per lane
MAX_SPEED      = 13.89   # 50 km/h in m/s (lane speed normalisation)
MAX_WAIT       = 600.0   # seconds — higher than baseline (399s) to allow headroom
MAX_PHASE_T    = 96.0    # one full 96-second TL cycle

# ── Environment parameters ────────────────────────────────────────────────────
DECISION_INTERVAL  = 5     # SUMO seconds between agent decisions
MIN_GREEN_THROUGH  = 15    # seconds before through-phase switch (anti-flicker)
MIN_GREEN_LEFT     = 8     # left-turn phases serve fewer vehicles — shorter hold
YELLOW_DURATION    = 3     # seconds of yellow clearance
SIM_DURATION       = 7200  # seconds per episode (matches baseline)

# Exported constants for use by train_agent.py / run_ai.py
STATE_SIZE  = 33
ACTION_SIZE = 5

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

    def __init__(self, gui: bool = False, verbose: bool = False):
        self.gui     = gui
        self.verbose = verbose

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
            action: 0=HOLD, 1=NS_THROUGH, 2=NS_LEFT, 3=EW_THROUGH, 4=EW_LEFT

        Returns:
            next_state  — 33-dim normalised state vector
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

        reward = self._compute_reward(
            total_queue        = total_queue,
            prev_total_queue   = self._prev_total_queue,
            n_arrived          = block_arrived,
            n_emerg_waiting    = block_emerg_max,
            switched_too_soon  = (action != ACTION_HOLD and not preempted
                                  and self._phase_timer < (
                                      MIN_GREEN_LEFT
                                      if self._phase in (NS_LEFT, EW_LEFT)
                                      else MIN_GREEN_THROUGH)),
            queue_distribution = final_queues,
            wait_distribution  = final_waits,
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
        """Construct the 33-dimensional normalised state vector."""
        lane_m = self._collect_lane_metrics()
        edge_m = self._collect_edge_metrics()

        # Per-lane features (6 lanes × 3 = 18 dims)
        lane_queues = np.array([lane_m[l]["queue"] for l in INCOMING_LANES], dtype=np.float32)
        lane_speeds = np.array([lane_m[l]["speed"] for l in INCOMING_LANES], dtype=np.float32)
        lane_waits  = np.array([lane_m[l]["wait"]  for l in INCOMING_LANES], dtype=np.float32)

        # Per-approach aggregate queues (4 dims)
        approach_queues = np.array([edge_m[e]["queue"] for e in INCOMING_EDGES], dtype=np.float32)

        # One-hot encode the current phase (6 dims)
        phase_vec = np.zeros(NUM_PHASES, dtype=np.float32)
        phase_vec[self._phase] = 1.0

        # Normalised time in current phase
        t_norm = np.float32(min(self._phase_timer / MAX_PHASE_T, 1.0))

        # Emergency vehicle presence per approach (binary, 4 dims)
        emerg_flags = self._get_emergency_flags()

        state = np.concatenate([
            lane_queues / MAX_QUEUE_LANE,   # 6 values
            lane_speeds / MAX_SPEED,         # 6 values
            lane_waits  / MAX_WAIT,          # 6 values
            approach_queues / MAX_QUEUE,     # 4 values
            phase_vec,                       # 6 values
            [t_norm],                        # 1 value
            emerg_flags,                     # 4 values
        ])                                   # = 33 total
        return state.astype(np.float32)

    # ── Reward Computation ────────────────────────────────────────────────────

    def _compute_reward(self,
                        total_queue:       float,
                        prev_total_queue:  float,
                        n_arrived:         int,
                        n_emerg_waiting:   int,
                        switched_too_soon: bool,
                        queue_distribution: list[float],
                        wait_distribution:  list[float] | None = None) -> float:
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

        return (r_abs + r_delta + r_thru + r_emerg
                + r_flick + r_balance + r_max_wait)

    # ── Phase Control ─────────────────────────────────────────────────────────

    def _can_switch(self) -> bool:
        """True if the current green phase has run long enough to switch."""
        if self._in_yellow or self._phase not in GREEN_PHASES:
            return False
        min_green = (MIN_GREEN_LEFT
                     if self._phase in (NS_LEFT, EW_LEFT)
                     else MIN_GREEN_THROUGH)
        return self._phase_timer >= min_green

    def _initiate_switch(self, target_green: int | None = None) -> None:
        """
        Begin a phase transition: yellow → next_green.

        Args:
            target_green: Target green phase to switch to.
        """
        if target_green is None:
            return

        # Determine the yellow phase that clears the current green
        if self._phase in (NS_THROUGH, NS_LEFT):
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
        with our custom 18-character PHASE_SIGNALS strings.
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
