#!/usr/bin/env python3
"""
ATCS-GH | Corridor Traffic Environment — 3-Junction N6 Nsawam Road
═══════════════════════════════════════════════════════════════════
Multi-junction SUMO environment for training multi-agent DQN.

Three signalised junctions along the N6 Nsawam Road (Achimota corridor):
  J0 — Achimota/Neoplan (Aggrey St / Guggisberg St)
  J1 — Asylum Down Rd / Ring Rd  (300m north of J0)
  J2 — Nima Bypass / Tesano Rd   (300m north of J1)

Each junction is independently controlled by a DQN agent that observes
its own state plus neighbor queue/phase info (50-dim state vector).

Green-wave design:
  At 50 km/h (13.89 m/s), 300m between junctions takes ~21.6s.
  Agents can learn to offset their NS phases by ~22s for smooth
  traffic flow through the corridor.

Per-junction state vector (50 dims):
  [0-7]   8  per-lane queue counts     (padded to 8, / MAX_QUEUE_LANE)
  [8-15]  8  per-lane mean speeds      (padded to 8, / MAX_SPEED)
  [16-23] 8  per-lane wait times       (padded to 8, / MAX_WAIT)
  [24-27] 4  approach aggregate queues  (/ MAX_QUEUE)
  [28-35] 8  one-hot phase encoding
  [36]    1  normalised time-in-phase   (/ MAX_PHASE_T)
  [37-40] 4  emergency vehicle flags    (binary)
  [41-44] 4  pedestrian waiting counts  (/ MAX_PED_QUEUE)
  [45-46] 2  south neighbor info        (queue_norm, phase_norm)
  [47-48] 2  north neighbor info        (queue_norm, phase_norm)
  [49]    1  max corridor link occupancy (spillback risk)

Actions per junction (7): same as single-junction env
  0=HOLD, 1=NS_THROUGH, 2=NS_LEFT, 3=EW_THROUGH, 4=EW_LEFT,
  5=NS_ALL, 6=EW_ALL
"""

import os
import sys
import shutil
import numpy as np
from pathlib import Path
from dataclasses import dataclass, field


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


# ── Paths ─────────────────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SIM_DIR      = PROJECT_ROOT / "simulation"
CONFIG_FILE  = SIM_DIR / "corridor.sumocfg"


# ── Phase Constants (same action space for all junctions) ────────────────────

NS_THROUGH = 0
NS_LEFT    = 1
NS_YELLOW  = 2
EW_THROUGH = 3
EW_LEFT    = 4
EW_YELLOW  = 5
NS_ALL     = 6
EW_ALL     = 7
NUM_PHASES = 8

PHASE_NAMES = {
    0: "NS_THROUGH", 1: "NS_LEFT", 2: "NS_YELLOW",
    3: "EW_THROUGH", 4: "EW_LEFT", 5: "EW_YELLOW",
    6: "NS_ALL",     7: "EW_ALL",
}

GREEN_PHASES = {NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT, NS_ALL, EW_ALL}

ACTION_HOLD       = 0
ACTION_NS_THROUGH = 1
ACTION_NS_LEFT    = 2
ACTION_EW_THROUGH = 3
ACTION_EW_LEFT    = 4
ACTION_NS_ALL     = 5
ACTION_EW_ALL     = 6
ACTION_SIZE       = 7

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

EMERGENCY_TYPE = "emergency"


# ── State/reward normalisation ───────────────────────────────────────────────

MAX_QUEUE      = 50.0
MAX_QUEUE_LANE = 25.0
MAX_SPEED      = 13.89
MAX_WAIT       = 600.0
MAX_PHASE_T    = 96.0
MAX_PED_QUEUE  = 15.0

STATE_SIZE     = 50   # per-junction state vector dimension
MAX_LANES      = 8    # pad all junctions to this many lanes

# ── Environment parameters ───────────────────────────────────────────────────

DECISION_INTERVAL  = 5
MIN_GREEN_THROUGH  = 10
MIN_GREEN_LEFT     = 8
YELLOW_DURATION    = 3
SIM_DURATION       = 7200

# ── Reward weights (per-junction, same as single-junction env) ───────────────

