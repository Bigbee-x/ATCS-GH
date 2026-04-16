# ATCS-GH — Adaptive Traffic Control System Ghana

> **AI-powered smart traffic control for the Achimota/Neoplan Junction and the N6 Nsawam corridor, Accra**

---

## Overview

ATCS-GH uses **Double DQN reinforcement learning agents** to adaptively control traffic signals along a real stretch of the N6 Nsawam Road in Accra — starting at the Achimota/Neoplan Junction (GPS: 5.6216N, 0.2193W) and extending north through two additional junctions. The system replaces traditional fixed-timer signals with AI that observes real-time traffic, adjusts signal phases dynamically, prioritises emergency vehicles, and coordinates green-wave timing across the corridor.

The project includes a **real-time 3D visualiser** built in Godot 4 — fully procedural (no external assets, no plugins) — connected to the simulation via WebSocket, plus a **Flask web dashboard** showing live training and evaluation analytics.

| Phase | Status | Description |
|-------|--------|-------------|
| **Phase 1** | Done | Fixed-timer baseline, demand calibration, metrics pipeline |
| **Phase 2** | Done | Single-junction Double DQN — 81%+ wait-time improvement vs tuned baseline |
| **Phase 3** | Done | 3-junction N6 corridor with multi-agent DQN + green-wave coordination |
| **Phase 4** | Done | Full pedestrian modelling (SUMO crossings + ambient peds) and multi-scenario generalisation |
| **Phase 5** | Done | Production-grade 3D visualiser + live dashboard + one-click Godot launcher |
| **Phase 6** | Future | Field pilot with real-world signal controllers |

---

## Architecture

```
                                 ┌──────────────────────────────────┐
                                 │  Godot 4 Visualiser (3D client)  │
                                 │  LauncherMenu → Single / Corridor │
                                 └──────────────┬───────────────────┘
                                                │ WebSocket (port 8765)
                                                │
  SUMO Traffic Sim ◀──TraCI──▶ Python Server ──┤
  (intersection /              (visualizer_server.py
   corridor.sumocfg)            corridor_visualizer_server.py)
                                                │
                                                ▼
                                 ┌──────────────────────────────────┐
                                 │  Flask Dashboard (port 5050)      │
                                 │  Live training + scenario eval   │
                                 └──────────────────────────────────┘
```

| Component | Technology | Role |
|-----------|-----------|------|
| Traffic Simulation | SUMO + TraCI | Microsimulation of vehicles, pedestrians, and signals |
| AI Agent | PyTorch (Double DQN, per-junction) | Observes 45-dim (single) / 50-dim (corridor) state, 7 actions |
| Training Pipeline | Python | Epsilon-greedy, prioritized replay, target network, multi-scenario training |
| Action Sanitizer | Python | Alternates `NS_ALL`/`EW_ALL` between protected through/left phases |
| WebSocket Server | Python asyncio | Bridges sim to visualiser in real-time |
| 3D Visualiser | Godot 4 (GDScript) | Procedural 3D rendering with day/night cycle, buildings, pedestrians |
| Launcher | Godot autoload | One-click server + dashboard + browser spawn from Godot |
| Dashboard | Flask + Chart.js | Live training curves, per-scenario evaluation, live simulation feed |

---

## Project Structure

