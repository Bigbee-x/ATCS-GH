# ATCS-GH — Adaptive Traffic Control System Ghana

> **AI traffic signals for Accra.** Double-DQN agents control the
> Achimota/Neoplan Junction and a 3-junction stretch of the N6 Nsawam corridor
> in a calibrated SUMO microsimulation — cutting average waits by **40–98%**
> versus a realistic fixed-timer across every demand scenario, verified across
> seeds. Rendered live in a fully procedural Godot 4 3D world.
>
> *Valiborn Technologies — "Relax, it works."*

---

## Results (greedy policy, full 2-hour scenarios, 5 seeds)

The deployable models are evaluated frozen (ε = 0) against protected-left
fixed-timer baselines. **Mean ± std across 5 seeds — the AI beats the timer on
every scenario at every seed, including each scenario's worst seed.**
Reproduce with `python scripts/multi_seed_eval.py` (raw rows in
`data/multi_seed_eval.csv`).

### Single junction — Achimota/Neoplan (`ai/best_model.pth`)

| Scenario | AI wait (mean ± std) | Worst seed | Fixed timer | Improvement |
|---|---:|---:|---:|---:|
| continuous_day | 18.1 ± 0.9 s | 19.5 s | 47.6 s | **−62%** |
| morning_rush | 27.8 ± 2.3 s | 30.7 s | 186.7 s | **−85%** |
| evening_rush | 256.1 ± 16.7 s | 277.6 s | 427.4 s | **−40%** |
| weekend_market | 13.8 ± 0.5 s | 14.3 s | 885.8 s | **−98%** |
| off_peak | 8.4 ± 0.5 s | 9.1 s | 14.2 s | **−41%** |

### 3-junction corridor (`ai/checkpoints/corridor/best_J{0,1,2}.pth`)

| Scenario | AI wait (mean ± std) | Worst seed | Fixed timer | Improvement |
|---|---:|---:|---:|---:|
| corridor_morning | 13.0 ± 1.2 s | 14.4 s | 143.1 s | **−91%** |
| corridor_evening | 10.5 ± 0.5 s | 11.1 s | 134.8 s | **−92%** |
| corridor_offpeak | 3.4 ± 0.1 s | 3.4 s | 25.6 s | **−87%** |

Baselines are the recorded protected-left fixed-timer references
(`data/scenario_baselines.csv`, `data/corridor_baselines.csv`). All results are
**purely learned behaviour** — an earlier hard-coded ambulance-preemption
feature was removed so the numbers reflect only what the agents learned.

---

## What it is

- **SUMO microsimulation** of real Accra geometry: the Achimota/Neoplan
  Junction (GPS 5.6216 N, 0.2193 W) and a 3-junction corridor along Achimota
  Forest Road (J0 Achimota → J1 Asylum Down → J2 Nima/Tesano), with cars,
  trotros, and signal-respecting pedestrians.
- **Double-DQN control** (PyTorch): one agent per junction reads live per-lane
  queues/speeds/waits and picks the next signal phase every 5 s from a
  protected-left action set — `HOLD / NS_THROUGH / NS_LEFT / EW_THROUGH /
  EW_LEFT`. No all-green phases (permissive lefts deadlock the junction box).
- **Godot 4 visualiser**: a procedural 3D Accra — zoned township, billboards,
  airport, day/night + weather, traffic sounds, a free-fly camera drone — fed
  live over WebSocket, with an in-scene analytics panel and a Flask dashboard.

```
                               ┌─────────────────────────────────┐
                               │  Godot 4 visualiser (3D client) │
                               │  LauncherMenu → Single/Corridor │
                               └───────────────┬─────────────────┘
                                               │ WebSocket :8765
 SUMO microsim ◀──TraCI──▶ Python server ──────┤
 (intersection /           (visualizer_server.py /
  corridor.sumocfg)         corridor_visualizer_server.py)
                                               │
                               ┌───────────────▼─────────────────┐
                               │  Flask dashboard  :5050         │
                               └─────────────────────────────────┘
```

| Component | Technology | Role |
|---|---|---|
| Traffic simulation | SUMO + TraCI | Vehicles, pedestrians, signals (1 s steps) |
| AI agents | PyTorch Double-DQN | 41-dim state (single) / 46-dim per junction (corridor), 5 actions |
| Training | Python | Expert warm-start, ε-greedy, scenario rotation, maximin model selection |
| Bridge | Python asyncio websockets | Streams sim state to the 3D client every sim-second |
| Visualiser | Godot 4.6 (GDScript, all procedural) | 3D world, HUD, launcher, drone, audio |
| Dashboard | Flask + Chart.js | Live + historical metrics at `http://127.0.0.1:5050` |

---

## Quick start

```bash
# 1. Install Python deps (Python 3.11 recommended; SUMO comes with eclipse-sumo)
python -m pip install -r requirements.txt

# 2. Open visualizer/project.godot in Godot 4.6+ (Standard, NOT .NET) and press F5
#    → pick Single Junction or N6 Corridor in the launcher. It spawns the
#    Python server + dashboard and opens the dashboard in a browser for you.
```

Manual workflow (no launcher):

```bash
python scripts/visualizer_server.py            # single junction, AI control
python scripts/corridor_visualizer_server.py   # corridor, AI control
python scripts/corridor_visualizer_server.py --route simulation/corridor_routes_evening.rou.xml
python dashboard/app.py                        # dashboard → http://127.0.0.1:5050
# then open the Godot project and press F5
```

In the 3D scene: drag the time-of-day slider (night = headlights, billboards,
runway lights), set weather, press **H** to fly the drone, **K** for sensor
sightlines.

### Training & evaluation

