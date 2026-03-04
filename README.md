# ATCS-GH — Adaptive Traffic Control System Ghana

> **AI-powered smart traffic control for the Achimota/Neoplan Junction, Accra**

---

## Overview

ATCS-GH uses a **Double DQN** reinforcement learning agent to adaptively control traffic signals at a real Accra junction — the Achimota/Neoplan Junction on the N6 Nsawam Road (GPS: 5.6216N, 0.2193W). The system replaces traditional fixed-timer lights with an AI that observes real-time traffic and dynamically adjusts signal phases to minimise wait times, reduce congestion, and prioritise emergency vehicles.

The project includes a **real-time 3D visualiser** built in Godot 4 — entirely procedural (no external assets, no plugins) — connected to the simulation via WebSocket.

| Phase | Status | Description |
|-------|--------|-------------|
| **Phase 1** | Done | Fixed-timer baseline (81.83s avg wait) |
| **Phase 2** | Active | DQN agent with 7-action control, training in progress |
| **Phase 3** | Future | Multi-intersection N6 corridor, field testing |

### Target

**40% reduction** in average vehicle wait time: from 81.83s (baseline) to below 49.10s using AI-controlled signals.

---

## Architecture

```
SUMO Traffic Sim <--TraCI--> Python AI Server <--WebSocket--> Godot 4 Visualiser
                             (port 8765)                     (3D Renderer)
```

| Component | Technology | Role |
|-----------|-----------|------|
| Traffic Simulation | SUMO + TraCI | Microsimulation of vehicles and signals |
| AI Agent | PyTorch (Double DQN) | Observes 38-dim state, selects from 7 actions |
| Training Pipeline | Python | Epsilon-greedy, experience replay, target network |
| WebSocket Server | Python asyncio | Bridges AI to the visualiser in real-time |
| 3D Visualiser | Godot 4 (GDScript) | Procedural 3D rendering of live traffic |

---

## Project Structure

```
ATCS-GH/
├── simulation/                    # SUMO network files
│   ├── nodes.nod.xml              # Junction node definition
│   ├── edges.edg.xml              # Road edges (Achimota-calibrated)
│   ├── routes.rou.xml             # Vehicle demand + trotros + ambulances
│   ├── intersection.sumocfg       # SUMO configuration
│   └── intersection.net.xml       # Generated network (15 connections)
│
├── ai/                            # DQN agent and environment
│   ├── traffic_env.py             # Gym-style SUMO environment (38-dim state, 7 actions)
│   ├── dqn_agent.py               # Double DQN with replay buffer
│   ├── best_model.pth             # Best trained model checkpoint
│   └── checkpoints/               # Periodic training checkpoints
│
├── scripts/
│   ├── build_network.py           # Compile net.xml via netconvert
│   ├── run_baseline.py            # Phase 1 fixed-timer simulation
│   ├── train_agent.py             # Phase 2 DQN training loop
│   ├── run_ai.py                  # Run trained AI on full 2-hour scenario
│   ├── eval_multi_seed.py         # Multi-seed evaluation with confidence intervals
│   ├── visualizer_server.py       # WebSocket server for Godot visualiser
│   ├── metrics_logger.py          # Shared metrics collection (CSV output)
│   └── launch_visualizer.sh       # One-line launch script
│
├── visualizer/                    # Godot 4 project (fully procedural)
│   ├── project.godot
│   └── scripts/
│       ├── Main.gd                # Orchestrator
│       ├── Intersection.gd        # 3D road geometry + traffic lights
│       ├── VehicleManager.gd      # Vehicle pool rendering
│       ├── UI.gd                  # HUD overlay
│       ├── MetricsChart.gd        # Real-time chart plotting
│       ├── AudioManager.gd        # Ambient sounds + sirens
│       └── WebSocketClient.gd     # Server connection
│
├── data/                          # Generated CSV results
│   ├── baseline_results.csv
│   ├── training_log.csv
│   └── ai_results.csv
│
└── requirements.txt
```

---

## Quick Start

### 1. Install Dependencies

```bash
pip install -r requirements.txt
```

