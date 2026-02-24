# Phase 1 Design Notes

## Goals

Establish a reproducible baseline for a fixed-timer Accra junction so that
Phase 2's AI controller has a concrete benchmark to beat.

---

## Intersection Model

### Why a single 4-way junction?

Single-intersection models are standard in traffic RL research as a clean
testbed. The AI learns a single-agent policy before we scale to a network
in Phase 3.

### Road Dimensions

- 500m per arm → ~1 typical urban block in central Accra
- 2-lane N/S main road, 1-lane E/W side street → asymmetric demand pattern
- Speed limits: 50 km/h (main), 40 km/h (side)

### Vehicle Types

| Type | Model | Length | Notes |
|------|-------|--------|-------|
| car | Toyota Corolla / Kia Rio | 4.5m | dominant vehicle type in Accra |
| trotro | Shared minibus | 7.0m | very common, slower acceleration |
| emergency | Ambulance | 5.5m | scenario test for Phase 2 |

---

## Traffic Demand Calibration

Volumes are estimated from Accra traffic pattern knowledge:
- N→S ~900 veh/hr: inbound CBD commuters on main arterial
- Counter-flow is lighter (people leaving CBD at 7am is low)
- W→N ~310 veh/hr: residential estates west of centre feeding north road
- E/W cross-street is moderate (~270/hr) but lower than main corridor

Total: ~3,200 vehicles/hour across all movements.
For comparison, a well-functioning 2-lane urban junction in West Africa
can handle ~1,200–1,800 vehicles/hour per direction before saturation.
Our N-S corridor at ~1,200/hr (both directions) is approaching saturation,
which is exactly the interesting regime for testing adaptive control.

---

## Fixed Timer Design

Accra's current signals are typically 45–60s green per phase.
We use 45s/3s (45s NS green → 3s yellow → 45s EW green → 3s yellow)
= 96s cycle time.

This is **deliberately suboptimal for asymmetric demand**: the E/W side
street gets the same 45s green as the much busier N/S main road,
wasting green time while the N/S queue builds.

This inefficiency is exactly what the Phase 2 RL agent will exploit.

---

## Emergency Vehicle Timing

Ambulance 1 timing calculation:
```
Cycle length = 96s  (45 + 3 + 45 + 3)
Phase 0 (NS_GREEN):  offsets 0–44
Phase 1 (NS_YELLOW): offsets 45–47
Phase 2 (EW_GREEN):  offsets 48–92   ← NS is RED
Phase 3 (EW_YELLOW): offsets 93–95

Ambulance departs North at t=130s
Travel time: 500m ÷ 13.89 m/s ≈ 36s
Arrives at junction: t ≈ 166s
Cycle offset at t=166: 166 mod 96 = 70  → Phase 2 (EW_GREEN = NS_RED) ✓
Next NS_GREEN: t = 96*2 = 192s
Expected wait: 192 - 166 = 26 seconds
```

---

## Metrics Design

### Why per-step logging?

Fine-grained step data lets us:
1. Plot queue evolution over time to spot congestion patterns
2. Identify which phase has the most waste
3. Feed real-time state vectors to the Phase 2 RL agent
4. Compare Phase 1 vs Phase 2 on identical time windows

### Rolling Throughput Window (60s)

Throughput at any moment = vehicles that completed journeys in the
preceding 60 seconds. A 60s window smooths out per-step noise while
still being responsive enough to detect phase-level changes.

---

## Known Limitations (intentional for Phase 1)

1. **Single intersection** — no spillback from upstream/downstream signals
2. **No pedestrian modelling** — Accra has significant pedestrian activity
3. **Uniform demand** — no intra-hour variation (real rush has a peak ~7:45 AM)
4. **No lane changes at approach** — SUMO handles this but we don't customise it
5. **No broken-down vehicles** — common in Accra; Phase 3 candidate
6. **No hawkers / informal activity** — affects effective lane width in reality

These simplifications are standard for Phase 1 RL baseline research.

---

## Phase 2 Roadmap

1. Install gymnasium: `pip install gymnasium`
2. Wrap TraCI loop as a gym environment in `ai/atcs_env.py`
3. State vector: per-lane queue lengths + current TL phase + phase time elapsed
4. Action space: {keep current phase, switch to next phase}
5. Reward: negative average queue length (minimise waiting)
6. Train DQN agent with stable-baselines3
7. Compare baseline_results.csv vs ai_results.csv on same metrics