```
ATCS-GH/
├── simulation/                         # SUMO network files
│   ├── nodes.nod.xml / edges.edg.xml   # Single-junction nodes and edges
│   ├── routes.rou.xml                  # Demand (cars, trotros, ambulances, peds)
│   ├── intersection.net.xml            # Generated single-junction network
│   ├── intersection.sumocfg            # Single-junction config
│   ├── corridor_nodes.nod.xml          # 3-junction corridor nodes (J0/J1/J2)
│   ├── corridor_edges.edg.xml          # Corridor edges (including 1500m arms)
│   ├── corridor_routes.rou.xml         # Multi-junction routes + emergencies + peds
│   ├── corridor.net.xml                # Generated corridor network
│   ├── corridor.sumocfg                # Corridor config
│   └── scenarios/                      # Morning rush / evening / market / emergency / off-peak
│
├── ai/                                 # DQN agents and environments
│   ├── traffic_env.py                  # Single-junction env (45-dim state, 7 actions)
│   ├── corridor_env.py                 # Multi-junction env (50-dim per junction, 7 actions)
│   ├── dqn_agent.py                    # Double DQN with prioritized replay
│   ├── best_model.pth                  # Single-junction trained checkpoint
│   ├── best_model_v1_38dim.pth         # Legacy 38-dim checkpoint (pre-ped integration)
│   └── checkpoints/                    # Per-episode + per-junction training checkpoints
│
├── scripts/
│   ├── build_network.py                # Compile net.xml via netconvert (single + corridor)
│   ├── run_baseline.py                 # Phase 1 fixed-timer single-junction
│   ├── run_corridor_baseline.py        # Fixed-timer baseline for the 3-junction corridor
│   ├── train_agent.py                  # Phase 2 DQN training (single junction)
│   ├── train_corridor.py               # Phase 3 multi-agent DQN training
│   ├── run_ai.py                       # Run trained AI on a full scenario (single junction)
│   ├── eval_multi_seed.py              # Multi-seed confidence-interval eval (single)
│   ├── eval_scenarios.py               # Per-scenario evaluation with AI vs baseline
│   ├── eval_corridor.py                # Corridor multi-seed evaluation
│   ├── generate_scenarios.py           # Build scenario route files (5 demand patterns)
│   ├── visualizer_server.py            # WebSocket server — single junction
│   ├── corridor_visualizer_server.py   # WebSocket server — 3-junction corridor
│   ├── metrics_logger.py               # Shared CSV metrics output
│   └── launch_visualizer.sh            # Terminal one-liner (Godot launcher is preferred)
│
├── visualizer/                         # Godot 4 project (fully procedural)
│   ├── project.godot
│   ├── scenes/
│   │   ├── LauncherMenu.tscn           # Entry — pick Single Junction or Corridor
│   │   ├── Main.tscn                   # Single-junction 3D world + HUD
│   │   └── CorridorMain.tscn           # 3-junction corridor world + HUD
│   └── scripts/
│       ├── ServerManager.gd            # Autoload — spawns Python server + dashboard
│       ├── LauncherMenu.gd             # Sim-selection UI, one-click launch
│       ├── Main.gd / CorridorMain.gd   # Scene orchestrators
│       ├── Intersection.gd             # 3D roads + signals (incl. overhead lights + arrows)
│       ├── CorridorBuilder.gd          # Instantiates 3 junctions with corridor links
│       ├── VehicleManager.gd           # Pooled rendering + headlights/taillights/shadows
│       ├── PedestrianManager.gd        # Ambient + SUMO-integrated pedestrians
│       ├── EnvironmentBuilder.gd       # Procedural Accra buildings, shops, stalls, walls
│       ├── TimeOfDayManager.gd         # Day/night cycle (sun, sky, fog, ambient)
│       ├── UI.gd                       # HUD, queues, overrides, panels
│       ├── MetricsChart.gd             # In-game live charts
│       ├── AudioManager.gd             # Ambient city sounds + sirens
│       └── WebSocketClient.gd          # Server connection + reconnect
│
├── dashboard/                          # Flask analytics dashboard
│   ├── app.py                          # Routes: /, /live, /api/*
│   ├── templates/dashboard.html
│   └── static/                         # Chart.js, styles
│
├── data/                               # Generated CSV results
│   ├── training_log.csv                # Live training curve (dashboard pulls this)
│   ├── baseline_results.csv
│   ├── baseline_tuned_results.csv
│   ├── ai_results.csv
│   ├── ai_eval_seed*.csv               # Multi-seed AI evaluation
│   ├── {ai,bl}_<scenario>_seed*.csv    # Per-scenario AI + baseline results
│   └── scenario_eval_results.csv       # Aggregated scenario comparison
│
├── docs/phase1_notes.md                # Phase 1 baseline design log (historical)
├── plan.md                             # Phase 3 corridor plan (historical — delivered)
└── requirements.txt
```