```bash
python scripts/train_agent.py --episodes 200      # single junction
python scripts/train_corridor.py --episodes 240   # corridor (3 agents, rotation)

python scripts/_eval_best.py                      # official single-junction eval
python scripts/eval_corridor.py --compare         # official corridor eval
python scripts/multi_seed_eval.py                 # 5-seed robustness (both systems)
```

Training uses Apple-Silicon MPS automatically (~9 s per greedy 2-h episode,
~30 s per training episode). Baselines: `scripts/_per_scenario_baselines.py`
(protected-left timer preset, writes `data/scenario_baselines.csv`) and
`run_corridor_baseline.py --route … --label …` (writes
`data/corridor_baselines.csv`).

---

## The junctions

**Achimota/Neoplan (single junction):** 4 approaches × 2 lanes — Achimota
Forest Rd (N/S), Aggrey St (E), Guggisberg St (W). The junction is asymmetric:
northbound saturates before southbound, so morning (N-heavy, 1 901 veh/h) and
evening (S-heavy, 2 350 veh/h) stress it differently. Five demand scenarios:
`continuous_day` (a realistic 24-h profile with the N→S directional flip —
the training centerpiece), `morning_rush`, `evening_rush`, `weekend_market`
(E-heavy), `off_peak`. Heavy scenarios are calibrated to solvable demand so
the AI is graded against a fair target.

**N6 corridor:** J0/J1/J2 spaced 300 m apart. Each junction has its own
independent agent — a 46-dim state adds neighbour queue/phase/link occupancy,
and any green-wave that emerges is *learned* coordination (visible live in the
corridor overview's green-wave strip). Three calibrated scenarios rotate in
training: `corridor_morning` (S→N heavy), `corridor_evening` (the N→S flip),
`corridor_offpeak` (light, balanced) — built by
`scripts/build_corridor_scenarios.py`.

### Training methodology (what made the models robust)

1. **Bounded, clipped rewards** — queue/wait penalties normalised and clipped
   (±40) so saturated traffic can't produce a runaway "gridlock trap" signal.
2. **Expert warm-start** — during exploration, 70% of random actions follow a
   sustained-green heuristic so heavy scenarios keep flowing while ε decays.
3. **Scenario rotation** — one scenario per episode, round-robin; the single
   junction rotates 5, the corridor 3.
4. **Maximin best-model selection** — the saved checkpoint is the one whose
   *worst* scenario (single) / *worst junction* (corridor), measured as rolling
   wait relative to its own baseline, is best — gated to near-greedy ε ≤ 0.10
   so selection reflects deployment behaviour.

---

## The visualiser

Fully procedural (CSG + generated audio — zero external assets):

- **Zoned township** around the corridor: residential compounds, glass office
  towers, industrial yard, school + football pitch, hospital campus + GOIL
  filling station, market, and a KOTOKA-style airport with lit runway.
- **Brand billboards** (MTN, Telecel, GCB, Voltic, Guinness, Fan Ice, GOIL,
  Melcom + Valiborn) that glow at night.
- **Atmosphere**: day/night cycle, weather (rain/fog/overcast) with
  headlight behaviour, drifting clouds, street + utility poles, gutters.
- **Smooth traffic**: vehicle motion is snapshot-interpolated against the
  packets' sim-time (`SnapClock.gd`) — 60 fps motion from 1 Hz data, no
  stutter; launcher runs the sim at 1.5× for a lively pace.
- **Traffic soundscape**: per-vehicle engine audio (petrol + trotro diesel)
  that follows SUMO speeds with doppler, congestion-driven horns, and a
  moving-traffic wash — all synthesised at startup.
- **Camera drone**: press **H** — a DJI-style quadcopter with FPS controls
  and a chase camera. Fly-bys bend engine pitch.
- **Corridor overview panel**: per-approach queue bars, a green-wave strip,
  live *"Beating fixed timer by N%"* badge, phase timers, throughput.

See [`visualizer/README.md`](visualizer/README.md) for controls and protocol.

---

## Repository map

```
ATCS-GH/
├── ai/                     # envs + agent + deployable models
│   ├── traffic_env.py         # single junction (41-dim, 5 actions)
│   ├── corridor_env.py        # corridor (46-dim/junction, 5 actions)
│   ├── dqn_agent.py           # Double-DQN
│   ├── best_model.pth         # deployable single-junction model
│   └── checkpoints/corridor/best_J{0,1,2}.pth   # deployable corridor models
├── simulation/             # SUMO networks + demand
│   ├── intersection.*         # single-junction net/config
│   ├── corridor.*             # corridor net/config
│   ├── corridor_routes*.rou.xml   # corridor scenarios (morning/evening/offpeak)
│   └── scenarios/             # single-junction scenarios (5)
├── scripts/                # training / baselines / eval / servers / builders
├── visualizer/             # Godot 4 project (open + F5)
├── dashboard/              # Flask analytics (127.0.0.1:5050)
├── data/                   # baselines + eval CSVs (incl. multi_seed_eval.csv)
└── requirements.txt
```

Historical design docs: [`plan.md`](plan.md) (corridor plan — delivered),
[`docs/phase1_notes.md`](docs/phase1_notes.md). `CLAUDE.md` is the working
engineering brief and always reflects the current state.

---

## Requirements & notes

- **Python 3.11+**, deps via `requirements.txt` (`eclipse-sumo` bundles SUMO +
  TraCI — the envs bootstrap `SUMO_HOME` automatically).
- **PyTorch** uses MPS on Apple Silicon automatically (CUDA/CPU elsewhere).
- **Godot 4.6+ Standard** (not .NET) for the visualiser.
- macOS/Linux. The launcher auto-detects the Python interpreter; it opens the
  dashboard in Chrome/Brave/Edge/Firefox because Safari's HTTPS-Only mode
  refuses local HTTP servers.
