# Corridor control investigation — 13 November 2026

The selected deployment combines the existing three DQN checkpoints with a
movement-aware supervisor. It improves all four matched test cases below.
The checkpoint weights were preserved; this change improves observation handling,
decision supervision, runtime consistency and the station layout.

## What caused the regression

The 3D car meshes and display spacing do not feed the AI. SUMO is the source of
its observations. The boarding service and pedestrian-clearance interlock do
change the physical simulation, and the old evaluation excluded both.

With the original morning seed 42 and both live services enabled, raw DQN
completed 2,082 trips, averaged 570.4 stopped vehicles and allowed J0 to remain
in one green for 3,817 simulated seconds. A lane-wait feature reached 567 times
its normalization scale. The policy had no maximum-service/fairness supervisor
and kept requesting the same phase while queues grew.

Ablations help separate the causes: without the live services, the same models
completed 4,132 trips and averaged 18.5 stopped vehicles. Keeping pedestrian
clearance but disabling stops produced 2,742 trips and 348.0 stopped vehicles.
Moving stops alone produced 2,687 trips and 343.8 stopped vehicles. Station
placement mattered, but it was not a sufficient fix for the policy's response
to the changed dynamics. Pedestrian clearance remains enabled in deployment.

Both old stations also stopped trotros in through lanes on approximately
280-metre links between junctions. They are now on the long outbound approaches:
ACH_J0toS and ACH_J2toN, 320 metres beyond their junction exits, with off-road
boarding stops and matching 3D bays. The short inter-junction links remain clear
of scheduled boarding. Existing single-junction station behavior is retained.

## What the controller now observes and does

- SUMO detectors update once per simulated second. Decisions remain on the
  five-second cadence, with shared minimum-green and full three-second yellow
  transitions. Simulator-backed detectors provide the perception; the rendered
  camera/sensor models are scenery, not a computer-vision inference pipeline.
- Detectors resolve actual next traffic-light movements, head-of-lane vehicles,
  queues within 160 metres, approaching traffic, waiting pedestrians and the
  receiving lanes' occupancy and upstream queue tails.
- Neural inputs keep their checkpoint feature order and normalization scales,
  with finite saturation handling. The supervisor combines DQN proposals with
  queue pressure, a holding bias against unnecessary switching, ageing demand,
  downstream capacity and maximum green limits when competing demand exists.
- Pedestrians retain their clearance interlock. Manual requests still obey
  minimum-green/yellow rules. Missing or incompatible models select the fixed
  timer, rather than silently presenting random actions as AI.
- The live server and evaluation share `CorridorRuntime` and the environment's
  one-second physics/transition methods. Per-junction telemetry includes the
  proposed/applied action, reason, detector timestamp and blocked exits.
- Current mean wait is now divided by the actual vehicle count. Historical
  lane-wait sums are retained only as legacy scores in diagnostic output. The
  UI no longer compares live traffic with an incompatible historical baseline.

## Matched performance checks

Each case runs the full configured two-hour demand horizon (7,201 SUMO steps,
including initialization), with identical routes, seeds, boarding, pedestrian
clearance and three-second yellow timing for both controllers. Fixed timing
uses protected turns and 22-second offsets between adjacent junctions.

Mean stopped vehicles is stopped vehicle-seconds divided by elapsed simulation
time, measured on incoming road edges. It includes unfinished queues and avoids
judging a gridlocked run only by the few trips that managed to finish.

| Scenario | Seed | Fixed: completed trips | AI: completed trips | Fixed: mean stopped | AI: mean stopped | Reduction |
|---|---:|---:|---:|---:|---:|---:|
| Morning | 42 | 3,872 | 3,884 | 117.7 | 90.0 | 23.5% |
| Evening | 179 | 3,996 | 4,087 | 83.1 | 44.0 | 47.0% |
| Off-peak | 316 | 2,008 | 2,021 | 12.2 | 5.7 | 53.8% |
| Morning holdout | 997 | 3,889 | 3,910 | 111.8 | 85.1 | 23.9% |

Across these selected runs, competing demand did not produce the previous
hour-long green holds. These are scenario/seed-specific regression results,
not a claim of optimality for every demand pattern. Completed-trip travel times,
unfinished vehicle counts, phase durations, collision/teleport reports and
checkpoint hashes are recorded in `corridor-control-results.json`.

## Validation and reproduction

```sh
.venv/bin/python3 scripts/validate_corridor_control.py
.venv/bin/python3 scripts/validate_trotro_service.py
.venv/bin/python3 scripts/diagnose_corridor.py --controller adaptive --seed 42 --output /tmp/ai.json
.venv/bin/python3 scripts/diagnose_corridor.py --controller fixed --seed 42 --output /tmp/fixed.json
.venv/bin/python3 scripts/eval_corridor.py --compare
godot --headless --path visualizer --script res://tools/validate_live_traffic.gd
godot --headless --path visualizer --script res://tools/validate_transit.gd
```

Use `--route corridor_routes_evening.rou.xml --seed 179` or
`--route corridor_routes_offpeak.rou.xml --seed 316` for the other demand patterns.
`--controller dqn` audits the unprotected checkpoint policy with the live services;
`--no-clearance`, `--no-transit` and `--stations PATH` support explicit ablations.
The older training path remains a legacy environment unless it attaches the
shared runtime; future checkpoints should be trained and selected against the
same deployment services. No new neural weights were trained during this fix.