---

## Quick Start

### Easiest — use the Godot launcher

The launcher runs **everything** for you (Python server, Flask dashboard, browser tab).

1. Install deps: `pip install -r requirements.txt`
2. Build the networks: `python scripts/build_network.py && python scripts/build_network.py --corridor`
3. Open `visualizer/project.godot` in **Godot 4.6+** (Standard edition)
4. Press **F5** — the Launcher menu appears
5. Click **Single Junction** or **N6 Corridor**. The launcher:
   - Kills any orphan Python server from a prior session (ports 8765 / 5050)
   - Spawns the correct `*_visualizer_server.py` as a background process
   - Starts the Flask dashboard and opens `http://localhost:5050?tab=live` in your browser
   - Connects the 3D scene via WebSocket

### Manual workflow (terminal)

```bash
# Single-junction AI
python scripts/visualizer_server.py          # AI mode
python scripts/visualizer_server.py --demo   # Random-action demo
python scripts/visualizer_server.py --manual # Control from Godot HUD

# Corridor
python scripts/corridor_visualizer_server.py

# Dashboard
python dashboard/app.py                      # http://localhost:5050

# Then open visualizer/project.godot in Godot and press F5
```

### Training

```bash
# Single junction
python scripts/train_agent.py --episodes 200

# Corridor (3 agents in parallel, shared SUMO sim)
python scripts/train_corridor.py --episodes 200
```

Apple Silicon MPS acceleration is used automatically. A single-junction episode is ~2 min wall-time at 1x; corridor episodes ~3 min.

### Evaluation

```bash
python scripts/eval_multi_seed.py              # Single junction, 5 seeds, CIs
python scripts/eval_scenarios.py               # AI vs baseline across all 5 scenarios
python scripts/eval_corridor.py --seeds 5      # Corridor multi-seed
```

---

## Achimota/Neoplan Junction (J0)

The single-junction sim is calibrated to the real Achimota/Neoplan Junction on Accra's N6 Nsawam Road, part of Ghana's ATMC smart signal network.

```
              Nsawam / Achimota Forest Rd (N)
                     ↕↕ (2 lanes)
  Guggisberg (W)  ─⬛─  Aggrey St (E)
    (2 lanes)      ↕↕    (2 lanes)
              CBD / South (S)
                 (2 lanes)
```

| Approach | Road | Lanes | Speed | Demand |
|----------|------|-------|-------|--------|
| North | Achimota Forest Rd (from Nsawam) | 2 | 50 km/h | 900 veh/hr |
| South | Achimota Forest Rd (from CBD) | 2 | 50 km/h | 420 veh/hr |
| East | Aggrey Street | 2 | 50 km/h | 320 veh/hr |
| West | Guggisberg Street | 2 | 50 km/h | 300 veh/hr |

Total: ~2,270 vehicles/hour + trotros + ambulances + pedestrians.

## N6 Corridor (J0 → J1 → J2)

Three traffic-light junctions spaced 300m apart along Achimota Forest Rd. Each has its own DQN agent with a **50-dim state** that includes neighbor queue length, neighbor phase, and upstream/downstream corridor link status. This enables **green-wave coordination** via a dedicated reward term — agents learn the ~22s ideal offset between adjacent junctions at 50 km/h.

- **J0** (Achimota/Neoplan): 2-lane E + 2-lane W cross streets
- **J1** (Asylum Down / Ring Rd): 2-lane symmetric cross streets
- **J2** (Nima / Tesano): 1-lane symmetric cross streets

Corridor arms extend **1500m** north and south of the endpoints for realistic approach dynamics.

---

## AI Agent

### State Vector

| Env | Dims | Composition |
|-----|-----|------|
| **Single** | 45 | 8 lanes × (queue + speed + wait) + 4 approach queues + 8 phase one-hot + 1 phase timer + 4 emergency flags + 4 pedestrian-wait |
| **Corridor** | 50/junction | 42-dim own state + 8 neighbor dims (upstream + downstream queue, phase, link speed) |

### Actions (7, shared across all environments)

