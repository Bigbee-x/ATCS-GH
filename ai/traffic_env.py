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

State vector (17 dims):
  [q_N, q_S, q_E, q_W,         4  normalised queue lengths   (÷ MAX_QUEUE)
   w_N, w_S, w_E, w_W,         4  normalised avg wait times  (÷ MAX_WAIT)
   ph_0, ph_1, ph_2, ph_3,     4  one-hot phase encoding
   t_phase,                     1  normalised time in phase   (÷ MAX_PHASE_T)
   em_N, em_S, em_E, em_W]     4  emergency vehicle flags (binary)

Actions:
  0 → keep current phase
  1 → switch to next phase (3s yellow then next green)
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
EMERGENCY_TYPE = "emergency"

# Phase indices (matches netconvert output for our 4-way junction)
NS_GREEN  = 0   # North-South has right-of-way
NS_YELLOW = 1   # North-South clearing
EW_GREEN  = 2   # East-West has right-of-way
EW_YELLOW = 3   # East-West clearing
PHASE_NAMES = {0: "NS_GREEN", 1: "NS_YELLOW", 2: "EW_GREEN", 3: "EW_YELLOW"}

# Which edges get green in each green phase
PHASE_TO_EDGES = {
    NS_GREEN: ["N2J", "S2J"],
    EW_GREEN: ["E2J", "W2J"],
}
# Which green phase serves each incoming edge
EDGE_TO_GREEN = {
    "N2J": NS_GREEN, "S2J": NS_GREEN,
    "E2J": EW_GREEN, "W2J": EW_GREEN,
}

# ── State normalisation ───────────────────────────────────────────────────────
MAX_QUEUE   = 50.0    # vehicles per approach (per edge, all lanes summed)
MAX_WAIT    = 600.0   # seconds — higher than baseline (399s) to allow headroom
MAX_PHASE_T = 96.0    # one full 96-second TL cycle

# ── Environment parameters ────────────────────────────────────────────────────
DECISION_INTERVAL  = 5     # SUMO seconds between agent decisions
MIN_GREEN_DURATION = 15    # seconds before a switch is allowed (anti-flicker)
YELLOW_DURATION    = 3     # seconds of yellow clearance
SIM_DURATION       = 7200  # seconds per episode (matches baseline)

# Exported constants for use by train_agent.py / run_ai.py
STATE_SIZE  = 17
ACTION_SIZE = 2

