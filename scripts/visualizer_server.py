#!/usr/bin/env python3
"""
ATCS-GH | WebSocket Visualizer Server
═══════════════════════════════════════
Runs the SUMO simulation with the DQN agent and broadcasts
real-time state to a Godot 4 3D visualizer over WebSocket.

Architecture:
    SUMO <--TraCI--> This Server <--WebSocket--> Godot 4 Client

The server runs the simulation loop, makes AI decisions every
DECISION_INTERVAL seconds, and broadcasts a JSON state packet
to all connected Godot clients. It also accepts manual override
commands from the Godot UI.

Usage:
    python scripts/visualizer_server.py                  # AI mode (default)
    python scripts/visualizer_server.py --manual         # Manual override mode
    python scripts/visualizer_server.py --demo           # Random actions (no model)
    python scripts/visualizer_server.py --speed 2.0      # 2x simulation speed
    python scripts/visualizer_server.py --port 9000      # Custom WebSocket port
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
# (Same pattern as run_ai.py — locate SUMO and add TraCI tools to sys.path)

def _setup_sumo() -> str:
    """Locate SUMO installation and add TraCI to Python path."""
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
        print("[ERROR] SUMO not found. Install via: pip install eclipse-sumo")
        print("        or: brew tap dlr-ts/sumo && brew install sumo")
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

import websockets

from dqn_agent import DQNAgent
from traffic_env import (
    TL_ID, INCOMING_EDGES, EMERGENCY_TYPE,
    NS_GREEN, NS_YELLOW, EW_GREEN, EW_YELLOW, PHASE_NAMES,
    EDGE_TO_GREEN, STATE_SIZE, ACTION_SIZE,
    DECISION_INTERVAL, MIN_GREEN_DURATION, YELLOW_DURATION,
    MAX_QUEUE, MAX_WAIT, MAX_PHASE_T, SIM_DURATION,
    TrafficEnv,
)

# Outgoing edges (junction → direction)
OUTGOING_EDGES = ["J2N", "J2S", "J2E", "J2W"]


# ── Simulation modes ────────────────────────────────────────────────────────

class SimMode:
    """Enumeration of simulation control modes."""
    AI     = "ai"       # DQN agent controls traffic lights
    MANUAL = "manual"   # Godot UI controls via override messages
    DEMO   = "demo"     # Random actions (no model needed)


# ── Global state ─────────────────────────────────────────────────────────────

# Set of currently connected WebSocket clients
connected_clients: set = set()

# Pending manual override from Godot UI (consumed by simulation loop)
# Format: {"target_phase": int, "approach": str} or None
pending_override: dict | None = None


# ── WebSocket handler ────────────────────────────────────────────────────────

async def ws_handler(websocket):
    """
    Handle a single WebSocket client connection.

    Accepts incoming messages for manual override:
        {"action": "force_green", "approach": "north"}

    The override is stored in `pending_override` and consumed by the
    simulation loop on the next decision step.
    """
    global pending_override

    connected_clients.add(websocket)
    client_count = len(connected_clients)
    print(f"[WS] Client connected ({client_count} total)")

    try:
        async for message in websocket:
            try:
                data = json.loads(message)

                if data.get("action") == "force_green":
                    approach = data.get("approach", "").lower()
                    # Map approach name to target green phase
                    # North and South share NS_GREEN; East and West share EW_GREEN
                    approach_to_phase = {
                        "north": NS_GREEN,
                        "south": NS_GREEN,
                        "east":  EW_GREEN,
                        "west":  EW_GREEN,
                    }
                    if approach in approach_to_phase:
                        pending_override = {
                            "target_phase": approach_to_phase[approach],
                            "approach": approach,
                        }
                        print(f"[WS] Manual override received: force green for {approach}")
                    else:
                        print(f"[WS] Unknown approach: {approach}")

            except json.JSONDecodeError:
                print("[WS] Received invalid JSON, ignoring")

    except websockets.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        remaining = len(connected_clients)
        print(f"[WS] Client disconnected ({remaining} remaining)")


async def broadcast(packet: dict):
    """
    Send a JSON packet to all connected WebSocket clients.

    Uses websockets.broadcast() for efficient delivery.
    Silently handles disconnected clients.
    """
    if not connected_clients:
        return
    message = json.dumps(packet)
    websockets.broadcast(connected_clients, message)


# ── Per-vehicle data collection ─────────────────────────────────────────────

def _collect_vehicle_data() -> list[dict]:
    """
    Collect position, speed, angle, and type for every vehicle
    near the junction (incoming edges, outgoing edges, and internal
    junction lanes).  Returns a list of dicts suitable for JSON.
    """
    vehicles: list[dict] = []
    seen: set[str] = set()

    # Scan incoming + outgoing edges
    for edge in INCOMING_EDGES + OUTGOING_EDGES:
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

    # Also capture vehicles traversing the junction (internal edges :J0_*)
    try:
        for vid in traci.vehicle.getIDList():
            if vid in seen:
                continue
            road = traci.vehicle.getRoadID(vid)
            if road.startswith(":J0"):
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


# ── Simulation loop ─────────────────────────────────────────────────────────

async def simulation_loop(mode: str, model_path: Path, speed: float):
    """
    Main simulation loop: run SUMO, make decisions, broadcast state.

    Uses TrafficEnv directly for SUMO management. The env.step() method
    handles all phase transitions, yellow logic, and emergency preemption
    internally. After each step, we read the env's internal state to build
    the broadcast packet.

    Args:
        mode:       One of SimMode.AI, SimMode.MANUAL, SimMode.DEMO
        model_path: Path to trained DQN model checkpoint
        speed:      Simulation speed multiplier (1.0 = real-time)
    """
    global pending_override

    # ── Load agent (or set up demo/manual mode) ──────────────────────────
    agent = None

    if mode == SimMode.AI:
        agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
        if model_path.exists():
            agent.load(model_path)
            agent.set_eval_mode()
            print(f"[SIM] Loaded model: {model_path.name}")
        else:
            print(f"[WARN] Model not found: {model_path}")
            print("[WARN] Falling back to DEMO mode (random actions)")
            mode = SimMode.DEMO

    elif mode == SimMode.DEMO:
        print("[SIM] Demo mode — using random actions")

    elif mode == SimMode.MANUAL:
        print("[SIM] Manual mode — waiting for Godot UI commands")

    # ── Initialise SUMO environment ──────────────────────────────────────
    env = TrafficEnv(gui=False, verbose=False)
    run_count = 0

    try:
        while True:
            # Reset the simulation
            seed = 42 + run_count * 137
            state = env.reset(seed=seed)
            run_count += 1
            print(f"\n[SIM] Run #{run_count} started (seed={seed})")

            await broadcast({
                "type": "sim_restart",
                "run": run_count,
                "seed": seed,
            })

            done = False
            step_count = 0

            while not done:
                decision_start = time.time()

                # ── Determine action ─────────────────────────────────────
                if pending_override is not None:
                    # Manual override from Godot UI
                    override = pending_override
                    pending_override = None
                    target = override["target_phase"]
                    # Force switch if not already on the target phase
                    if target != env._phase and env._phase in (NS_GREEN, EW_GREEN):
                        action = 1   # Switch
                    else:
                        action = 0   # Already on correct phase (or in yellow)
                    print(f"[SIM] Override applied: {override['approach']} → "
                          f"action={action}")

                elif mode == SimMode.AI and agent is not None:
                    action = agent.select_action(state)

                elif mode == SimMode.DEMO:
                    # Random action with bias toward keeping (70% keep, 30% switch)
                    action = 0 if random.random() < 0.7 else 1

                else:
                    # Manual mode default: keep current phase
                    action = 0

                # ── Step the simulation (per-second for smooth animation) ─
                # Call env.step() for AI/reward logic (advances 5 SUMO steps)
                # but ALSO broadcast vehicle positions after each sub-step.
                #
                # We replicate the inner loop manually so we can broadcast
                # intermediate vehicle positions. The env.step() is called
                # AFTER to keep reward/state computation correct.

                # --- Phase 1: Apply action to env (same as env.step start) ---
                preempted, forced_phase = env._check_emergency_preemption()
                if preempted:
                    actual_action = 1 if forced_phase != env._phase else 0
                    if actual_action == 1:
                        env._initiate_switch(target_green=forced_phase)
                elif action == 1 and env._can_switch():
                    env._initiate_switch()

                # --- Phase 2: Step SUMO one second at a time, broadcasting ---
                block_arrived = 0
                sub_step_done = False

                for sub in range(DECISION_INTERVAL):
                    sub_start = time.time()

                    # Handle yellow countdown
                    if env._in_yellow:
                        env._yellow_countdown -= 1
                        if env._yellow_countdown <= 0:
                            env._complete_switch()

                    traci.simulationStep()
                    env._sim_step += 1
                    env._phase_timer += 1

                    block_arrived += traci.simulation.getArrivedNumber()
                    env._track_emergency_vehicles()

                    # Broadcast vehicle positions every sim-second
                    vehicle_data = _collect_vehicle_data()
                    await broadcast({
                        "type": "vehicle_update",
                        "vehicles": vehicle_data,
                        "sim_time": env._sim_step,
                    })

                    # Check early termination
                    if traci.simulation.getMinExpectedNumber() == 0:
                        sub_step_done = True
                        break

                    # Sleep 1 sim-second of real time (divided by speed)
                    sub_elapsed = time.time() - sub_start
                    sub_sleep = max(0.005, (1.0 / speed) - sub_elapsed)
                    await asyncio.sleep(sub_sleep)

                # --- Phase 3: Collect end-of-decision metrics (same as env.step end) ---
                edge_metrics = env._collect_edge_metrics()
                emergency_flags = env._get_emergency_flags()

                # Update env internal accumulators (normally done inside step)
                final_queues = []
                final_waits = []
                for edge in INCOMING_EDGES:
                    final_queues.append(edge_metrics[edge]["queue"])
                    final_waits.append(edge_metrics[edge]["wait"])

                total_queue = float(sum(final_queues))
                env.total_arrived += block_arrived
                reward = env._compute_reward(
                    total_queue=total_queue,
                    prev_total_queue=env._prev_total_queue,
                    n_arrived=block_arrived,
                    n_emerg_waiting=0,
                    switched_too_soon=(action == 1 and not preempted
                                      and env._phase_timer < MIN_GREEN_DURATION),
                    queue_distribution=final_queues,
                )
                env._prev_total_queue = total_queue

                avg_wait = float(np.mean(final_waits)) if final_waits else 0.0
                env.episode_rewards.append(reward)
                env.episode_queues.append(total_queue)
                env.episode_waits.append(avg_wait)

                done = (
                    env._sim_step >= SIM_DURATION
                    or sub_step_done
                )
                next_state = env._build_state()

                # Find emergency approach for display
                emergency_approach = None
                emergency_vid = None
                approach_names = ["north", "south", "east", "west"]
                for i, edge in enumerate(INCOMING_EDGES):
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

                vehicle_data = _collect_vehicle_data()

                # ── Build full state broadcast packet ─────────────────────
                packet = {
                    "type": "state_update",

                    # Timing
                    "step": env._sim_step,
                    "sim_time": env._sim_step,

                    # Phase state
                    "phase": env._phase,
                    "phase_name": PHASE_NAMES.get(env._phase, "UNKNOWN"),
                    "phase_timer": env._phase_timer,
                    "in_yellow": env._in_yellow,

                    # Per-approach queues
                    "queues": {
                        "north": edge_metrics["N2J"]["queue"],
                        "south": edge_metrics["S2J"]["queue"],
                        "east":  edge_metrics["E2J"]["queue"],
                        "west":  edge_metrics["W2J"]["queue"],
                    },

                    # Per-approach wait times
                    "wait_times": {
                        "north": round(edge_metrics["N2J"]["wait"], 1),
                        "south": round(edge_metrics["S2J"]["wait"], 1),
                        "east":  round(edge_metrics["E2J"]["wait"], 1),
                        "west":  round(edge_metrics["W2J"]["wait"], 1),
                    },

                    # Aggregate stats
                    "vehicles_completed": env.total_arrived,
                    "avg_wait": round(env.episode_avg_wait, 1),

                    # Emergency
                    "emergency": {
                        "active": bool(any(emergency_flags)),
                        "approach": emergency_approach,
                        "vehicle_id": emergency_vid,
                    },

                    # AI decision
                    "ai_decision": "SWITCH" if action == 1 else "HOLD",
                    "reward": round(reward, 1),
                    "total_reward": round(env.episode_total_reward, 1),

                    # Per-vehicle positions
                    "vehicles": vehicle_data,

                    # Meta
                    "mode": mode,
                    "preempted": preempted,
                    "done": done,
                }

                await broadcast(packet)

                state = next_state
                step_count += 1

            # ── Simulation complete ──────────────────────────────────────
            print(f"[SIM] Run #{run_count} complete — "
                  f"{env.total_arrived} vehicles, "
                  f"avg wait {env.episode_avg_wait:.1f}s")

            await broadcast({
                "type": "sim_complete",
                "total_arrived": env.total_arrived,
                "avg_wait": round(env.episode_avg_wait, 1),
                "total_reward": round(env.episode_total_reward, 1),
            })

            # Pause before restarting
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
    """Start WebSocket server and simulation loop concurrently."""
    # Determine simulation mode
    if args.demo:
        mode = SimMode.DEMO
    elif args.manual:
        mode = SimMode.MANUAL
    else:
        mode = SimMode.AI

    model_path = Path(args.model)

    print()
    print("═" * 58)
    print("  ATCS-GH  |  3D Visualizer Server")
    print("═" * 58)
    print(f"  Mode       : {mode.upper()}")
    print(f"  Model      : {model_path}")
    print(f"  Speed      : {args.speed}x")
    print(f"  WebSocket  : ws://localhost:{args.port}")
    print(f"  Sim length : {SIM_DURATION}s ({SIM_DURATION/3600:.1f} hours)")
    print("═" * 58)
    print()
    print("  Waiting for Godot clients to connect...")
    print("  Open the Godot project in visualizer/ and press F5.")
    print()

    # Start WebSocket server, then run simulation loop
    async with websockets.serve(ws_handler, "localhost", args.port):
        await simulation_loop(mode, model_path, args.speed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ATCS-GH WebSocket Visualizer Server — "
                    "bridges SUMO + DQN to Godot 4 3D client"
    )
    parser.add_argument(
        "--model", type=str,
        default=str(PROJECT_ROOT / "ai" / "best_model.pth"),
        help="Path to trained DQN model (default: ai/best_model.pth)"
    )
    parser.add_argument(
        "--manual", action="store_true",
        help="Manual override mode — no AI decisions, Godot UI controls lights"
    )
    parser.add_argument(
        "--demo", action="store_true",
        help="Demo mode — random actions, no trained model needed"
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
