#!/usr/bin/env python3
from __future__ import annotations
"""
ATCS-GH | Corridor WebSocket Visualizer Server
════════════════════════════════════════════════
Runs the 3-junction corridor SUMO simulation with multi-agent DQN
and broadcasts real-time state to a Godot 4 3D visualizer over WebSocket.

Architecture:
    SUMO <--TraCI--> This Server <--WebSocket--> Godot 4 Client

Three independent DQN agents control J0, J1, J2.
State/vehicle/pedestrian data for ALL junctions is broadcast every sim-second.

Usage:
    python scripts/corridor_visualizer_server.py                     # AI mode
    python scripts/corridor_visualizer_server.py --demo              # Random actions
    python scripts/corridor_visualizer_server.py --speed 2.0         # 2x speed
    python scripts/corridor_visualizer_server.py --port 9000         # Custom port
"""

import os
import sys
import json
import time
import asyncio
import argparse
import random
from pathlib import Path
import numpy as np


# ── SUMO / TraCI bootstrapping ──────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from corridor_env import (
    _bootstrap_sumo, CorridorEnv,
    JUNCTIONS, JUNCTION_IDS, NEIGHBORS, CORRIDOR_LINKS,
    PHASE_NAMES, GREEN_PHASES,
    NS_THROUGH, NS_LEFT, NS_YELLOW, EW_THROUGH, EW_LEFT, EW_YELLOW,
    NS_ALL, EW_ALL,
    ACTION_HOLD, ACTION_TO_PHASE, ACTION_NAMES, ACTION_SIZE,
    ACTION_NS_THROUGH, ACTION_NS_LEFT,
    ACTION_EW_THROUGH, ACTION_EW_LEFT,
    ACTION_NS_ALL, ACTION_EW_ALL,
    STATE_SIZE, DECISION_INTERVAL, SIM_DURATION,
    MIN_GREEN_THROUGH, MIN_GREEN_LEFT, YELLOW_DURATION,
    EMERGENCY_TYPE,
)

SUMO_HOME = _bootstrap_sumo()

try:
    import traci
    import traci.exceptions
except ImportError as e:
    print(f"[ERROR] Cannot import TraCI: {e}")
    sys.exit(1)

import websockets
from dqn_agent import DQNAgent


# ── Outgoing edges per junction ─────────────────────────────────────────────

OUTGOING_EDGES = {
    "J0": ["ACH_J0toJ1", "ACH_J0toS", "AGG_J0toE", "GUG_J0toW"],
    "J1": ["ACH_J1toJ0", "ACH_J1toJ2", "ASD_J1toE", "RNG_J1toW"],
    "J2": ["ACH_J2toJ1", "ACH_J2toN", "NMA_J2toE", "TSN_J2toW"],
}

# All edges (incoming + outgoing) for vehicle collection
ALL_EDGES = set()
for jid in JUNCTION_IDS:
    cfg = JUNCTIONS[jid]
    ALL_EDGES.update(cfg.incoming_edges)
    ALL_EDGES.update(OUTGOING_EDGES[jid])


# ── Simulation modes ────────────────────────────────────────────────────────

class SimMode:
    AI       = "ai"
    MANUAL   = "manual"
    DEMO     = "demo"
    BASELINE = "baseline"


# ── Fixed-timer baseline controller ──────────────────────────────────────

class BaselineTimer:
    """Fixed-cycle 4-phase traffic light timer for one junction (no AI).

    Proper 4-phase cycle with protected left turns:
      1. NS_THROUGH (40s) — N/S straight + right, left blocked
      2. NS_LEFT    (15s) — N/S protected left turn
      3. EW_THROUGH (25s) — E/W straight + right, left blocked
      4. EW_LEFT    (10s) — E/W protected left turn
    Total cycle: 90s

    Yellow transitions are handled automatically by CorridorEnv when we
    request a phase switch — we just output the target action each step.
    """
    PHASES = [
        (ACTION_NS_THROUGH, 40),
        (ACTION_NS_LEFT,    15),
        (ACTION_EW_THROUGH, 25),
        (ACTION_EW_LEFT,    10),
    ]
    CYCLE = sum(dur for _, dur in PHASES)  # 90s

    def __init__(self, offset: float = 0.0):
        self.offset = offset

    def get_action(self, sim_step: int) -> int:
        """Return proper 4-phase action based on cycle position."""
        adjusted = sim_step - self.offset
        if adjusted < 0:
            return ACTION_NS_THROUGH  # Default to NS through during offset
        cycle_pos = adjusted % self.CYCLE
        elapsed = 0
        for action, duration in self.PHASES:
            elapsed += duration
            if cycle_pos < elapsed:
                return action
        return self.PHASES[0][0]


