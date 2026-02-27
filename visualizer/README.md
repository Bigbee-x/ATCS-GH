# ATCS-GH 3D Visualizer

Real-time 3D visualization of the ATCS-GH adaptive traffic control system, powered by **Valiborn Technologies**.

Watch the DQN AI agent control a 4-way Accra-style intersection live in a Godot 4 3D environment.

## Architecture

```
 SUMO Simulation ←─TraCI─→ Python Server ←─WebSocket─→ Godot 4 Client
                          (port 8765)                  (3D Renderer)
```

The Python server runs the SUMO traffic simulation with the trained DQN agent and broadcasts real-time state over WebSocket. The Godot client renders the intersection, vehicles, traffic lights, and HUD.

## Prerequisites

| Component | Version | Installation |
|-----------|---------|-------------|
| **Python** | 3.10+ | [python.org](https://www.python.org/downloads/) |
| **SUMO** | 1.18+ | `pip install eclipse-sumo` or `brew install sumo` |
| **Godot** | 4.2+ (Standard) | [godotengine.org/download](https://godotengine.org/download/linux/) |
| **websockets** | 12.0+ | `pip install websockets` |

> **Note:** Download the **Standard** version of Godot 4, not the .NET version. GDScript only — no C# required.

## Quick Start

### Step 1: Install Python dependencies

```bash
pip install -r requirements.txt
```

### Step 2: Build the SUMO network (if not already done)

```bash
python scripts/build_network.py
```

### Step 3: Start the Python server

```bash
# AI mode (uses trained DQN model)
python scripts/visualizer_server.py

# Demo mode (random actions — no trained model needed)
python scripts/visualizer_server.py --demo

# Manual mode (control from Godot UI)
python scripts/visualizer_server.py --manual

# Fast mode (10x speed)
python scripts/visualizer_server.py --speed 10
```

### Step 4: Open the Godot project

1. Open **Godot 4.2+**
2. Click **Import** → navigate to `visualizer/project.godot`
3. Press **F5** (Play) to start the 3D visualizer
4. The Godot client automatically connects to the Python server

### One-Line Launch (Alternative)

```bash
./scripts/launch_visualizer.sh           # AI mode
./scripts/launch_visualizer.sh --demo    # Demo mode
```

## Controls

| Input | Action |
|-------|--------|
| **Mouse Scroll** | Zoom in/out |
| **Middle Mouse Drag** | Pan the camera |
| **R** | Reset camera to default position |
| **Override Buttons** | Force green on N/S/E/W (bottom bar) |

## Modes

### AI Mode (default)
The trained DQN agent makes all traffic light decisions. Emergency preemption is active — ambulances automatically get priority.

### Manual Mode (`--manual`)
No AI decisions. Use the override buttons in the Godot HUD to manually switch traffic lights. Useful for demos and testing.

### Demo Mode (`--demo`)
Random actions with a 70/30 keep/switch bias. No trained model needed — great for testing the visualizer without training first.

## HUD Layout

- **Top Bar**: Project name, simulation time, vehicles completed, average wait time, connection status
- **Right Panel**: Per-approach queue bars (color-coded green→yellow→red), AI decision indicator, reward display
- **Bottom Bar**: Mode indicator, manual override buttons
- **Emergency Banner**: Appears when an ambulance is detected, shows approach and vehicle ID

## WebSocket Protocol

The Python server broadcasts JSON packets every 5 simulation seconds:

```json
{
  "type": "state_update",
  "step": 720,
  "phase_name": "NS_GREEN",
  "queues": {"north": 8, "south": 12, "east": 3, "west": 15},
  "wait_times": {"north": 45.2, "south": 89.1, "east": 12.3, "west": 134.5},
  "emergency": {"active": true, "approach": "west", "vehicle_id": "ambulance_2"},
  "ai_decision": "SWITCH",
  "reward": -245.3
}
```

The Godot client can send manual override commands:

```json
{"action": "force_green", "approach": "north"}
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "DISCONNECTED" in Godot | Make sure the Python server is running first |
| "SUMO not found" | Set `SUMO_HOME` environment variable or install: `pip install eclipse-sumo` |
| "Model not found" | Use `--demo` mode, or train first: `python scripts/train_agent.py` |
| Godot can't import project | Ensure you're using Godot 4.2+ (Standard, not .NET) |
| Vehicles not showing | Check that the WebSocket shows "CONNECTED" in the top bar |

## Project Structure

```
visualizer/
├── project.godot           # Godot 4 project config
├── icon.svg                # Project icon
├── scenes/
│   └── Main.tscn           # Master scene (3D world + HUD)
├── scripts/
│   ├── Main.gd             # Orchestrator — wires everything together
│   ├── WebSocketClient.gd  # Connects to Python server
│   ├── Intersection.gd     # 3D road geometry + traffic lights
│   ├── VehicleManager.gd   # Vehicle pool rendering
│   └── UI.gd               # HUD overlay
├── assets/                 # (placeholder for future assets)
└── README.md               # This file
```

## Screenshots

*(Coming soon — run the visualizer and take screenshots!)*

---

*Built for the ATCS-GH project by Valiborn Technologies*
