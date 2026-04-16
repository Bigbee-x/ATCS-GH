# ATCS-GH 3D Visualizer

Real-time 3D visualisation of the ATCS-GH adaptive traffic control system, powered by **Valiborn Technologies**.

Watch a Double DQN AI agent control the **Achimota/Neoplan Junction** (N6 Nsawam Road, Accra), or an entire **3-junction corridor**, live in a Godot 4 3D environment — fully procedural geometry, no external assets, no plugins.

## Architecture

```
SUMO Simulation ←─TraCI─→ Python Server ←─WebSocket─→ Godot 4 Client ─┐
                         (port 8765)                  (3D Renderer)  │
                              │                                       │
                              ▼                                       │
                     Flask Dashboard ◀──HTTP (port 5050)──────────────┘
                     (live training + scenario analytics)
```

The Python server runs the SUMO traffic simulation with the trained DQN agent(s) and broadcasts real-time state over WebSocket. The Godot client renders roads, buildings, vehicles, pedestrians, traffic lights, and HUD. The Flask dashboard runs alongside, pulling from the same CSVs, and is auto-opened in the browser by the launcher.

## Prerequisites

| Component | Version | Installation |
|-----------|---------|--------------|
| **Python** | 3.10+ | [python.org](https://www.python.org/downloads/) |
| **SUMO** | 1.18+ | `pip install eclipse-sumo` or `brew install sumo` |
| **Godot** | **4.6+ (Standard)** | [godotengine.org/download](https://godotengine.org/download/) |
| **Python deps** | see `requirements.txt` | `pip install -r requirements.txt` |

> **Note:** Download the **Standard** version of Godot 4, not the .NET version. GDScript only — no C# required.

## Quick Start — Godot Launcher (recommended)

The launcher handles everything: killing orphan Python processes on ports 8765/5050, starting the correct WebSocket server, spawning the Flask dashboard, opening a browser tab, and connecting the 3D client.

1. Open **Godot 4.6+** → Import → `visualizer/project.godot`
2. Press **F5**
3. Pick a simulation card:
   - **Single Junction** — Achimota/Neoplan (J0 only)
   - **N6 Corridor** — 3 junctions (J0, J1, J2) with green-wave coordination
4. Wait a moment — the server boots, the dashboard opens in your browser, the 3D scene loads

### What the launcher does behind the scenes

| Step | What happens | File |
|------|--------------|------|
| 1 | Kill any orphan server on ports 8765/5050 (`lsof -ti`) | `ServerManager.gd` |
| 2 | Spawn `visualizer_server.py` or `corridor_visualizer_server.py` | `ServerManager.gd` |
| 3 | Start `dashboard/app.py` (Flask) as background process | `ServerManager.gd` |
| 4 | Open `http://localhost:5050?tab=live` in default browser | `ServerManager.gd` |
| 5 | Load the correct scene and connect via WebSocket | `Main.gd` / `CorridorMain.gd` |
| 6 | Clean shutdown: kill both processes when Godot exits | `ServerManager.gd` |

## Manual Workflow (terminal)

If you prefer running the Python side by hand:

```bash
# Single-junction AI
python scripts/visualizer_server.py               # AI mode
python scripts/visualizer_server.py --demo        # Random actions (no trained model)
python scripts/visualizer_server.py --manual      # Control from Godot HUD
python scripts/visualizer_server.py --speed 10    # 10× faster simulation

# 3-junction corridor
python scripts/corridor_visualizer_server.py

# Dashboard (optional)
python dashboard/app.py                           # http://localhost:5050
```

Then open `visualizer/project.godot` in Godot and press **F5** — skip the launcher by setting the main scene to `Main.tscn` or `CorridorMain.tscn` directly.

## Controls

| Input | Action |
|-------|--------|
| **Mouse Scroll** | Zoom in/out |
| **Middle Mouse Drag** | Orbit the camera |
| **Right Mouse Drag** | Pan the camera |
| **R / Home** | Reset camera to default isometric view |
| **Arrow Keys / WASD** | Nudge camera |
| **Time-of-Day Slider** | Manually set sun position (in HUD top-left) |
| **Time Mode Toggle** | Switch between Manual / Auto-Cycle / Sim-Linked day-night |
| **Override Buttons** | Force green on N/S/E/W (bottom bar — single junction) |
| **Junction Selector** | Switch focus between J0/J1/J2 (corridor mode) |

## Modes

### AI Mode (default)
Trained DQN agent(s) decide every signal change. `NS_ALL` / `EW_ALL` picks are alternated between protected through/left phases by the runtime `ActionSanitizer` — see the main [README](../README.md) for the rationale. Emergency preemption is active.

### Baseline Mode (`--baseline`)
Fixed-timer cycle matching the real Achimota ATMC signal plan. Used for side-by-side visual comparison with the AI.

### Manual Mode (`--manual`)
No AI — use the override buttons in the HUD to switch lights manually. Handy for demos.

### Demo Mode (`--demo`)
Random actions (60% HOLD, 40% random protected phase). No trained model required — good for testing the visualiser without training first.

## 3D Scene Features

- **Detailed vehicles** — cars (4-part: body + cabin step + windshield + undercarriage), trotros (with roof rack), ambulances with light bars. All have **headlights + taillights** that turn on at night.
- **Day/night cycle** — interpolated keyframes for sun energy, sun colour, sun pitch, sky gradient, ambient light, and fog across 24 hours. Traffic lights and vehicle windshields glow brighter at night.
- **Accra streetscape** — procedural buildings behind sidewalks on every arm: block buildings (ochre/terracotta/cream palette), shops with coloured awnings, compound walls, market stall clusters. Seeded RNG so placement is deterministic.
- **Pedestrians** — ambient sidewalk strollers + SUMO-integrated crosswalk pedestrians that obey the walk signal.
- **Overhead traffic lights** — mast-arm poles with dedicated protected-left arrow heads, emissive glow, and OmniLight3D illumination that intensifies at night.
- **Street lights** — line both sides of every arm, glow after sundown.
- **Ambient city audio** — drone soundscape + directional ambulance sirens during emergency preemption.

## HUD Layout

- **Top bar**: project name, simulation time, vehicles completed, current avg wait, connection status, time-of-day slider
- **Right panel** (per-junction in corridor mode): queue bars, phase readout, AI action, reward, pedestrian wait, live mini-charts
- **Bottom bar**: mode indicator, manual override buttons (N/S/E/W), emergency banner
- **Emergency banner**: flashes when an ambulance is detected and preemption is active

## WebSocket Protocol

### Single junction packet (every ~500ms sim time)
```json
{
  "type": "state_update",
  "step": 720,
  "phase_name": "NS_ALL",
  "queues":     {"north": 8,  "south": 12,  "east": 3,  "west": 15},
  "wait_times": {"north": 45.2, "south": 89.1, "east": 12.3, "west": 134.5},
  "ped_waits":  {"north": 5.0,  "south": 0.0,  "east": 22.1, "west": 0.0},
  "emergency":  {"active": true, "approach": "west", "vehicle_id": "ambulance_2"},
  "ai_decision": "NS_ALL",
  "reward": -45.3,
  "vehicles":    [ /* id, type, x, y, heading, lights_on */ ],
  "pedestrians": [ /* id, x, y, angle, crossing_bool */ ]
}
```

### Corridor packet
```json
{
  "type": "state_update",
  "step": 720,
  "junctions": {
    "J0": { "phase_name": "...", "queues": {...}, "ai_decision": "...", "reward": -... },
    "J1": { ... },
    "J2": { ... }
  },
  "corridor_metrics": {
    "total_throughput": 123,
    "green_wave_score": 0.85,
    "avg_corridor_travel_time": 45.2
  },
  "vehicles": [...],
  "pedestrians": [...]
}
```

### Godot → Python commands
```json
{"action": "force_green", "approach": "north"}        // Single junction
{"action": "force_green", "junction": "J1", "approach": "east"}   // Corridor
{"action": "set_mode", "mode": "baseline"}
```

## Troubleshooting

| Problem | Cause / Fix |
|---------|-------------|
| Sim keeps connecting/reconnecting | An orphan Python server from a previous Godot session was holding port 8765. The launcher now auto-cleans these — if it still happens, check `/tmp/atcs_gh_server.log` for EADDRINUSE and run `lsof -ti :8765 \| xargs kill -9` once. |
| "DISCONNECTED" in top bar | Python server didn't start. Check the Log panel (Launcher → Log button) or `/tmp/atcs_gh_server.log`. |
| "SUMO not found" in server log | Set `SUMO_HOME` or install: `pip install eclipse-sumo` |
| "Model not found" | Use `--demo` mode, or train first: `python scripts/train_agent.py` |
| Dashboard doesn't open | Check `/tmp/atcs_gh_dashboard.log`. Port 5050 may be held by another Flask process — launcher cleans this, but if stuck: `lsof -ti :5050 \| xargs kill -9`. |
| Godot can't import project | Ensure you're using Godot **4.6+ (Standard, not .NET)**. |
| Vehicles invisible / scene black | Press **R** to reset the camera — it may have drifted out of view. |
| Traffic lights not updating | Usually a runtime type error in `Intersection.gd`. Check the Errors panel in the Godot debugger. |

## Project Structure

```
visualizer/
├── project.godot                   # Godot 4 project config (main scene: LauncherMenu.tscn)
├── icon.svg
├── scenes/
│   ├── LauncherMenu.tscn           # Entry scene — sim-selection cards + log panel
│   ├── Main.tscn                   # Single-junction 3D world
│   └── CorridorMain.tscn           # 3-junction corridor 3D world
├── scripts/
│   ├── ServerManager.gd            # Autoload — Python server + dashboard lifecycle
│   ├── LauncherMenu.gd             # Launcher UI and server-log viewer
│   ├── Main.gd / CorridorMain.gd   # Scene orchestrators — wire everything together
│   ├── WebSocketClient.gd          # Connects to Python server, parses packets
│   ├── Intersection.gd             # 3D roads + signals (overhead + arrows), sidewalks
│   ├── CorridorBuilder.gd          # Builds 3 Intersection instances + connecting roads
│   ├── VehicleManager.gd           # Pooled vehicles with headlights/taillights
│   ├── PedestrianManager.gd        # Ambient strollers + SUMO crosswalk peds
│   ├── EnvironmentBuilder.gd       # Procedural Accra buildings, shops, stalls, walls
│   ├── TimeOfDayManager.gd         # Day/night cycle (sun, sky, ambient, fog)
│   ├── UI.gd                       # HUD — queue bars, panels, overrides
│   ├── MetricsChart.gd             # In-game live chart rendering
│   ├── AudioManager.gd             # Ambient city sounds + emergency sirens
│   └── *.uid                       # Godot-generated, committed for stable refs
└── README.md                       # This file
```

## Screenshots

The launcher menu, single-junction sim at noon, corridor view, and night-time scene with street lights / headlights are all worth capturing. Contributions welcome — add under `docs/screenshots/`.

---

*Built for the ATCS-GH project by Valiborn Technologies.*