# ── Global state ─────────────────────────────────────────────────────────────

connected_clients: set = set()
pending_override: dict | None = None
# Runtime control mode — can be switched mid-simulation via WebSocket
active_control_mode: str | None = None   # Set in simulation_loop; None = use startup mode
pending_mode_switch: str | None = None   # Queued by ws_handler, consumed by sim loop

# Queue of pending emergency vehicle spawn requests
pending_emergency_spawns: list[dict] = []
_emergency_spawn_counter: int = 0


# ── WebSocket handler ────────────────────────────────────────────────────────

async def ws_handler(websocket):
    """Handle a single WebSocket client connection."""
    global pending_override, pending_mode_switch, active_control_mode

    connected_clients.add(websocket)
    client_count = len(connected_clients)
    print(f"[WS] Client connected ({client_count} total)")

    # Send current control mode to newly connected client
    if active_control_mode:
        try:
            await websocket.send(json.dumps({
                "type": "mode_changed",
                "control_mode": active_control_mode,
            }))
        except Exception:
            pass

    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                action = data.get("action", "")

                if action == "force_green":
                    approach = data.get("approach", "").lower()
                    junction = data.get("junction", "J0")
                    approach_to_phase = {
                        "north": NS_THROUGH,
                        "south": NS_THROUGH,
                        "east":  EW_THROUGH,
                        "west":  EW_THROUGH,
                    }
                    if approach in approach_to_phase:
                        pending_override = {
                            "junction": junction,
                            "target_phase": approach_to_phase[approach],
                            "approach": approach,
                        }
                        print(f"[WS] Override: {junction} force green for {approach}")
                    else:
                        print(f"[WS] Unknown approach: {approach}")

                elif action == "switch_mode":
                    target_mode = data.get("mode", "").lower()
                    if target_mode in (SimMode.AI, SimMode.BASELINE):
                        pending_mode_switch = target_mode
                        print(f"[WS] Mode switch requested: {target_mode.upper()}")
                    else:
                        print(f"[WS] Unknown mode: {target_mode}")

                elif action == "spawn_emergency":
                    approach = data.get("approach", "north").lower()
                    pending_emergency_spawns.append({"approach": approach})
                    print(f"[WS] Emergency spawn requested from {approach}")

            except json.JSONDecodeError:
                print("[WS] Received invalid JSON, ignoring")

    except websockets.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        remaining = len(connected_clients)
        print(f"[WS] Client disconnected ({remaining} remaining)")


async def broadcast(packet: dict):
    """Send a JSON packet to all connected WebSocket clients."""
    if not connected_clients:
        return
    message = json.dumps(packet)
    websockets.broadcast(connected_clients, message)


# ── Vehicle data collection (all junctions) ─────────────────────────────────

def _collect_vehicle_data() -> list[dict]:
    """
    Collect position, speed, angle, and type for every vehicle
    across all 3 junctions (incoming, outgoing, and internal edges).
    """
    vehicles: list[dict] = []
    seen: set[str] = set()

    # Scan all incoming + outgoing edges
    for edge in ALL_EDGES:
        try:
            for vid in traci.edge.getLastStepVehicleIDs(edge):
                if vid in seen:
                    continue
                seen.add(vid)
                x, y = traci.vehicle.getPosition(vid)
                vehicles.append({
                    "id":    vid,
                    "x":     round(x, 2),
                    "y":     round(y, 2),
                    "speed": round(traci.vehicle.getSpeed(vid), 2),
                    "angle": round(traci.vehicle.getAngle(vid), 1),
                    "type":  traci.vehicle.getTypeID(vid),
                    "edge":  edge,
                })
        except traci.exceptions.TraCIException:
            pass

    # Also capture vehicles traversing junction internals (:J0_*, :J1_*, :J2_*)
    try:
        for vid in traci.vehicle.getIDList():
            if vid in seen:
                continue
            road = traci.vehicle.getRoadID(vid)
            if any(road.startswith(f":{jid}") for jid in JUNCTION_IDS):
                seen.add(vid)
                x, y = traci.vehicle.getPosition(vid)
                vehicles.append({
                    "id":    vid,
                    "x":     round(x, 2),
                    "y":     round(y, 2),
                    "speed": round(traci.vehicle.getSpeed(vid), 2),
                    "angle": round(traci.vehicle.getAngle(vid), 1),
                    "type":  traci.vehicle.getTypeID(vid),
                    "edge":  road,
                })
    except traci.exceptions.TraCIException:
        pass

    return vehicles