SUMO is required:
```bash
pip install eclipse-sumo    # easiest method
# or
brew install sumo           # macOS Homebrew
```

### 2. Build the Network

```bash
python scripts/build_network.py
```

### 3. Run the Baseline

```bash
python scripts/run_baseline.py              # naive 45/45 timer
python scripts/run_baseline.py --tuned      # demand-proportional 60/30 timer
python scripts/run_baseline.py --gui        # with SUMO visual GUI
```

### 4. Train the AI

```bash
python scripts/train_agent.py --episodes 200
```

Training uses Apple Silicon MPS acceleration when available. Each episode runs a full 2-hour simulation (~2 min wall time).

### 5. Run the Trained AI

```bash
python scripts/run_ai.py                               # uses best_model.pth
python scripts/run_ai.py --model ai/best_model.pth      # specific checkpoint
```

### 6. Launch the 3D Visualiser

```bash
# Start the WebSocket server
python scripts/visualizer_server.py          # AI mode
python scripts/visualizer_server.py --demo   # random actions (no model needed)

# Then open visualizer/project.godot in Godot 4.2+ and press F5
```

---

## Achimota/Neoplan Junction

The simulation is calibrated to the real Achimota/Neoplan Junction on Accra's N6 Nsawam Road, part of Ghana's ATMC smart signal network.

```
            Nsawam / Achimota Forest Rd (N)
                   ↕↕ (2 lanes)
  Guggisberg (W)  ─⬛─  Aggrey St (E)
    (1 lane)       ↕↕    (2 lanes)
              CBD / South (S)
                (2 lanes)
```

| Approach | Road | Lanes | Speed | Demand |
|----------|------|-------|-------|--------|
| North | Achimota Forest Rd (from Nsawam) | 2 | 50 km/h | 900 veh/hr |
| South | Achimota Forest Rd (from CBD) | 2 | 50 km/h | 420 veh/hr |
| East | Aggrey Street | 2 | 50 km/h | 320 veh/hr |
| West | Guggisberg Street | 1 | 30 km/h | 300 veh/hr |

Total: ~2,270 vehicles/hour including trotro (minibus) flows.

---

## AI Agent

### State Vector (38 dimensions)

| Component | Dims | Description |
|-----------|------|-------------|
| Per-lane queue | 7 | Halted vehicles per incoming lane |
| Per-lane speed | 7 | Average speed per lane |
| Per-lane wait | 7 | Waiting time per lane |
| Approach queues | 4 | Total queue per approach (N/S/E/W) |
| Phase one-hot | 8 | Current signal phase encoding |
| Phase timer | 1 | Time in current phase (normalised) |
| Emergency flags | 4 | Ambulance presence per approach |

### Actions (7)

| Action | Effect |
|--------|--------|
| HOLD | Keep current phase |
| NS_THROUGH | N/S straight + right green, left blocked |
| NS_LEFT | N/S protected left turn |
| EW_THROUGH | E/W straight + right green, left blocked |
| EW_LEFT | E/W protected left turn |
| NS_ALL | N/S all movements green (unprotected) |
| EW_ALL | E/W all movements green (unprotected) |

### Signal Control

The agent uses `traci.trafficlight.setRedYellowGreenState()` with 15-character signal strings (one character per junction connection) for direct per-movement control.

### Emergency Preemption

A hard safety layer detects approaching ambulances and forces green on their approach, overriding the AI's decision. This reduces emergency wait from ~100s (baseline) to near 0s.

---

## Baseline Results (Achimota Network)

| Metric | Naive (45/45) |
|--------|--------------|
| Avg Wait Time | 81.83s |
| Vehicles Completed | 5,142 |
| Peak Queue | 66 |
| Throughput | 43.3 veh/min |
| Worst Approach (CBD) | 435.88s |
| Best Approach (Guggisberg) | 18.10s |

**AI Target:** < 49.10s average wait (40% reduction)

---

## Requirements

- Python 3.10+
- SUMO 1.18+ (with TraCI)
- PyTorch 2.0+
- Godot 4.2+ (Standard edition, for visualiser)
- macOS or Linux
