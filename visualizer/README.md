# ATCS-GH 3D Visualizer

Real-time 3D visualisation of the ATCS-GH adaptive traffic control system, powered by **Valiborn Technologies**.

Watch a Double DQN AI agent control the **Achimota/Neoplan Junction** (N6 Nsawam Road, Accra), or an entire **3-junction corridor**, live in a Godot 4 3D environment — detailed procedural architecture, weathered materials, and a shared vehicle fleet with working trotro pickups.

## Realistic Accra streetscape

Both scenes now use a shared architectural kit with hipped metal roofs,
verandas and balconies, framed windows and security bars, shop shutters,
local shop signs, rooftop water tanks, air conditioners, and compound gates.
Bundled photographed textures add asphalt, plaster and dry-ground detail;
paving and roofs use procedural seams, corrugation and weathering. Surrounding
neighbourhood blocks fill the horizon. Branching
broadleaf trees, palms, soft clouds, subtle atmospheric haze, and wet road
materials replace the original flat surfaces and geometric tree canopies.

Main-road plots now contain supermarkets, malls, mechanic workshops, police
stations, shops and kiosks. Homes sit inside the neighbourhoods behind this
commercial frontage. Additional 8–12-storey offices and apartment blocks have
balconies or sunshades, paved entrances and rooftop details. Full plot checks
keep buildings clear of each other, access streets, signs and trotro stations.

The corridor airport now has a curved-roof glass terminal, boarding bridges,
two detailed airliners, a control tower, hangar, baggage carts and tugs, parking,
and an access road. A separate taxiway serves the marked runway and apron;
airfield and apron lights turn on at night and in heavy rain. This is a
compressed Accra-inspired precinct, not a surveyed airport replica.

The four weather settings now share continuous cloud layers and wind. Rain
slants with gusts, follows the active camera, stops at rooftops, and leaves
reflective puddles with ripples that dry gradually. Harmattan brings warm dust
haze; overcast brings a continuous cloud deck. Foliage and the airport windsock
respond to the same wind. Rain ambience accompanies the existing thunder.

The overview starts in perspective. Press **P** to switch to the orthographic
plan view; normal orbit, pan, reset, and zoom controls work in both modes.
Use **V** in the single-junction scene to walk the streets, or **H** to fly
the drone in either scene. The existing time and weather controls still work.

See [Streetscape implementation and validation](../docs/streetscape.md) for
source locations, offline previews, and the scene checks.

## Live traffic startup

Use **F5** and choose Single Junction or N6 Corridor. Direct scene play with
**F6** also starts the matching traffic backend. Startup waits for real SUMO
state data before the launcher opens the scene. If startup fails, the launcher
keeps the error and server log visible instead of opening an empty town.

Port 8765 is preferred. If another application occupies it, the launcher
selects a free local port and passes it to both the scene and dashboard;
other applications are not stopped. The scene's connection indicator should
read **CONNECTED** before traffic appears. For a manually managed server on
the default endpoint, disable `WebSocketClient.auto_start_server` in the scene;
custom non-default server URLs are also supported. Offline art previews set
`auto_connect = false` and intentionally contain no SUMO traffic.

For an end-to-end check with actual SUMO vehicles and changing signal bulbs:

```sh
godot --headless --path visualizer --script res://tools/validate_live_traffic.gd
```

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

The launcher selects a free traffic port, starts the correct WebSocket server, opens the Flask dashboard when port 5050 is available, and connects the 3D client. Applications already using those ports remain running.

1. Open **Godot 4.6+** → Import → `visualizer/project.godot`
2. Press **F5**
3. Pick a simulation card:
   - **Single Junction** — Achimota/Neoplan (J0 only)
   - **N6 Corridor** — 3 junctions (J0, J1, J2) with green-wave coordination
4. Wait a moment — the server boots, the dashboard opens in your browser, the 3D scene loads

### What the launcher does behind the scenes

| Step | What happens | File |
|------|--------------|------|
| 1 | Select a free traffic port starting at 8765; preserve existing port owners | `ServerManager.gd` |
| 2 | Spawn `visualizer_server.py` or `corridor_visualizer_server.py` | `ServerManager.gd` |
| 3 | Start `dashboard/app.py` (Flask) if port 5050 is available | `ServerManager.gd` |
| 4 | Open `http://127.0.0.1:5050?tab=live` in an available Chromium/Firefox browser, falling back to the default | `ServerManager.gd` |
| 5 | Load the correct scene and connect via WebSocket | `Main.gd` / `CorridorMain.gd` |
| 6 | Clean shutdown: stop only the traffic and dashboard processes started by this launcher | `ServerManager.gd` |

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

### Drone navigation

Press **H** in either scene. Flight accelerates smoothly, settles into a hover
when movement keys are released, and slides along building collisions. The
chase camera retracts near walls; **F** switches to an unobstructed stabilised
gimbal view. The compass, minimap and instruments help you keep your bearings.
The quadcopter has a sculpted pearl-grey shell, detailed folding-arm hinges,
vented motors, swept two-blade propellers, stereo sensors, landing feet and a
suspended camera gimbal that counteracts body tilt.