# ── Pedestrian data collection (all junctions) ──────────────────────────────

def _collect_pedestrian_data() -> list[dict]:
    """Collect pedestrian positions across the entire corridor."""
    pedestrians: list[dict] = []
    try:
        for pid in traci.person.getIDList():
            x, y = traci.person.getPosition(pid)
            # Include pedestrians near any of the 3 junctions
            # J0 is at (0,0), J1 at (0,300), J2 at (0,600) in SUMO coords
            # offset by SUMO center (1500,1500)
            # So J0=(1500,1500), J1=(1500,1800), J2=(1500,2100)
            # Include if within ~200m of corridor axis (1300 < x < 1700)
            # and within corridor Y range (0 < y < 3600)
            if 1300 < x < 1700 and 0 < y < 3600:
                pedestrians.append({
                    "id":    pid,
                    "x":     round(x, 2),
                    "y":     round(y, 2),
                    "speed": round(traci.person.getSpeed(pid), 2),
                    "angle": round(traci.person.getAngle(pid), 1),
                    "edge":  traci.person.getRoadID(pid),
                })
    except traci.exceptions.TraCIException:
        pass
    return pedestrians


# ── Per-junction state packet builder ────────────────────────────────────────

def _build_junction_packet(env: CorridorEnv, jid: str, action: int,
                            reward: float, preempted: bool) -> dict:
    """Build the state sub-packet for one junction."""
    cfg = JUNCTIONS[jid]
    js  = env._jstate[jid]

    edge_metrics = env._collect_edge_metrics(jid)
    emergency_flags = env._get_emergency_flags(jid)
    lane_m = env._collect_lane_metrics(jid)

    # Per-approach names (N, E, S, W)
    approach_names = ["north", "east", "south", "west"]

    # Queues and waits per approach
    queues = {}
    wait_times = {}
    for i, edge in enumerate(cfg.incoming_edges):
        name = approach_names[i]
        queues[name]     = edge_metrics[edge]["queue"]
        wait_times[name] = round(edge_metrics[edge]["wait"], 1)

    # Emergency info
    emergency_approach = None
    emergency_vid = None
    for i, edge in enumerate(cfg.incoming_edges):
        if emergency_flags[i] > 0:
            emergency_approach = approach_names[i]
            try:
                for vid in traci.edge.getLastStepVehicleIDs(edge):
                    if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE:
                        emergency_vid = vid
                        break
            except traci.exceptions.TraCIException:
                pass
            break

    # Per-lane sensor data
    lane_data = {}
    for lid in cfg.incoming_lanes:
        lm = lane_m[lid]
        lane_data[lid] = {
            "queue": int(lm["queue"]),
            "speed": round(lm["speed"], 2),
            "wait":  round(lm["wait"], 1),
        }

    # Crossing signals based on current phase
    sig = cfg.phase_signals.get(js.phase, "r" * 30)
    sig_len = len(sig)
    # Last 4 chars are crossings: c0, c1, c2, c3
    # c0=N crossing, c1=E crossing, c2=S crossing, c3=W crossing
    crossing_green = {
        "north": sig[sig_len - 4] in "Gg" if sig_len >= 4 else False,
        "east":  sig[sig_len - 3] in "Gg" if sig_len >= 3 else False,
        "south": sig[sig_len - 2] in "Gg" if sig_len >= 2 else False,
        "west":  sig[sig_len - 1] in "Gg" if sig_len >= 1 else False,
    }

    avg_wait = (float(np.mean(env.episode_waits[jid]))
                if env.episode_waits[jid] else 0.0)

    return {
        "junction_id": jid,
        "phase": js.phase,
        "phase_name": PHASE_NAMES.get(js.phase, "UNKNOWN"),
        "phase_timer": js.phase_timer,
        "in_yellow": js.in_yellow,
        "queues": queues,
        "wait_times": wait_times,
        "avg_wait": round(avg_wait, 1),
        "emergency": {
            "active": bool(any(emergency_flags)),
            "approach": emergency_approach,
            "vehicle_id": emergency_vid,
        },
        "ai_decision": ACTION_NAMES[action] if action < len(ACTION_NAMES) else "UNKNOWN",
        "reward": round(reward, 1),
        "lane_data": lane_data,
        "crossing_green": crossing_green,
        "preempted": preempted,
    }