W_QUEUE_ABS     = 0.2
W_QUEUE_DELTA   = 0.5
W_ARRIVED       = 3.0
W_EMERGENCY     = 50.0
W_FLICKER       = 10.0
W_BALANCE       = 4.0
W_MAX_WAIT      = 0.4
W_PED_WAIT      = 0.3
FAIR_WAIT_THRESH = 30.0

# Corridor-specific reward weights
W_GREEN_WAVE    = 3.0    # bonus for correct green-wave timing with neighbor
W_SPILLBACK     = 5.0    # penalty for corridor link congestion

# Green wave timing: distance / speed = offset
JUNCTION_SPACING = 300.0   # metres between consecutive junctions
CORRIDOR_SPEED   = 13.89   # 50 km/h
IDEAL_OFFSET     = JUNCTION_SPACING / CORRIDOR_SPEED  # ~21.6 seconds
OFFSET_TOLERANCE = 5.0     # ±5 seconds of ideal is rewarded
SPILLBACK_THRESH = 0.8     # occupancy above this triggers penalty


# ── Signal string builder ────────────────────────────────────────────────────

def _approach_signal(n_conns: int, mode: str) -> str:
    """Build signal characters for one approach direction.

    Args:
        n_conns: Number of controlled connections (4 for 1-lane, 5 for 2-lane)
        mode: 'through', 'left', 'all', 'yellow', 'red'
    """
    if n_conns == 5:  # 2-lane approach: right, straight, straight, left, uturn
        return {
            "through": "GGGrr",
            "left":    "grrGr",
            "all":     "GGGGr",
            "yellow":  "yyyyy",
            "red":     "rrrrr",
        }[mode]
    elif n_conns == 4:  # 1-lane approach: right, straight, left, uturn
        return {
            "through": "GGrr",
            "left":    "grGr",
            "all":     "GGGr",
            "yellow":  "yyyy",
            "red":     "rrrr",
        }[mode]
    else:
        raise ValueError(f"Unexpected n_conns={n_conns}")


def build_phase_signals(n_N: int, n_E: int, n_S: int, n_W: int) -> dict[int, str]:
    """Build all 8 phase signal strings for a junction.

    Crossing pattern (4 chars appended):
      NS phases → E/W crossings green: rGrG  (c0=r, c1=G, c2=r, c3=G)
      EW phases → N/S crossings green: GrGr  (c0=G, c1=r, c2=G, c3=r)
      Yellow    → all crossings red:   rrrr
    """
    X_NS = "rGrG"   # EW arm crossings green when NS traffic flows
    X_EW = "GrGr"   # NS arm crossings green when EW traffic flows
    X_R  = "rrrr"   # all crossings red during yellow

    def _sig(n_mode, e_mode, s_mode, w_mode, x):
        return (_approach_signal(n_N, n_mode)
                + _approach_signal(n_E, e_mode)
                + _approach_signal(n_S, s_mode)
                + _approach_signal(n_W, w_mode)
                + x)

    return {
        NS_THROUGH: _sig("through", "red", "through", "red", X_NS),
        NS_LEFT:    _sig("left",    "red", "left",    "red", X_NS),
        NS_YELLOW:  _sig("yellow",  "red", "yellow",  "red", X_R),
        EW_THROUGH: _sig("red", "through", "red", "through", X_EW),
        EW_LEFT:    _sig("red", "left",    "red", "left",    X_EW),
        EW_YELLOW:  _sig("red", "yellow",  "red", "yellow",  X_R),
        NS_ALL:     _sig("all",  "red", "all",  "red", X_NS),
        EW_ALL:     _sig("red",  "all", "red",  "all", X_EW),
    }


# ── Per-junction configuration ───────────────────────────────────────────────