| While flying | Action |
| --- | --- |
| **Mouse / Arrow Keys** | Look and turn |
| **WASD** | Fly horizontally |
| **Space / Ctrl or C** | Ascend / descend |
| **1 / 2 / 3** | Inspect / Cruise / Fast speed |
| **Shift** | Temporary speed boost |
| **X** | Brake immediately |
| **F** | Chase / stabilised gimbal camera |
| **Wheel / trackpad pinch** | Lens zoom |
| **R** | Reset to the safe launch point |
| **Tab** | Hover and release the cursor for dashboard controls; press again to fly |
| **K** | Toggle sensor coverage and the cable runs to the signal cabinet |
| **H / Esc** | Exit and restore the overview |

The drone remembers its position, view and speed between toggles until the
scene reloads. Losing window focus engages hover and releases the cursor;
press **Tab** to resume. Simulation traffic keeps running while you use the
dashboard. Height and speed use the scene's compressed world units (`u`).
Rain follows the active camera at its current altitude.

## Modes

### AI Mode (default)
Trained Double-DQN agents select from HOLD and four protected through/left phases. The environment enforces phase transitions; the visual rebuild changes presentation only.

### Baseline Mode (`--baseline`)
Fixed-timer cycle matching the real Achimota ATMC signal plan. Used for side-by-side visual comparison with the AI.

### Manual Mode (`--manual`)
No AI — use the override buttons in the HUD to switch lights manually. Handy for demos.

### Demo Mode (`--demo`)
Random actions (60% HOLD, 40% random protected phase). No trained model required — good for testing the visualiser without training first.

## 3D Scene Features

- **Detailed vehicles** — curved car bodies, fitted glass, mirrors, wheel arches, alloy wheels, multiple paint colours and taxi trim. Wheels rotate with travel and front wheels steer into turns. Headlights and brake lights respond to conditions; ambulances retain flashing light bars.
- **Trotros and stations** — dedicated minibuses with destination boards, stripes, roof racks and sliding doors; two stations per scene with shelters, benches, route desks, waiting passengers and loading bays. Existing SUMO trotros stop, board actual passengers and depart after a dwell. Use `--no-transit` on either Python visualizer server to disable this service; training and benchmark routes are unchanged.
- **Day/night cycle** — interpolated keyframes for sun energy, sun colour, sun pitch, sky gradient, ambient light, and fog across 24 hours. Building windows, vehicle headlights, station lighting and street lamps respond to the time of day.
- **Accra streetscape** — commercial main-road frontage with supermarkets, malls, open mechanic bays, police stations, shops and kiosks. Houses occupy interior compounds; taller offices and apartments form the skyline. Building plots preserve neighbourhood access, station bays and billboard space. Placement is deterministic.
- **Pedestrians** — ambient sidewalk strollers + SUMO-integrated crosswalk pedestrians that obey the walk signal.
- **Natural walking** — varied procedural characters with cloth shading, bending knees, planted feet, counter-swinging arms and idle motion. Walkers ease into stops and turns, keep following distances and pass in separate sidewalk lanes.
- **Traffic lights and sensors** — galvanized mast arms, braces, bolted bases, hooded LED lenses, protected-left arrows and three-aspect roadside repeaters, plus a far-side through head and left arrow for every approach, and two pedestrian heads on each corner pole (WALK on green, a flashing hand while people are still crossing, steady hand otherwise). A TSH-1 sensor head rides each mast arm; its cable drops down the pole to a pull box and under the road to the junction's one signal cabinet (NEMA TS2 with a side battery backup and roof antenna). **K** toggles sensor coverage and the cable runs.
- **Signs and billboards** — fitted shop fascia signs, roadside direction boards and printed advertising on reserved plots away from crossings, with floodlights after dusk. Two billboards in the single-junction scene; three in the corridor.
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
| Sim keeps connecting/reconnecting | Check the Godot output for the WebSocket close code. Code **1009, "Message too big"** occurred when dense traffic exceeded the old 64 KiB receive buffer. The client and startup probe now use a **16 MiB** receive buffer; stop and restart the running viewer to load the fix. If the issue persists, inspect the Launcher Log panel or `/tmp/atcs_gh_server.log`. |
| No live traffic / connection pending | Check the Launcher Log panel or `/tmp/atcs_gh_server.log` for startup errors. The launcher selects a free traffic port starting at **8765** and preserves other applications using those ports. For an externally started server, ensure the client URL matches its port. |
| "SUMO not found" in server log | Set `SUMO_HOME` or install: `pip install eclipse-sumo` |
| "Model not found" | Use `--demo` mode, or train first: `python scripts/train_agent.py` |
| Dashboard doesn't open | Check `/tmp/atcs_gh_dashboard.log` and the Godot output. If port **5050** is occupied, the launcher skips opening its dashboard and leaves the existing application running; traffic simulation continues. Close that application yourself only if you want to free the dashboard port. |
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