# ── Emergency vehicle spawner (corridor) ──────────────────────────────────

# For corridor, spawn ambulances on the main N-S Achimota corridor
# approaching from N (top) or S (bottom), or from side streets at J1.
# approach → (incoming edge, route edges for through-movement)
CORRIDOR_APPROACH_ROUTES = {
    # N-S through corridor (enters J2 from north, exits J0 south)
    "north": ("ACH_N2J2",     "ACH_N2J2 ACH_J2toJ1 ACH_J1toJ0 ACH_J0toS"),
    # S-N through corridor (enters J0 from south, exits J2 north)
    "south": ("ACH_S2J0",     "ACH_S2J0 ACH_J0toJ1 ACH_J1toJ2 ACH_J2toN"),
    # E-W at J1 (enters from Asylum Down, exits to Ring Road)
    "east":  ("ASD_E2J1",     "ASD_E2J1 RNG_J1toW"),
    # W-E at J1 (enters from Ring Road, exits to Asylum Down)
    "west":  ("RNG_W2J1",     "RNG_W2J1 ASD_J1toE"),
}


def _spawn_emergency_vehicles():
    """Process pending emergency spawn requests for corridor simulation."""
    global _emergency_spawn_counter

    while pending_emergency_spawns:
        req = pending_emergency_spawns.pop(0)
        approach = req.get("approach", "north")
        if approach not in CORRIDOR_APPROACH_ROUTES:
            print(f"[SPAWN] Unknown approach '{approach}', defaulting to north")
            approach = "north"

        _emergency_spawn_counter += 1
        vid = f"manual_ambulance_{_emergency_spawn_counter}"
        edge, route_edges = CORRIDOR_APPROACH_ROUTES[approach]
        route_id = f"emer_route_{_emergency_spawn_counter}"

        try:
            traci.route.add(route_id, route_edges.split())
            traci.vehicle.add(
                vehID=vid,
                routeID=route_id,
                typeID=EMERGENCY_TYPE,
                depart="now",
                departSpeed="max",
            )
            print(f"[SPAWN] Ambulance '{vid}' deployed from {approach} ({edge})")
        except traci.exceptions.TraCIException as e:
            print(f"[SPAWN] Failed to spawn ambulance: {e}")


# ── Simulation loop ─────────────────────────────────────────────────────────