@dataclass
class JunctionConfig:
    """Static configuration for one junction in the corridor."""
    tl_id: str
    # Incoming edges in order: [N_approach, E_approach, S_approach, W_approach]
    incoming_edges: list[str]
    # Vehicle lanes (lane 0 is sidewalk, these are _1, _2 etc.)
    incoming_lanes: list[str]
    # Walking areas for pedestrian counting
    walking_areas: list[str]
    # Crossing edges
    crossing_edges: list[str]
    # Connections per approach: [n_N, n_E, n_S, n_W]
    conns_per_approach: list[int]
    # Phase signals (computed from conns_per_approach)
    phase_signals: dict[int, str] = field(default_factory=dict)
    # Which edges green in each phase
    phase_to_edges: dict[int, list[str]] = field(default_factory=dict)
    # Corridor links: (south_link_edge, north_link_edge) or None
    south_link: str | None = None   # edge FROM this junction going south
    north_link: str | None = None   # edge FROM this junction going north

    def __post_init__(self):
        n_N, n_E, n_S, n_W = self.conns_per_approach
        self.phase_signals = build_phase_signals(n_N, n_E, n_S, n_W)
        N, E, S, W = self.incoming_edges
        self.phase_to_edges = {
            NS_THROUGH: [N, S], NS_LEFT: [N, S], NS_ALL: [N, S],
            EW_THROUGH: [E, W], EW_LEFT: [E, W], EW_ALL: [E, W],
        }
        self.edge_to_greens = {
            N: [NS_THROUGH, NS_LEFT, NS_ALL],
            S: [NS_THROUGH, NS_LEFT, NS_ALL],
            E: [EW_THROUGH, EW_LEFT, EW_ALL],
            W: [EW_THROUGH, EW_LEFT, EW_ALL],
        }


# Build junction configs from the corridor network
JUNCTION_IDS = ["J0", "J1", "J2"]

JUNCTIONS: dict[str, JunctionConfig] = {
    "J0": JunctionConfig(
        tl_id="J0",
        incoming_edges=["ACH_J1toJ0", "AGG_E2J0", "ACH_S2J0", "GUG_W2J0"],
        incoming_lanes=[
            "ACH_J1toJ0_1", "ACH_J1toJ0_2",  # N approach (from J1)
            "AGG_E2J0_1",   "AGG_E2J0_2",     # E approach (Aggrey St)
            "ACH_S2J0_1",   "ACH_S2J0_2",     # S approach (from boundary)
            "GUG_W2J0_1",                       # W approach (Guggisberg, 1 lane)
        ],
        walking_areas=[":J0_w0", ":J0_w1", ":J0_w2", ":J0_w3"],
        crossing_edges=[":J0_c0", ":J0_c1", ":J0_c2", ":J0_c3"],
        conns_per_approach=[5, 4, 5, 5],  # N=5, E=4, S=5, W=5
        south_link=None,          # J0 is southernmost
        north_link="ACH_J0toJ1",  # northbound corridor link to J1
    ),
    "J1": JunctionConfig(
        tl_id="J1",
        incoming_edges=["ACH_J2toJ1", "ASD_E2J1", "ACH_J0toJ1", "RNG_W2J1"],
        incoming_lanes=[
            "ACH_J2toJ1_1", "ACH_J2toJ1_2",  # N approach (from J2)
            "ASD_E2J1_1",   "ASD_E2J1_2",     # E approach (Asylum Down)
            "ACH_J0toJ1_1", "ACH_J0toJ1_2",   # S approach (from J0)
            "RNG_W2J1_1",   "RNG_W2J1_2",     # W approach (Ring Rd, 2 lanes)
        ],
        walking_areas=[":J1_w0", ":J1_w1", ":J1_w2", ":J1_w3"],
        crossing_edges=[":J1_c0", ":J1_c1", ":J1_c2", ":J1_c3"],
        conns_per_approach=[5, 5, 5, 5],  # all 2-lane approaches
        south_link="ACH_J1toJ0",  # southbound corridor link to J0
        north_link="ACH_J1toJ2",  # northbound corridor link to J2
    ),
    "J2": JunctionConfig(
        tl_id="J2",
        incoming_edges=["ACH_N2J2", "NMA_E2J2", "ACH_J1toJ2", "TSN_W2J2"],
        incoming_lanes=[
            "ACH_N2J2_1",   "ACH_N2J2_2",     # N approach (from boundary)
            "NMA_E2J2_1",                       # E approach (Nima, 1 lane)
            "ACH_J1toJ2_1", "ACH_J1toJ2_2",   # S approach (from J1)
            "TSN_W2J2_1",                       # W approach (Tesano, 1 lane)
        ],
        walking_areas=[":J2_w0", ":J2_w1", ":J2_w2", ":J2_w3"],
        crossing_edges=[":J2_c0", ":J2_c1", ":J2_c2", ":J2_c3"],
        conns_per_approach=[5, 4, 5, 4],  # N=5, E=4, S=5, W=4
        south_link="ACH_J2toJ1",  # southbound corridor link to J1
        north_link=None,           # J2 is northernmost
    ),
}