# ── Reward weights ────────────────────────────────────────────────────────────
# These are tuned so the baseline fixed-timer scores ≈ -2000 per episode
# and a near-optimal policy scores ≈ +8000 per episode, giving a clear signal.
W_QUEUE_ABS   = 0.2    # continuous penalty per vehicle in queue per decision block
W_QUEUE_DELTA = 0.5    # signed penalty/reward for queue growing/shrinking
W_ARRIVED     = 3.0    # reward per vehicle completing its journey
W_EMERGENCY   = 50.0   # penalty per decision block any emergency vehicle waits
W_FLICKER     = 10.0   # penalty for switching before MIN_GREEN_DURATION
W_BALANCE     = 1.0    # bonus for balanced queue distribution across approaches


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
        self._phase            = NS_GREEN
        self._phase_timer      = 0        # sim-seconds since last phase change
        self._in_yellow        = False
        self._yellow_countdown = 0
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
        self._phase            = NS_GREEN
        self._phase_timer      = 0
        self._in_yellow        = False
        self._yellow_countdown = 0
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
            action: 0 = keep current phase, 1 = switch to next phase

        Returns:
            next_state  — 17-dim normalised state vector
            reward      — scalar reward for this decision block
            done        — True if episode has ended
            info        — diagnostic dict (phase, arrived, queues, preempted, ...)
        """
        if not self._connected:
            raise RuntimeError("Call env.reset() before env.step()")

        # ── Safety layer: emergency preemption ───────────────────────────────
        preempted, forced_phase = self._check_emergency_preemption()
        if preempted:
            # Override agent action to serve the emergency vehicle
            action = 1 if forced_phase != self._phase else 0
            if action == 1:
                self._initiate_switch(target_green=forced_phase)

        # ── Initiate switch if agent chose to (and it's allowed) ─────────────
        elif action == 1 and self._can_switch():
            self._initiate_switch()

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
            total_queue       = total_queue,
            prev_total_queue  = self._prev_total_queue,
            n_arrived         = block_arrived,
            n_emerg_waiting   = block_emerg_max,
            switched_too_soon = (action == 1 and not preempted
                                 and self._phase_timer < MIN_GREEN_DURATION),
            queue_distribution = final_queues,
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
        """Construct the 17-dimensional normalised state vector."""
        em = self._collect_edge_metrics()

        queues = np.array([em[e]["queue"] for e in INCOMING_EDGES], dtype=np.float32)
        waits  = np.array([em[e]["wait"]  for e in INCOMING_EDGES], dtype=np.float32)

        # One-hot encode the current phase (4 dims)
        phase_vec      = np.zeros(4, dtype=np.float32)
        phase_vec[self._phase] = 1.0

        # Normalised time in current phase
        t_norm = np.float32(min(self._phase_timer / MAX_PHASE_T, 1.0))

        # Emergency vehicle presence per approach (binary)
        emerg_flags = self._get_emergency_flags()

        state = np.concatenate([
            queues    / MAX_QUEUE,   # 4 values
            waits     / MAX_WAIT,    # 4 values
            phase_vec,               # 4 values
            [t_norm],                # 1 value
            emerg_flags,             # 4 values
        ])
        return state.astype(np.float32)

    # ── Reward Computation ────────────────────────────────────────────────────

    def _compute_reward(self,
                        total_queue:       float,
                        prev_total_queue:  float,
                        n_arrived:         int,
                        n_emerg_waiting:   int,
                        switched_too_soon: bool,
                        queue_distribution: list[float]) -> float:
        """
        Multi-component reward function:

        1. Absolute queue penalty  — penalises sustained congestion
        2. Queue growth penalty    — penalises net queue increase (asymmetric)
        3. Throughput bonus        — rewards vehicles completing journeys
        4. Emergency penalty       — large negative when ambulance waits at red
        5. Flicker penalty         — discourages rapid phase switching
        6. Balance bonus           — rewards equal queue distribution across approaches

        Calibrated so a fixed-timer policy scores ≈ -2000/episode and a
        near-optimal policy scores ≈ +8000/episode over 7200s.
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

        return r_abs + r_delta + r_thru + r_emerg + r_flick + r_balance

    # ── Phase Control ─────────────────────────────────────────────────────────

    def _can_switch(self) -> bool:
        """True if the current green phase has run long enough to switch."""
        return (
            not self._in_yellow
            and self._phase in (NS_GREEN, EW_GREEN)
            and self._phase_timer >= MIN_GREEN_DURATION
        )

    def _initiate_switch(self, target_green: int | None = None) -> None:
        """
        Begin a phase transition: yellow → next_green.

        Args:
            target_green: if set, force a specific target green phase
                          (used by emergency preemption).
        """
        # Determine the yellow phase that clears the current green
        if self._phase == NS_GREEN:
            yellow = NS_YELLOW
            self._next_green = target_green if target_green is not None else EW_GREEN
        else:
            yellow = EW_YELLOW
            self._next_green = target_green if target_green is not None else NS_GREEN

        traci.trafficlight.setPhase(TL_ID, yellow)
        self._phase            = yellow
        self._in_yellow        = True
        self._yellow_countdown = YELLOW_DURATION

        if self.verbose:
            print(f"[ENV] t={self._sim_step:4d}s  Switch initiated → "
                  f"{PHASE_NAMES[yellow]} (3s) → {PHASE_NAMES[self._next_green]}")

    def _complete_switch(self) -> None:
        """Yellow has expired — set the next green phase."""
        traci.trafficlight.setPhase(TL_ID, self._next_green)
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
        Replace the default SUMO TL program with "ai_control":
          — Same phase state strings (encodes which lanes have green/yellow/red)
          — All phase durations set to 1,000,000 seconds

        This prevents SUMO from ever auto-advancing phases. The agent (via
        _initiate_switch / _complete_switch) is the sole controller.
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
        traci.trafficlight.setPhase(TL_ID, NS_GREEN)
        self._phase = NS_GREEN

        if self.verbose:
            print(f"[ENV] 'ai_control' program installed  "
                  f"({len(long_phases)} phases, 1M-sec durations)")
            for i, p in enumerate(orig.phases):
                print(f"       Phase {i} ({PHASE_NAMES.get(i,'?'):10s}): "
                      f"state={p.state}")

    # ── Metric Collection ─────────────────────────────────────────────────────

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
        the correct green phase is not already showing (or in transition to it).
        """
        for edge in INCOMING_EDGES:
            try:
                for vid in traci.edge.getLastStepVehicleIDs(edge):
                    if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                        continue

                    target_green = EDGE_TO_GREEN[edge]
                    already_serving = (
                        self._phase == target_green
                        or (self._in_yellow and self._next_green == target_green)
                    )
                    if not already_serving:
                        return True, target_green

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