async def simulation_loop(mode: str, model_dir: Path, speed: float):
    """
    Main simulation loop: run corridor SUMO, make decisions, broadcast state.

    Uses CorridorEnv for SUMO management. After each step, we broadcast
    per-junction state + vehicle positions to all connected Godot clients.

    Supports runtime switching between AI and BASELINE modes via WebSocket.
    """
    global pending_override, active_control_mode, pending_mode_switch

    # ── Load agents ──────────────────────────────────────────────────────
    agents: dict[str, DQNAgent | None] = {jid: None for jid in JUNCTION_IDS}

    if mode == SimMode.AI:
        all_loaded = True
        for jid in JUNCTION_IDS:
            agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
            model_path = model_dir / f"best_{jid}.pth"
            if model_path.exists():
                agent.load(str(model_path))
                agent.set_eval_mode()
                print(f"[SIM] {jid}: Loaded model {model_path.name}")
            else:
                print(f"[WARN] {jid}: Model not found: {model_path}")
                all_loaded = False
            agents[jid] = agent

        if not all_loaded:
            print("[WARN] Some models missing — falling back to DEMO mode")
            mode = SimMode.DEMO

    elif mode == SimMode.DEMO:
        print("[SIM] Demo mode -- using random actions")

    elif mode == SimMode.MANUAL:
        print("[SIM] Manual mode -- waiting for Godot UI commands")

    elif mode == SimMode.BASELINE:
        print("[SIM] Baseline mode -- fixed-timer cycling (60s NS / 30s EW)")

    # Baseline timers (always created — used when switching to baseline at runtime)
    # Green-wave offset ~22s for 300m spacing at 50 km/h
    baseline_offset = 22.0
    baseline_timers: dict[str, BaselineTimer] = {
        "J0": BaselineTimer(offset=0.0),
        "J1": BaselineTimer(offset=baseline_offset),
        "J2": BaselineTimer(offset=baseline_offset * 2),
    }

    # Set the active control mode (can be changed at runtime via WebSocket)
    active_control_mode = mode

    # ── Initialise SUMO environment ──────────────────────────────────────
    env = CorridorEnv(gui=False, verbose=False)
    run_count = 0

    try:
        while True:
            seed = 42 + run_count * 137
            states = env.reset(seed=seed)
            run_count += 1
            print(f"\n[SIM] Run #{run_count} started (seed={seed})")

            await broadcast({
                "type": "sim_restart",
                "run": run_count,
                "seed": seed,
                "mode": "corridor",
                "junctions": JUNCTION_IDS,
            })

            done = False
            step_count = 0

            # Track per-step actions/rewards for broadcast
            last_actions = {jid: ACTION_HOLD for jid in JUNCTION_IDS}
            last_rewards = {jid: 0.0 for jid in JUNCTION_IDS}
            last_preempted = {jid: False for jid in JUNCTION_IDS}

            while not done:
                decision_start = time.time()

                # ── Check for runtime mode switch ─────────────────────────
                if pending_mode_switch is not None:
                    new_mode = pending_mode_switch
                    pending_mode_switch = None
                    if new_mode != active_control_mode:
                        active_control_mode = new_mode
                        print(f"[SIM] Control mode switched to: "
                              f"{active_control_mode.upper()}")
                        # Broadcast mode change to all clients
                        await broadcast({
                            "type": "mode_changed",
                            "control_mode": active_control_mode,
                        })

                # ── Determine actions ──────────────────────────────────────
                actions = {}

                for jid in JUNCTION_IDS:
                    if (pending_override is not None
                            and pending_override.get("junction") == jid):
                        override = pending_override
                        pending_override = None
                        target = override["target_phase"]
                        action = ACTION_HOLD
                        for act_idx, phase in ACTION_TO_PHASE.items():
                            if phase == target:
                                action = act_idx
                                break
                        actions[jid] = action
                        print(f"[SIM] {jid} override: {override['approach']} "
                              f"-> {ACTION_NAMES[action]}")
                    elif active_control_mode == SimMode.AI and agents[jid] is not None:
                        actions[jid] = agents[jid].select_action(states[jid])
                    elif active_control_mode == SimMode.BASELINE:
                        actions[jid] = baseline_timers[jid].get_action(
                            env._sim_step)
                    elif active_control_mode == SimMode.DEMO:
                        actions[jid] = (0 if random.random() < 0.6
                                        else random.randint(1, 6))
                    else:
                        actions[jid] = ACTION_HOLD

                # ── Spawn any manually-requested emergency vehicles ───────
                _spawn_emergency_vehicles()

                # ── Apply actions (same as env.step start) ─────────────────
                for jid in JUNCTION_IDS:
                    action = actions[jid]
                    js = env._jstate[jid]

                    preempted, forced_phase = env._check_emergency(jid)
                    last_preempted[jid] = preempted

                    if preempted:
                        if forced_phase != js.phase and env._can_switch(jid):
                            env._initiate_switch(jid, forced_phase)
                    elif action != ACTION_HOLD and env._can_switch(jid):
                        target = ACTION_TO_PHASE.get(action)
                        if target is not None and target != js.phase:
                            env._initiate_switch(jid, target)

                # ── Step SUMO one second at a time, broadcasting ───────────
                block_arrived = 0
                sub_step_done = False

                for sub in range(DECISION_INTERVAL):
                    sub_start = time.time()

                    # Handle yellow countdowns
                    for jid in JUNCTION_IDS:
                        js = env._jstate[jid]
                        if js.in_yellow:
                            js.yellow_countdown -= 1
                            if js.yellow_countdown <= 0:
                                env._complete_switch(jid)

                    traci.simulationStep()
                    env._sim_step += 1

                    for jid in JUNCTION_IDS:
                        env._jstate[jid].phase_timer += 1

                    block_arrived += traci.simulation.getArrivedNumber()
                    env._track_emergency_vehicles()

                    # Broadcast vehicle + pedestrian positions every sim-second
                    vehicle_data = _collect_vehicle_data()
                    ped_data = _collect_pedestrian_data()
                    await broadcast({
                        "type": "vehicle_update",
                        "vehicles": vehicle_data,
                        "pedestrians": ped_data,
                        "sim_time": env._sim_step,
                        "mode": "corridor",
                    })

                    if traci.simulation.getMinExpectedNumber() == 0:
                        sub_step_done = True
                        break

                    # Pacing: 1 sim-second of real time divided by speed
                    sub_elapsed = time.time() - sub_start
                    sub_sleep = max(0.005, (1.0 / speed) - sub_elapsed)
                    await asyncio.sleep(sub_sleep)

                # ── End-of-decision metrics ────────────────────────────────
                env.total_arrived += block_arrived

                for jid in JUNCTION_IDS:
                    js = env._jstate[jid]
                    cfg = JUNCTIONS[jid]
                    action = actions[jid]

                    edge_metrics = env._collect_edge_metrics(jid)
                    queues = [edge_metrics[e]["queue"] for e in cfg.incoming_edges]
                    waits  = [edge_metrics[e]["wait"]  for e in cfg.incoming_edges]
                    total_q = float(sum(queues))

                    ped_counts = env._get_ped_counts(jid)
                    total_ped = int(sum(ped_counts))

                    preempted = last_preempted[jid]
                    min_g = (MIN_GREEN_LEFT if js.phase in (NS_LEFT, EW_LEFT)
                             else MIN_GREEN_THROUGH)

                    r_local = env._compute_local_reward(
                        total_queue=total_q,
                        prev_total_queue=js.prev_total_queue,
                        n_arrived=block_arrived // len(JUNCTION_IDS),
                        n_emerg_waiting=0,
                        switched_too_soon=(action != ACTION_HOLD and not preempted
                                           and js.phase_timer < min_g),
                        queue_distribution=queues,
                        wait_distribution=waits,
                        n_ped_waiting=total_ped,
                    )
                    r_corridor = env._compute_corridor_reward(jid)
                    reward = r_local + r_corridor

                    js.prev_total_queue = total_q

                    avg_wait = float(np.mean(waits)) if waits else 0.0
                    env.episode_rewards[jid].append(reward)
                    env.episode_waits[jid].append(avg_wait)

                    last_actions[jid] = action
                    last_rewards[jid] = reward

                done = (env._sim_step >= SIM_DURATION or sub_step_done)
                next_states = {jid: env._build_state(jid) for jid in JUNCTION_IDS}

                # ── Build and broadcast full state packet ──────────────────
                junction_states = {}
                for jid in JUNCTION_IDS:
                    junction_states[jid] = _build_junction_packet(
                        env, jid, last_actions[jid],
                        last_rewards[jid], last_preempted[jid]
                    )

                corridor_avg_wait = env.corridor_avg_wait()
                corridor_total_reward = env.corridor_total_reward()

                packet = {
                    "type": "state_update",
                    "mode": "corridor",
                    "control_mode": active_control_mode,

                    # Global timing
                    "step": env._sim_step,
                    "sim_time": env._sim_step,

                    # Per-junction state
                    "junctions": junction_states,

                    # Also broadcast J0 state at top level for backwards compat
                    "phase": env._jstate["J0"].phase,
                    "phase_name": PHASE_NAMES.get(env._jstate["J0"].phase, "UNKNOWN"),
                    "phase_timer": env._jstate["J0"].phase_timer,
                    "in_yellow": env._jstate["J0"].in_yellow,

                    # Corridor aggregate stats
                    "vehicles_completed": env.total_arrived,
                    "corridor_avg_wait": round(corridor_avg_wait, 1),
                    "avg_wait": round(corridor_avg_wait, 1),
                    "total_reward": round(corridor_total_reward, 1),

                    # Per-vehicle positions (all junctions)
                    "vehicles": _collect_vehicle_data(),

                    # Pedestrians (all junctions)
                    "pedestrians": _collect_pedestrian_data(),

                    # Legacy fields for J0 (backwards compat with single-junction UI)
                    "queues": junction_states["J0"]["queues"],
                    "wait_times": junction_states["J0"]["wait_times"],
                    "emergency": junction_states["J0"]["emergency"],
                    "ai_decision": junction_states["J0"]["ai_decision"],
                    "reward": junction_states["J0"]["reward"],
                    "crossing_green": junction_states["J0"]["crossing_green"],
                    "lane_data": junction_states["J0"]["lane_data"],
                    "preempted": junction_states["J0"]["preempted"],

                    "done": done,
                }

                await broadcast(packet)
                states = next_states
                step_count += 1

            # ── Simulation complete ──────────────────────────────────────
            print(f"[SIM] Run #{run_count} complete -- "
                  f"{env.total_arrived} vehicles, "
                  f"corridor avg wait {env.corridor_avg_wait():.1f}s")

            await broadcast({
                "type": "sim_complete",
                "mode": "corridor",
                "total_arrived": env.total_arrived,
                "corridor_avg_wait": round(env.corridor_avg_wait(), 1),
                "avg_wait": round(env.corridor_avg_wait(), 1),
                "total_reward": round(env.corridor_total_reward(), 1),
            })

            print("[SIM] Restarting in 5 seconds...")
            await asyncio.sleep(5.0)

    except asyncio.CancelledError:
        print("\n[SIM] Simulation cancelled")
    except KeyboardInterrupt:
        print("\n[SIM] Interrupted by user")
    finally:
        env.close()
        print("[SIM] SUMO connection closed")