# Neighbor mapping: for each junction, (south_neighbor_id, north_neighbor_id)
NEIGHBORS = {
    "J0": (None, "J1"),
    "J1": ("J0", "J2"),
    "J2": ("J1", None),
}

# Corridor links between junctions (for occupancy measurement)
# (from_jid, to_jid): [northbound_edge, southbound_edge]
CORRIDOR_LINKS = {
    ("J0", "J1"): ("ACH_J0toJ1", "ACH_J1toJ0"),
    ("J1", "J2"): ("ACH_J1toJ2", "ACH_J2toJ1"),
}


# ── Per-junction runtime state ───────────────────────────────────────────────

class JunctionState:
    """Mutable per-episode state for one junction."""

    def __init__(self):
        self.phase: int            = NS_THROUGH
        self.phase_timer: int      = 0
        self.in_yellow: bool       = False
        self.yellow_countdown: int = 0
        self.next_green: int       = NS_THROUGH
        self.prev_total_queue: float = 0.0
        self.ns_green_start: float = 0.0  # sim time when last NS green started

    def reset(self):
        self.phase            = NS_THROUGH
        self.phase_timer      = 0
        self.in_yellow        = False
        self.yellow_countdown = 0
        self.next_green       = NS_THROUGH
        self.prev_total_queue = 0.0
        self.ns_green_start   = 0.0


# ── Corridor Environment ────────────────────────────────────────────────────