| Action | Effect |
|--------|--------|
| HOLD | Keep current phase |
| NS_THROUGH | N/S straight + right green, left blocked |
| NS_LEFT | N/S protected left turn only |
| EW_THROUGH | E/W straight + right green, left blocked |
| EW_LEFT | E/W protected left turn only |
| NS_ALL | N/S all movements green (permissive left) |
| EW_ALL | E/W all movements green (permissive left) |

### ActionSanitizer (runtime wrapper)

`NS_ALL` and `EW_ALL` are permissive-left phases that force left-turners to yield to opposing through traffic, which doesn't match the fixed-timer baseline's protected-left cycle. The sanitizer **alternates** each time the AI picks an ALL-phase:

```
1st NS_ALL → NS_LEFT    (serve lefts first)
2nd NS_ALL → NS_THROUGH
3rd NS_ALL → NS_LEFT
...
```

This preserves the agent's directional intent while guaranteeing both movements eventually get served on a clean protected cycle. Existing 7-action checkpoints load unchanged. Corridor uses one sanitizer per junction (alternation state is independent across J0/J1/J2).

### Emergency Preemption

A hard safety layer detects approaching ambulances and forces green on their approach, overriding the AI's decision. Reduces emergency wait from ~100s (baseline) to near 0s.

### Pedestrian-Aware Policy

The state vector includes per-approach pedestrian wait times. The reward function penalises prolonged pedestrian waits, so the agent proactively serves crossings rather than starving them indefinitely.

---

## Results

### Single-junction Achimota (5-seed, 2-hour scenarios)

| Metric | Naive Baseline | Tuned Baseline | AI (Double DQN) | Improvement |
|--------|---------------:|---------------:|----------------:|-------------|
| Avg Wait Time | 81.83s | ~55s | **~10s** | **81%+ vs tuned** |
| Emergency Wait | ~100s | ~100s | **<5s** | hard-safety preempt |
| Throughput | 43.3 veh/min | ~46 veh/min | **~55 veh/min** | |

### Scenario Generalization (trained once, evaluated across 5 scenarios)

Morning rush, evening rush, off-peak, heavy-emergency, weekend-market. The AI beats the tuned baseline on every scenario — full breakdown available in the live dashboard.

### Corridor (3-junction, preliminary)

Multi-agent DQN learns coordinated green-wave timing. Per-junction and corridor-wide metrics are logged to `data/corridor_eval_*.csv` and rendered live in the dashboard.

---

## Visualiser Features

- **Launcher menu** with card-based selection of Single Junction or N6 Corridor
- **Automatic server + dashboard lifecycle** — no terminal juggling
- **Fully procedural 3D** — no external assets, everything is CSG / procedural meshes
- **Detailed vehicles** — cars, trotros, ambulances with windshields, cabin steps, undercarriage, headlights, taillights
- **Day/night cycle** — sun, sky gradient, ambient light, fog, keyframed across 24h (manual slider or sim-linked)
- **Accra streetscape** — block buildings, shop awnings, compound walls, market stall clusters, procedurally placed along every road arm
- **Pedestrians** — ambient sidewalk strollers + full SUMO-integrated crosswalk pedestrians that respect the signal
- **Overhead traffic lights** with mast-arm poles, separate protected-left arrow indicators, and emissive glow
- **HUD** — per-approach queue bars, AI decision readout, reward trace, emergency banner
- **Live in-game charts** for wait time, queue length, and throughput
- **Ambient audio** — city drone, sirens during emergency preemption

See [`visualizer/README.md`](visualizer/README.md) for controls, WebSocket protocol, and troubleshooting.

---

## Requirements

- Python 3.10+
- SUMO 1.18+ (with TraCI) — `pip install eclipse-sumo` or `brew install sumo`
- PyTorch 2.0+ (MPS on Apple Silicon, CUDA or CPU elsewhere)
- Flask (for the dashboard) — installed via `requirements.txt`
- **Godot 4.6+ (Standard edition)** for the visualiser — do **not** use the .NET version
- macOS or Linux (Windows untested)
