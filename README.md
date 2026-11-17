# TrafIQ — Traffic Intelligence & Coordination

Previously named ATCS-GH. The existing checkout folder can remain `ATCS-GH`;
the launcher resolves it relative to the app. Versioned TSH-1 schema IDs,
recorded experiment files and simulation inputs retain their original identifiers
to preserve compatibility and validation hashes. New dashboard launches use
`TRAFIQ_WS_PORT`; `ATCS_WS_PORT` remains a supported fallback.
Restart the simulator and dashboard together after updating to the new branding.

> **Traffic intelligence for Accra.** TrafIQ now focuses on the three-junction
> N6 corridor. Double-DQN agents and a supervisor control SUMO traffic; Godot
> renders the city independently. The launcher opens this corridor only.
> See [current control findings](docs/corridor-handoff-review-20261116.md) and
> the [traffic observation contract](docs/traffic-observation-contract.md).
>
> *Valiborn Tech. Build Beyond.*

---

## Historical results (greedy policy, full 2-hour scenarios, 5 seeds)

These retained results predate the current deployment audit. They are not a claim
that today's supervised corridor passes every case. The single-junction product
is retired; its results and checkpoints remain for reference.

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

**Transferability (measured, not assumed):** checkpoints are junction-specific.
A swap test (`scripts/transfer_swap_test.py`, raw rows in
`data/transfer_swap_test.csv`) drops each corridor brain onto the other
junctions with zero retraining: every swapped configuration gridlocks
(~1,000× worse than the fixed timer) — partly out-of-distribution inputs
(different lane layouts), partly corridor coupling (one failing junction
spills back and collapses its neighbours). What transfers is the **platform**
— the env/reward design, training methodology, and calibration pipeline retune
a model for a new junction in hours on a laptop (full corridor training:
~2 h), warm-starting from existing weights.

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
| Visualiser | Godot 4.6 (GDScript, procedural architecture) | 3D world, HUD, launcher, drone, audio |
| Dashboard | Flask + native SVG (live), Chart.js (archive) | Measured live telemetry at `http://127.0.0.1:5050`; historical reports at `/analytics` |

---

## Quick start

```bash
# 1. Install Python deps into a project-local virtualenv (Python 3.11 recommended;
#    SUMO comes with eclipse-sumo). The Godot launcher looks for .venv/ first.
python3.11 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt

# 2. Confirm the existing corridor network and routes are present in simulation/.
#    Preserve these calibrated inputs; do not regenerate them over an existing study.

# 3. Open visualizer/project.godot in Godot 4.6+ (Standard, NOT .NET) and press F5
#    → Launch corridor. It starts the traffic server and optionally opens
#    the live dashboard. Resume and session logs are available in the lobby.
```

Manual workflow (no launcher):

```bash
python scripts/corridor_visualizer_server.py   # corridor, AI control
python scripts/corridor_visualizer_server.py --route simulation/corridor_routes_evening.rou.xml
python dashboard/app.py                        # dashboard → http://127.0.0.1:5050
# for an externally managed server, run CorridorMain.tscn with F6,
# WebSocketClient.auto_start_server=false, and a matching server URL
```

In the 3D scene: drag the time-of-day slider (night = headlights, billboards,
runway lights), set weather, press **H** to fly the drone, **K** for sensor
sightlines.

### Training & evaluation

```bash
python scripts/train_corridor.py --output ai/checkpoints/corridor/my-run --seed 101 --episodes 18

python scripts/eval_corridor.py --compare         # official corridor eval
python scripts/validate_corridor_candidates.py --help  # current supervised evaluation tooling
```

Single-junction training uses Apple-Silicon MPS automatically. Corridor training
uses deterministic CPU runs, crossing clearance, boarding and the live supervisor;
it writes isolated, resumable model bundles and never installs a candidate.
See [the corridor deployment audit](docs/corridor-deployment-validation.md) for
matched evaluation, model/input contracts and the optional fast libsumo backend.
Baselines: `scripts/_per_scenario_baselines.py`
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

Procedural architecture, surface shaders and generated audio, with bundled vehicle models:

- **Detailed Accra streetscape** in both scenes: hipped metal roofs, balconies,
  shop shutters and signs, framed windows, compound gates, rooftop tanks,
  branching trees and palms, weathered road/plaster materials, and wet surfaces
  in rain. Perspective overview with **P** for plan view. See
  [`docs/streetscape.md`](docs/streetscape.md).
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
- **Camera drone**: press **H** — smooth assisted flight, three speed presets,
  building collisions, chase/gimbal views, lens zoom, compass and minimap.
  **Tab** hovers for dashboard access; flight position resumes across toggles.
- **Corridor overview panel**: per-approach queue bars, a green-wave strip,
  live *"Beating fixed timer by N%"* badge, phase timers, throughput.

See [`visualizer/README.md`](visualizer/README.md) for controls and protocol.

---

## Repository map

```
TrafIQ/
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


## Corridor control validation (November 2026)

The corridor deployment combines its trained DQN policies with live movement detectors, queue-pressure and starvation checks, downstream-capacity checks, and pedestrian clearance. Trotro boarding now uses off-road bays beyond the short inter-junction links. The live server and current evaluation share the same control runtime. See the [corridor control audit](docs/corridor-control-audit.md) for measured comparisons, limitations, and reproduction commands.

The redesigned live dashboard includes junction signals, measured approach queues, current vehicle waits, AI decision explanations, and CSV export. See [live dashboard data definitions and validation](docs/live-dashboard.md) for exact metric scopes and checks against SUMO.
