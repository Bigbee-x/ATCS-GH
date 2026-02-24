# ATCS-GH — Adaptive Traffic Control System Ghana

> **AI-powered smart traffic control for Accra, Ghana**
> Phase 1: Baseline fixed-timer simulation

---

## Overview

ATCS-GH models a typical busy Accra 4-way junction using [SUMO](https://sumo.dlr.de/) (Simulation of Urban MObility) and Python. The project is structured in phases:

| Phase | Status | Description |
|-------|--------|-------------|
| **Phase 1** | ✅ Complete | Fixed-timer baseline — mirrors current Accra lights |
| **Phase 2** | 🔜 Next | RL agent replaces fixed timer with adaptive control |
| **Phase 3** | 🔜 Future | Multi-intersection network, pedestrians, field testing |

### Why Accra?

Accra's intersections run on simple fixed-timer lights that ignore real-time traffic. During morning rush, this causes severe congestion on N-S arterials. ATCS-GH targets a **40% reduction in average vehicle wait time** using reinforcement learning.

---

## Project Structure

```
ATCS-GH/
├── simulation/                 # SUMO network and demand files
│   ├── nodes.nod.xml           # Junction nodes (input for netconvert)
│   ├── edges.edg.xml           # Road edges    (input for netconvert)
│   ├── routes.rou.xml          # Vehicle demand + emergency vehicles
│   ├── intersection.sumocfg    # SUMO run configuration
│   └── intersection.net.xml    # ⚠ GENERATED — run build_network.py first
│
├── scripts/
│   ├── build_network.py        # Step 1: compile net.xml from nod + edg files
│   ├── run_baseline.py         # Step 2: run Phase 1 simulation via TraCI
│   └── metrics_logger.py       # Reusable metrics class (Phase 1 & 2 share this)
│
├── data/
│   └── baseline_results.csv    # ⚠ GENERATED — simulation output
│
├── ai/                         # Phase 2: RL controller (coming soon)
├── docs/                       # Notes, research, design decisions
└── requirements.txt
```

---

## Quick Start

### 1. Install SUMO

**macOS — Homebrew (recommended):**
```bash
brew install sumo
```

Add to `~/.zshrc`:
```bash
export SUMO_HOME=/opt/homebrew/share/sumo
export PATH=$SUMO_HOME/bin:$PATH
```

Reload:
```bash
source ~/.zshrc
```

Verify:
```bash
sumo --version
netconvert --version
```

> **Apple Silicon (M1/M2/M3)?** The path above is correct for Homebrew on Apple Silicon.
> **Intel Mac?** Use `/usr/local/share/sumo` instead.

---

### 2. Install Python Dependencies

```bash
pip install -r requirements.txt
```

---

### 3. Build the Road Network

```bash
python scripts/build_network.py
```

This runs `netconvert` to compile `nodes.nod.xml` + `edges.edg.xml` into `simulation/intersection.net.xml`.

Expected output:
```
[OK] SUMO home  : /opt/homebrew/share/sumo
[OK] netconvert : /opt/homebrew/bin/netconvert
[OK] Input files : .../simulation
[RUN] netconvert ...
[OK] Network built → .../simulation/intersection.net.xml
```

---

### 4. Run the Baseline Simulation

```bash
# Headless — fast, recommended for data collection
python scripts/run_baseline.py

# With SUMO-GUI — watch the simulation visually
python scripts/run_baseline.py --gui
```

The simulation runs 7,200 steps (2 hours). Expect it to finish in **2–5 minutes** in headless mode.

---

## What the Simulation Models

### Intersection Design

A 4-way junction modelled on a typical Accra arterial crossing (e.g. Ring Road / Starlet Road style):

```
              NORTH (heavy inbound)
                ↕↕
   WEST (light) ⬛ EAST (moderate)
                ↕↕
              SOUTH (counter-flow)
```

| Arm   | Lanes | Speed    | Notes                    |
|-------|-------|----------|--------------------------|
| North | 2     | 50 km/h  | Main arterial, CBD-bound |
| South | 2     | 50 km/h  | Counter-flow             |
| East  | 1     | 40 km/h  | Side street              |
| West  | 1     | 40 km/h  | Side street              |

### Traffic Demand (07:00–09:00 Morning Rush)

| Route       | Volume    | Vehicle Mix       |
|-------------|-----------|-------------------|
| North → South | ~900/hr | 90% car, 10% trotro |
| South → North | ~300/hr | 90% car, 10% trotro |
| West → North  | ~310/hr | cars               |
| East → West   | ~270/hr | cars               |
| (turn movements) | 90–200/hr | cars         |

Total: ~3,200 vehicles/hour across all movements.

### Fixed Timer (Baseline)

```
NS GREEN  ████████████████████████████████████████████████  45s
NS YELLOW ███  3s
EW GREEN  ████████████████████████████████████████████████  45s
EW YELLOW ███  3s
                                              Cycle: 96s
```

This is the **dumb timer** ATCS-GH is designed to replace.

### Emergency Vehicle Scenarios

Three ambulances enter the simulation at pre-calculated times to test
how long the fixed timer makes emergency vehicles wait at red lights.

| Vehicle     | Route         | Expected Wait |
|-------------|---------------|---------------|
| ambulance_1 | North → South | ~26 seconds   |
| ambulance_2 | West → North  | varies        |
| ambulance_3 | South → North | varies        |

In Phase 2, the AI will preempt the signal immediately.

---

## Output

### CSV: `data/baseline_results.csv`

One row per simulation second. Columns include:

| Column | Description |
|--------|-------------|
| `time_s` | Simulation time (seconds) |
| `tl_phase` | Traffic light phase name |
| `avg_wait_time_s` | Average waiting time across all incoming lanes |
| `total_queue_vehicles` | Total halted vehicles at intersection |
| `throughput_veh_per_min` | Vehicles completing journeys per minute |
| `completed_vehicles` | Cumulative total arrivals |
| `emergency_vehicles_waiting` | Stopped emergency vehicles this step |
| `N2J_0_wait_s` … | Per-lane wait times |
| `N2J_0_queue` … | Per-lane queue lengths |

### Terminal Report

At the end of the simulation, a formatted report is printed showing overall performance and a **Phase 2 target** (40% wait-time reduction goal).

---

## Phase 2 Preview

The AI controller will live in `ai/`. The minimal change from Phase 1:

```python
# Phase 1 (fixed timer — passive):
configure_fixed_timer(TL_ID)       # set once and leave it
# ... step loop with metrics ...

# Phase 2 (AI — active each step):
action = agent.choose_action(state)          # RL agent decides
traci.trafficlight.setPhase(TL_ID, action)   # apply decision
# ... same MetricsLogger, same CSV format ...
```

The `MetricsLogger` class is shared — Phase 1 and Phase 2 produce identically structured CSVs for direct comparison.

---

## Requirements

- Python 3.10+
- SUMO 1.14+ (with `netconvert` and TraCI)
- macOS or Linux