class CorridorEnv:
    """
    Multi-junction SUMO environment for the N6 Nsawam Road corridor.

    Interface:
        states                              = env.reset(seed=42)
        states, rewards, done, info         = env.step(actions)
        env.close()

    Where:
        states  = {jid: np.ndarray(50,)}
        actions = {jid: int}   (0-6)
        rewards = {jid: float}
        info    = {jid: dict}
    """

    def __init__(self, gui: bool = False, verbose: bool = False,
                 route_file: str | None = None):
        self.gui        = gui
        self.verbose    = verbose
        self.route_file = route_file

        self._connected = False
        self._sim_step  = 0

        # Per-junction mutable state
        self._jstate: dict[str, JunctionState] = {
            jid: JunctionState() for jid in JUNCTION_IDS
        }

        # Per-episode stats
        self.total_arrived: int = 0
        self.episode_rewards: dict[str, list[float]] = {jid: [] for jid in JUNCTION_IDS}
        self.episode_waits:   dict[str, list[float]] = {jid: [] for jid in JUNCTION_IDS}
        self.emergency_log:   dict[str, float] = {}

    # ── Gym Interface ─────────────────────────────────────────────────────────

    def reset(self, seed: int | None = None) -> dict[str, np.ndarray]:
        """Restart simulation and return initial states for all junctions."""
        self.close()
        self._start_sumo(seed=seed)

        # Configure AI control for all 3 traffic lights
        for jid in JUNCTION_IDS:
            self._configure_tl(jid)

        # Reset bookkeeping
        self._sim_step = 0
        self.total_arrived = 0
        self.emergency_log = {}
        for jid in JUNCTION_IDS:
            self._jstate[jid].reset()
            self.episode_rewards[jid] = []
            self.episode_waits[jid]   = []

        # Advance one step to populate TraCI state
        traci.simulationStep()
        self._sim_step = 1

        return {jid: self._build_state(jid) for jid in JUNCTION_IDS}

    def step(self, actions: dict[str, int]
             ) -> tuple[dict[str, np.ndarray], dict[str, float],
                         bool, dict[str, dict]]:
        """
        Apply actions for all junctions, advance DECISION_INTERVAL steps.

        Args:
            actions: {junction_id: action_int} for each junction

        Returns:
            (states, rewards, done, info) — all dicts keyed by junction_id
        """
        if not self._connected:
            raise RuntimeError("Call env.reset() before env.step()")

        # ── Apply actions for each junction ──────────────────────────────────
        for jid in JUNCTION_IDS:
            action = actions.get(jid, ACTION_HOLD)
            js = self._jstate[jid]
            cfg = JUNCTIONS[jid]

            # Emergency preemption check
            preempted, forced_phase = self._check_emergency(jid)
            if preempted:
                if forced_phase != js.phase and self._can_switch(jid):
                    self._initiate_switch(jid, forced_phase)
            elif action != ACTION_HOLD and self._can_switch(jid):
                target = ACTION_TO_PHASE.get(action)
                if target is not None and target != js.phase:
                    self._initiate_switch(jid, target)

        # ── Advance DECISION_INTERVAL simulation steps ───────────────────────
        block_arrived = 0
        block_emerg: dict[str, int] = {jid: 0 for jid in JUNCTION_IDS}

        for _ in range(DECISION_INTERVAL):
            # Handle yellow countdowns for all junctions
            for jid in JUNCTION_IDS:
                js = self._jstate[jid]
                if js.in_yellow:
                    js.yellow_countdown -= 1
                    if js.yellow_countdown <= 0:
                        self._complete_switch(jid)

            traci.simulationStep()
            self._sim_step += 1

            for jid in JUNCTION_IDS:
                self._jstate[jid].phase_timer += 1

            block_arrived += traci.simulation.getArrivedNumber()

            # Count emergency vehicles per junction
            for jid in JUNCTION_IDS:
                cfg = JUNCTIONS[jid]
                n_emerg = 0
                for edge in cfg.incoming_edges:
                    try:
                        for vid in traci.edge.getLastStepVehicleIDs(edge):
                            if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                                if traci.vehicle.getSpeed(vid) < 0.1:
                                    n_emerg += 1
                    except traci.exceptions.TraCIException:
                        pass
                block_emerg[jid] = max(block_emerg[jid], n_emerg)

            self._track_emergency_vehicles()

            if traci.simulation.getMinExpectedNumber() == 0:
                break

        # ── Collect metrics and compute rewards ──────────────────────────────
        self.total_arrived += block_arrived

        states  = {}
        rewards = {}
        infos   = {}

        for jid in JUNCTION_IDS:
            js = self._jstate[jid]
            cfg = JUNCTIONS[jid]

            # Per-junction edge metrics
            edge_metrics = self._collect_edge_metrics(jid)
            queues = [edge_metrics[e]["queue"] for e in cfg.incoming_edges]
            waits  = [edge_metrics[e]["wait"]  for e in cfg.incoming_edges]
            total_q = float(sum(queues))

            # Pedestrian counts
            ped_counts = self._get_ped_counts(jid)
            total_ped = int(sum(ped_counts))

            # Check flicker
            action = actions.get(jid, ACTION_HOLD)
            preempted, _ = self._check_emergency(jid)
            min_g = (MIN_GREEN_LEFT if js.phase in (NS_LEFT, EW_LEFT)
                     else MIN_GREEN_THROUGH)

            # Per-junction reward
            r_local = self._compute_local_reward(
                total_queue        = total_q,
                prev_total_queue   = js.prev_total_queue,
                n_arrived          = block_arrived // len(JUNCTION_IDS),  # share evenly
                n_emerg_waiting    = block_emerg[jid],
                switched_too_soon  = (action != ACTION_HOLD and not preempted
                                      and js.phase_timer < min_g),
                queue_distribution = queues,
                wait_distribution  = waits,
                n_ped_waiting      = total_ped,
            )

            # Corridor coordination rewards
            r_corridor = self._compute_corridor_reward(jid)

            reward = r_local + r_corridor
            js.prev_total_queue = total_q

            avg_wait = float(np.mean(waits)) if waits else 0.0
            self.episode_rewards[jid].append(reward)
            self.episode_waits[jid].append(avg_wait)

            states[jid] = self._build_state(jid)
            rewards[jid] = reward
            infos[jid] = {
                "sim_step":      self._sim_step,
                "phase":         PHASE_NAMES.get(js.phase, "?"),
                "phase_timer":   js.phase_timer,
                "arrived_block": block_arrived,
                "queues":        queues,
                "avg_wait":      avg_wait,
                "preempted":     preempted,
                "reward":        reward,
                "r_local":       r_local,
                "r_corridor":    r_corridor,
            }

        done = (
            self._sim_step >= SIM_DURATION
            or traci.simulation.getMinExpectedNumber() == 0
        )

        return states, rewards, done, infos

    def close(self) -> None:
        """Terminate the SUMO process."""
        if self._connected:
            try:
                traci.close()
            except Exception:
                pass
            self._connected = False

    # ── Episode Summary ──────────────────────────────────────────────────────

    def corridor_avg_wait(self) -> float:
        """Average wait time across all junctions for the episode."""
        all_waits = []
        for jid in JUNCTION_IDS:
            all_waits.extend(self.episode_waits[jid])
        return float(np.mean(all_waits)) if all_waits else 0.0

    def corridor_total_reward(self) -> float:
        """Sum of all rewards across all junctions."""
        return sum(
            sum(self.episode_rewards[jid]) for jid in JUNCTION_IDS
        )

    # ── State Construction ───────────────────────────────────────────────────

    def _build_state(self, jid: str) -> np.ndarray:
        """Build 50-dim normalised state vector for one junction."""
        cfg = JUNCTIONS[jid]
        js  = self._jstate[jid]

        # Per-lane metrics (padded to MAX_LANES=8)
        lane_m = self._collect_lane_metrics(jid)
        n_lanes = len(cfg.incoming_lanes)

        lq = np.zeros(MAX_LANES, dtype=np.float32)
        ls = np.zeros(MAX_LANES, dtype=np.float32)
        lw = np.zeros(MAX_LANES, dtype=np.float32)
        for i, lid in enumerate(cfg.incoming_lanes):
            m = lane_m[lid]
            lq[i] = m["queue"]
            ls[i] = m["speed"]
            lw[i] = m["wait"]

        # Per-approach aggregate queues (4 dims)
        edge_m = self._collect_edge_metrics(jid)
        approach_q = np.array([edge_m[e]["queue"] for e in cfg.incoming_edges],
                              dtype=np.float32)

        # Phase one-hot (8 dims)
        phase_vec = np.zeros(NUM_PHASES, dtype=np.float32)
        phase_vec[js.phase] = 1.0

        # Normalised time in phase
        t_norm = np.float32(min(js.phase_timer / MAX_PHASE_T, 1.0))

        # Emergency flags (4 dims)
        emerg = self._get_emergency_flags(jid)

        # Pedestrian counts (4 dims)
        ped = self._get_ped_counts(jid)

        # Neighbor info (south: 2, north: 2)
        south_jid, north_jid = NEIGHBORS[jid]

        def _neighbor_info(nid):
            if nid is None:
                return np.zeros(2, dtype=np.float32)
            njs = self._jstate[nid]
            ncfg = JUNCTIONS[nid]
            n_edge_m = self._collect_edge_metrics(nid)
            total_q = sum(n_edge_m[e]["queue"] for e in ncfg.incoming_edges)
            return np.array([
                min(total_q / MAX_QUEUE, 1.0),
                njs.phase / 7.0,
            ], dtype=np.float32)

        south_info = _neighbor_info(south_jid)
        north_info = _neighbor_info(north_jid)

        # Corridor link occupancy (max of adjacent links)
        max_occ = 0.0
        for link_edge in [cfg.south_link, cfg.north_link]:
            if link_edge:
                try:
                    occ = traci.edge.getLastStepOccupancy(link_edge)
                    max_occ = max(max_occ, occ / 100.0)  # occupancy is 0-100%
                except traci.exceptions.TraCIException:
                    pass

        state = np.concatenate([
            lq / MAX_QUEUE_LANE,     # 8
            ls / MAX_SPEED,          # 8
            lw / MAX_WAIT,           # 8
            approach_q / MAX_QUEUE,  # 4
            phase_vec,               # 8
            [t_norm],                # 1
            emerg,                   # 4
            ped / MAX_PED_QUEUE,     # 4
            south_info,              # 2
            north_info,              # 2
            [np.float32(max_occ)],   # 1
        ])                           # = 50 total
        return state.astype(np.float32)

    # ── Reward Computation ───────────────────────────────────────────────────

    def _compute_local_reward(self,
                              total_queue: float,
                              prev_total_queue: float,
                              n_arrived: int,
                              n_emerg_waiting: int,
                              switched_too_soon: bool,
                              queue_distribution: list[float],
                              wait_distribution: list[float],
                              n_ped_waiting: int = 0) -> float:
        """Per-junction reward (identical to single-junction env)."""
        r_abs   = -W_QUEUE_ABS * total_queue
        delta   = total_queue - prev_total_queue
        r_delta = -W_QUEUE_DELTA * max(0.0, delta)
        r_thru  = W_ARRIVED * n_arrived
        r_emerg = -W_EMERGENCY * n_emerg_waiting
        r_flick = -W_FLICKER if switched_too_soon else 0.0

        if total_queue > 0:
            mean_q    = total_queue / max(len(queue_distribution), 1)
            std_q     = float(np.std(queue_distribution))
            balance   = max(0.0, 1.0 - std_q / (mean_q + 1.0))
            r_balance = W_BALANCE * balance
        else:
            r_balance = W_BALANCE

        r_max_wait = 0.0
        if wait_distribution:
            worst_wait = max(wait_distribution)
            excess = max(0.0, worst_wait - FAIR_WAIT_THRESH)
            r_max_wait = -W_MAX_WAIT * excess

        r_ped = -W_PED_WAIT * n_ped_waiting

        return (r_abs + r_delta + r_thru + r_emerg
                + r_flick + r_balance + r_max_wait + r_ped)

    def _compute_corridor_reward(self, jid: str) -> float:
        """Corridor coordination reward components."""
        cfg = JUNCTIONS[jid]
        js  = self._jstate[jid]
        reward = 0.0

        # ── Green wave bonus ─────────────────────────────────────────────────
        # Reward when this junction's NS phase starts close to the ideal
        # offset from its neighbor's NS phase.
        south_jid, north_jid = NEIGHBORS[jid]

        for nid in [south_jid, north_jid]:
            if nid is None:
                continue
            njs = self._jstate[nid]
            # Both need to be in NS-related phases for green wave
            my_ns = js.phase in (NS_THROUGH, NS_LEFT, NS_ALL)
            nb_ns = njs.phase in (NS_THROUGH, NS_LEFT, NS_ALL)
            if my_ns and nb_ns:
                # Check phase offset
                offset = abs(js.ns_green_start - njs.ns_green_start)
                if abs(offset - IDEAL_OFFSET) <= OFFSET_TOLERANCE:
                    reward += W_GREEN_WAVE * 0.5  # partial reward per neighbor

        # ── Spillback penalty ────────────────────────────────────────────────
        # Penalize if corridor links adjacent to this junction are congested
        for link_edge in [cfg.south_link, cfg.north_link]:
            if link_edge:
                try:
                    occ = traci.edge.getLastStepOccupancy(link_edge) / 100.0
                    if occ > SPILLBACK_THRESH:
                        reward -= W_SPILLBACK * (occ - SPILLBACK_THRESH)
                except traci.exceptions.TraCIException:
                    pass

        return reward

    # ── Phase Control ────────────────────────────────────────────────────────

    def _can_switch(self, jid: str) -> bool:
        js = self._jstate[jid]
        if js.in_yellow or js.phase not in GREEN_PHASES:
            return False
        if js.phase in (NS_LEFT, EW_LEFT):
            return js.phase_timer >= MIN_GREEN_LEFT
        return js.phase_timer >= MIN_GREEN_THROUGH

    def _initiate_switch(self, jid: str, target_green: int) -> None:
        js  = self._jstate[jid]
        cfg = JUNCTIONS[jid]

        yellow = NS_YELLOW if js.phase in (NS_THROUGH, NS_LEFT, NS_ALL) else EW_YELLOW

        js.next_green = target_green
        traci.trafficlight.setRedYellowGreenState(
            cfg.tl_id, cfg.phase_signals[yellow]
        )
        js.phase            = yellow
        js.in_yellow        = True
        js.yellow_countdown = YELLOW_DURATION

    def _complete_switch(self, jid: str) -> None:
        js  = self._jstate[jid]
        cfg = JUNCTIONS[jid]

        traci.trafficlight.setRedYellowGreenState(
            cfg.tl_id, cfg.phase_signals[js.next_green]
        )
        js.phase       = js.next_green
        js.in_yellow   = False
        js.phase_timer = 0

        # Track NS green start time for green-wave reward
        if js.phase in (NS_THROUGH, NS_LEFT, NS_ALL):
            js.ns_green_start = float(self._sim_step)

    # ── SUMO Management ──────────────────────────────────────────────────────

    def _start_sumo(self, seed: int | None = None) -> None:
        binary = "sumo-gui" if self.gui else "sumo"
        bin_path = os.path.join(SUMO_HOME, "bin", binary)
        if not os.path.isfile(bin_path):
            bin_path = shutil.which(binary) or shutil.which("sumo")
        if not bin_path:
            raise RuntimeError(f"SUMO binary '{binary}' not found")

        cmd = [
            bin_path,
            "-c", str(CONFIG_FILE),
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

    def _configure_tl(self, jid: str) -> None:
        """Install AI control program for one junction."""
        cfg = JUNCTIONS[jid]
        tl_id = cfg.tl_id

        logics = traci.trafficlight.getAllProgramLogics(tl_id)
        if not logics:
            return

        orig = logics[0]
        long_phases = [
            traci.trafficlight.Phase(1_000_000, p.state)
            for p in orig.phases
        ]
        ai_logic = traci.trafficlight.Logic(
            programID="ai_control", type=0, currentPhaseIndex=0,
            phases=long_phases, subParameter={},
        )
        traci.trafficlight.setProgramLogic(tl_id, ai_logic)
        traci.trafficlight.setProgram(tl_id, "ai_control")
        traci.trafficlight.setRedYellowGreenState(
            tl_id, cfg.phase_signals[NS_THROUGH]
        )

        if self.verbose:
            n_conn = len(cfg.phase_signals[NS_THROUGH])
            print(f"[ENV] {tl_id} AI control installed ({n_conn}-char signals)")

    # ── Metric Collection ────────────────────────────────────────────────────

    def _collect_lane_metrics(self, jid: str) -> dict[str, dict]:
        cfg = JUNCTIONS[jid]
        result = {}
        for lid in cfg.incoming_lanes:
            try:
                q = traci.lane.getLastStepHaltingNumber(lid)
                s = traci.lane.getLastStepMeanSpeed(lid)
                w = traci.lane.getWaitingTime(lid)
            except traci.exceptions.TraCIException:
                q, s, w = 0, 0.0, 0.0
            result[lid] = {
                "queue": float(q), "speed": max(0.0, float(s)), "wait": float(w),
            }
        return result

    def _collect_edge_metrics(self, jid: str) -> dict[str, dict]:
        cfg = JUNCTIONS[jid]
        result = {}
        for edge in cfg.incoming_edges:
            total_q = 0
            total_w = 0.0
            n_lanes = 0
            try:
                n_lanes = traci.edge.getLaneNumber(edge)
                for idx in range(1, n_lanes):  # skip lane 0 (sidewalk)
                    lid = f"{edge}_{idx}"
                    total_q += traci.lane.getLastStepHaltingNumber(lid)
                    total_w += traci.lane.getWaitingTime(lid)
            except traci.exceptions.TraCIException:
                pass
            vehicle_lanes = max(n_lanes - 1, 1)  # exclude sidewalk
            result[edge] = {
                "queue": float(total_q),
                "wait":  float(total_w / vehicle_lanes),
            }
        return result

    def _get_emergency_flags(self, jid: str) -> np.ndarray:
        cfg = JUNCTIONS[jid]
        flags = np.zeros(4, dtype=np.float32)
        for i, edge in enumerate(cfg.incoming_edges):
            try:
                for vid in traci.edge.getLastStepVehicleIDs(edge):
                    if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                        flags[i] = 1.0
                        break
            except traci.exceptions.TraCIException:
                pass
        return flags

    def _get_ped_counts(self, jid: str) -> np.ndarray:
        cfg = JUNCTIONS[jid]
        counts = np.zeros(4, dtype=np.float32)
        for i, wa in enumerate(cfg.walking_areas):
            try:
                counts[i] = float(len(traci.edge.getLastStepPersonIDs(wa)))
            except traci.exceptions.TraCIException:
                pass
        return counts

    def _check_emergency(self, jid: str) -> tuple[bool, int | None]:
        cfg = JUNCTIONS[jid]
        js  = self._jstate[jid]
        for edge in cfg.incoming_edges:
            try:
                for vid in traci.edge.getLastStepVehicleIDs(edge):
                    if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                        continue
                    greens = cfg.edge_to_greens[edge]
                    already_serving = (
                        js.phase in greens
                        or (js.in_yellow and js.next_green in greens)
                    )
                    if not already_serving:
                        return True, greens[0]
            except traci.exceptions.TraCIException:
                pass
        return False, None

    def _track_emergency_vehicles(self) -> None:
        for vid in traci.vehicle.getIDList():
            if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                continue
            wait = traci.vehicle.getAccumulatedWaitingTime(vid)
            prev = self.emergency_log.get(vid, 0.0)
            if wait > prev:
                self.emergency_log[vid] = wait