# ── Main entry point ─────────────────────────────────────────────────────────

async def main(args):
    """Start WebSocket server and corridor simulation loop concurrently."""
    if args.baseline:
        mode = SimMode.BASELINE
    elif args.demo:
        mode = SimMode.DEMO
    elif args.manual:
        mode = SimMode.MANUAL
    else:
        mode = SimMode.AI

    model_dir = Path(args.model_dir)

    print()
    print("=" * 62)
    print("  ATCS-GH  |  Corridor 3D Visualizer Server")
    print("=" * 62)
    print(f"  Mode       : {mode.upper()}")
    print(f"  Junctions  : {', '.join(JUNCTION_IDS)}")
    print(f"  Model dir  : {model_dir}")
    print(f"  Speed      : {args.speed}x")
    print(f"  WebSocket  : ws://localhost:{args.port}")
    print(f"  Sim length : {SIM_DURATION}s ({SIM_DURATION/3600:.1f} hours)")
    print("=" * 62)
    print()
    print("  Waiting for Godot clients to connect...")
    print("  Open the Godot project in visualizer/ and press F5.")
    print()

    async with websockets.serve(ws_handler, "localhost", args.port):
        await simulation_loop(mode, model_dir, args.speed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ATCS-GH Corridor WebSocket Visualizer Server -- "
                    "bridges SUMO corridor + multi-agent DQN to Godot 4 client"
    )
    parser.add_argument(
        "--model-dir", type=str,
        default=str(PROJECT_ROOT / "ai" / "checkpoints" / "corridor"),
        help="Directory with corridor DQN models (default: ai/checkpoints/corridor/)"
    )
    parser.add_argument(
        "--manual", action="store_true",
        help="Manual override mode"
    )
    parser.add_argument(
        "--demo", action="store_true",
        help="Demo mode -- random actions, no trained model needed"
    )
    parser.add_argument(
        "--baseline", action="store_true",
        help="Fixed-timer baseline mode (60s NS / 30s EW cycle)"
    )
    parser.add_argument(
        "--speed", type=float, default=1.0,
        help="Simulation speed multiplier (default: 1.0 = real-time)"
    )
    parser.add_argument(
        "--port", type=int, default=8765,
        help="WebSocket server port (default: 8765)"
    )

    args = parser.parse_args()
    try:
        asyncio.run(main(args))
    except KeyboardInterrupt:
        print("\n[SERVER] Stopped.")
