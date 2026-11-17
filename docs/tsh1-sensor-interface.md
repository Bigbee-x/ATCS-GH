# TSH-1 sensor interface — 13 November 2026

TSH-1 is the roadside sensor head designed for TrafIQ: imaging radar, wide and
tele cameras, a thermal core and on-board compute, one head per junction arm. It
publishes what it sees as an **arm frame** once a second, in the sim's own IDs
and units, so the agent host can rebuild the exact inputs the trained agents
read. This file is the repo copy of the interface board from the TSH-1 design
canvas, which is a private artifact in the project owner's Claude account.

## Where things are

| Path | What it is |
|---|---|
| `ai/tsh1_interface.py` | The adapter: `emulate_arm_frames` (what four heads would send, emulated from SUMO), `LaneSpeedBlend` (the whole-lane speed estimate), `state_from_frames` (frames + controller phase → the 41 inputs) |
| `scripts/validate_tsh1_interface.py` | Round-trip check, 30 simulated minutes of the morning rush. Expect `decisions 360 \| exact round trip 360 \| mean lane-speed error 1.71 m/s` |
| `scripts/eval_tsh1_sensor_range.py` | The sensor-range experiment behind the results below |
| `logs/tsh1-sensor-range/` | Where that experiment writes its JSON (gitignored) |
| `visualizer/scripts/SensorBuilder.gd` | The head in the Godot scene; **K** paints each sensor's road footprint |

**14 November implementation update:** `ai/tsh1_corridor.py` now implements
the corridor's 46 inputs, exits, tracker age and a read-only supervisor bridge.
`scripts/validate_tsh1_corridor.py` checks JSON transport at 1 Hz against both
occupancy scales and the deployed supervisor. See the new contract below and
[the deployment validation report](corridor-deployment-validation.md).

## The arm frame (`atcs-gh/tsh1-arm/1`)

A real frame, emulated for the north arm of J0 with a 200 m head, 901 s into the
morning rush (seed 20260610), three of its ten tracks shown:

```json
{
  "schema": "atcs-gh/tsh1-arm/1",
  "junction": "J0",
  "arm": "N",
  "edge": "ACH_N2J",
  "sample_time": 901.0,
  "range_m": 200.0,
  "lanes": [
    {"lane": "ACH_N2J_1", "speed_limit_ms": 13.89, "vehicles": 9, "halting": 6,
     "window_speed_ms": 0.13, "wait_sum_s": 38.0, "queue_at_range_edge": false,
     "est_hidden_vehicles": 24.73, "lane_speed_ms": 8.32},
    {"lane": "ACH_N2J_2", "speed_limit_ms": 13.89, "vehicles": 1, "halting": 0,
     "window_speed_ms": 3.71, "wait_sum_s": 0.0, "queue_at_range_edge": false,
     "est_hidden_vehicles": 0.91, "lane_speed_ms": 7.55}
  ],
  "corner": {"area": ":J0_w0", "persons": 0, "waiting": []},
  "vehicles": [
    {"track": "flow_NS.120", "lane": "ACH_N2J_1", "distance_m": 1.0, "speed_ms": 0.0,
     "wait_s": 13.0, "link_index": 1, "class": "car"},
    {"track": "flow_NE.19", "lane": "ACH_N2J_2", "distance_m": 3.0, "speed_ms": 3.71,
     "wait_s": 0.0, "link_index": 2, "class": "car"},
    {"track": "flow_NS_t.12", "lane": "ACH_N2J_1", "distance_m": 8.5, "speed_ms": 0.0,
     "wait_s": 9.0, "link_index": 1, "class": "trotro"}
  ]
}
```

At that moment SUMO's whole-lane mean speeds were 7.91 and 12.23 m/s. Lane `_1`
shows the gap the estimate closes: 0.13 m/s in view (a queue at the stop line),
8.32 m/s estimated, 7.91 m/s true. On the nearly empty lane `_2` the estimate is
rougher (7.55 against 12.23).

| Field | Meaning | Replaces (TraCI) |
|---|---|---|
| `schema`, `junction`, `arm`, `edge` | Frame version, junction, approach (N/S/E/W) and its SUMO edge | |
| `sample_time` | Sim seconds; on hardware, the head's GNSS clock | `simulation.getTime` |
| `range_m` | How far from the stop line the head sees; `null` = the whole lane (ideal head) | |
| `lanes[].speed_limit_ms` | The lane's limit | `lane.getMaxSpeed` |
| `lanes[].vehicles` | Vehicles in view | |
| `lanes[].halting` | Vehicles in view slower than 0.1 m/s | `lane.getLastStepHaltingNumber` |
| `lanes[].window_speed_ms` | Mean speed of the vehicles in view; the limit if there are none | |
| `lanes[].lane_speed_ms` | Whole-lane mean speed, estimated (see below). The agent reads this | `lane.getLastStepMeanSpeed` |
| `lanes[].est_hidden_vehicles` | Vehicles estimated on the lane beyond the view | |
| `lanes[].wait_sum_s` | Each vehicle's continuous stopped time, summed. It resets to 0 once the vehicle moves | `lane.getWaitingTime` |
| `lanes[].queue_at_range_edge` | A halted vehicle within 14 m of the view's far edge, so the queue may go on out of sight | |
| `corner.area`, `corner.persons` | The corner's walking area and everyone inside it, waiting or passing through | `edge.getLastStepPersonIDs` |
| `corner.waiting[]` | Per person: `next_crossing`, `wait_s` | `person.getNextEdge`, `person.getWaitingTime` |
| `vehicles[]` | Tracks within 160 m: `track`, `lane`, `distance_m` (to the stop line), `speed_ms`, `wait_s`, `link_index`, `class` | `vehicle.*`, `vehicle.getNextTLS` |
| `vehicles[].age_s` | Corridor: time since the track was first seen within 160 m. Not emulated; the supervisor keeps its own `first_seen` | |
| `exits[]` | Corridor: per receiving lane, `occupancy`, `tail_m` (nearest car past the junction), `tail_speed_ms`. Not emulated yet | `lane.getLastStepOccupancy`, tail vehicle |

Definitions that must match the sim exactly (checked on SUMO 1.27.1):

- **halting**: slower than 0.1 m/s, SUMO's threshold.
- **empty lane speed**: the lane's limit, never 0 (13.89 m/s at J0; 8.33 or
  11.11 on some corridor arms).
- **occupancy**: vehicle lengths ÷ lane length, 0 to 1, gaps excluded. A car-only
  jam tops out near 0.64 (`ai/occupancy.py`).
- **cadence**: frames at 1 Hz, as the sim's detectors update. The agent still
  decides every 5 s.

## Inputs, slot by slot

| Slots | Input | Sim reads | TSH-1 field | Scale |
|---|---|---|---|---|
| 0–7 | Lane queue | `lane.getLastStepHaltingNumber` | `lanes[].halting` | ÷ 75 |
| 8–15 | Lane mean speed | `lane.getLastStepMeanSpeed` | `lanes[].lane_speed_ms` | ÷ 13.89 |
| 16–23 | Lane wait | `lane.getWaitingTime` | `lanes[].wait_sum_s` | ÷ 1200 |
| 24–27 | Arm queue | halting summed over the edge | sum of `lanes[].halting` | ÷ 150 |
| 28–35 | Phase | env phase, one-hot | signal controller | one-hot |
| 36 | Time in phase | env phase timer | signal controller | ÷ 96, max 1 |
| 37–40 | People at corners | persons on `:J0_w0` … `:J0_w3` | `corner.persons` | ÷ 15 |
| 41–44 | Neighbour queue, phase (corridor) | neighbour junction's state | neighbour frames + phase | ÷ 150, ÷ 7 |
| 45 | Link occupancy (corridor) | `edge.getLastStepOccupancy` | `exits[].occupancy` | old scale, see open items |

- Slots 0–40 are the single junction's 41 (`TrafficEnv._build_state`); the
  corridor adds 41–45 for 46 per junction (`corridor_env.py`).
- Each corner belongs to one head (N→`w0`, E→`w1`, S→`w2`, W→`w3`), so nobody is
  counted twice.
- Two heads see each 279 m corridor link from both ends, so a link is covered
  end to end.
- Lane order: single junction N, S, E, W (lane `_1`, then `_2`); corridor N, E,
  S, W, with one-lane arms padded at the end.

## Lane speed: the one real gap

SUMO averages lane speed over the whole 1.5 km lane, mostly free-flowing cars a
head can't see. Sending only the speed in view cost up to 2.3× the wait.
`LaneSpeedBlend` estimates the unseen part with Little's law:

- A track first seen more than `range − 75 m` from the stop line counts as an
  entry. Entries are kept for 120 s.
- inflow = entries ÷ 120 s; `v_in` = mean entry speed (the limit if none)
- hidden vehicles = inflow × (lane length − range) ÷ max(`v_in`, 0.5)
- `lane_speed_ms` = (sum of speeds in view + hidden × `v_in`) ÷ (vehicles in
  view + hidden), or the limit on an empty lane

## Results

`ai/best_model.pth` (the shipped single-junction agent), greedy, full 2-hour
scenarios. Heads are emulated from SUMO. The score is the env's own average wait
(`episode_avg_wait`, the README's number), in seconds; lower is better.
Fixed-timer values are `data/scenario_baselines.csv`.

Seed 20260610 (the official eval seed):

| Scenario | Fixed timer | Agent on SUMO state | 200 m, speed in view | 160 m, speed in view | 200 m + SUMO's speed ¹ | 200 m, lane-speed estimate | 160 m, lane-speed estimate |
|---|---|---|---|---|---|---|---|
| continuous_day | 47.6 | 22.9 | 36.5 | 34.7 | 21.0 | 20.8 | 17.9 |
| morning_rush | 186.7 | 29.9 | 41.5 | 38.8 | 27.5 | 29.1 | 26.8 |
| evening_rush | 427.4 | 271.1 | 265.4 | 307.6 | 214.9 | 251.4 | 225.7 |
| weekend_market | 885.8 | 14.9 | 33.9 | 30.2 | 14.9 | 14.5 | 14.7 |
| off_peak | 14.2 | 9.0 | 14.2 | 17.6 | 9.0 | 8.2 | 8.7 |

¹ Diagnostic only: range-limited counts and waits, but SUMO's true whole-lane
speed.

Four seeds (20260610, 42, 271, 503), mean of the four:

| Scenario | Agent on SUMO state | 200 m, speed in view | 200 m, lane-speed estimate |
|---|---|---|---|
| continuous_day | 20.3 | 35.5 | 20.9 |
| morning_rush | 28.4 | 36.7 | 25.7 |
| evening_rush | 259.5 | 241.4 | 257.5 |
| weekend_market | 14.7 | 31.2 | 14.3 |
| off_peak | 8.7 | 14.9 | 8.5 |

Per run against the agent on SUMO state (20 runs per column): the lane-speed
estimate averaged 0.98× (0.70 to 1.23×); speed in view alone averaged 1.57× (up
to 2.27×), and in off-peak it was worse than the fixed timer.

What this shows:

- **The frame carries everything.** With unlimited range, frames rebuild all 41
  inputs bit-for-bit at every decision of all five scenarios.
- **Range still loses information.** Evening queues reach 107 cars a lane
  (about 750 m), with 44 % of stopped cars outside a 200 m view. Similar average
  control scores do not establish accurate queue/wait measurements or safe
  operation under sensor saturation.
- The speed estimate improved these historical single-junction runs; its
  errors and control outcomes still vary by traffic pattern and seed.
- The evening rush is saturated and single runs swing widely there; read it
  across seeds.

Re-checked 14 November 2026 after restoring the scripts: the round-trip check
gave 360 of 360 exact and 1.71 m/s, and `off_peak` with the 200 m estimate gave
8.2 s, both as recorded. The per-run result files from 13 November were lost
with a temporary folder; rerun the experiment to regenerate them.

These historical experiments use the bare single-junction environment, without
the corridor's deployed crossing/boarding supervisor. They update the estimator
once per 5-second decision, **not at the proposed 1 Hz hardware cadence**. They
are not field validation or a test of the final corridor runtime. The 360/360,
1.71 m/s compatibility check was reproduced again on 14 November. The estimator
now consumes only transmitted visible tracks and surveyed lane length; it no
longer needs access to TraCI. Limited-frame policy input requires an explicit
whole-lane speed estimate; raw-window speed is a named research ablation.

## Implemented corridor contract — 14 November

`atcs-gh/tsh1-corridor-arm/1` is deliberately separate from the single-junction
schema. A synchronized batch has 12 heads: N/E/S/W for J0/J1/J2. Each frame
includes `network_sha256`, the mapped incoming edge/lanes, its corner, visible
lane tracks, supervisor tracks and all receiving lanes on that arm.

- The map is loaded from `simulation/corridor.net.xml` without importing SUMO.
  Local lanes use the corridor's N/E/S/W order and end padding. Neighbour pairs
  are south queue/phase then north queue/phase. Slot 45 selects the model
  bundle's `legacy` or `fullness` contract, without changing a global setting.
- `lanes[].tracks` contains every visible track, with stable head-local ID,
  distance and speed. Aggregate and supervisor records must agree. The speed
  estimator can be configured with a corridor arm map, but its accuracy on
  range-limited corridor traffic has **not** been established by the ideal
  round-trip test.
- Supervisor tracks add `age_s`, `link_index`, `intended_lane` and
  `movement_basis`. The observed lane can differ from the lane SUMO plans to
  use after a lane change; this distinction is explicit. Physical input requires
  confirmed movement intent. Probabilistic turn inference is still open.
- `exits[]` contains `lane`, fractional `occupancy`, `coverage_m`,
  `occupancy_basis`, `tail_state` (`observed` or explicitly `empty`), `tail_m`
  and `tail_speed_ms`. Full-lane occupancy and the instantaneous tail are
  different observations: a last-step occupancy can remain nonzero just after
  the last vehicle leaves. Unknown/occluded tails cannot be reported as empty.
- The receiver requires complete heads, lanes, exits, track details and
  pedestrian intent; finite values and fractional occupancy; fresh observations
  (maximum age 2.5 s), maximum 0.25 s skew, synchronized controller phase/timer,
  and strictly advancing samples. Missing information is rejected, never filled
  with an invented zero. A queue touching the sensor boundary is rejected by
  the default policy-input gate.
- `CorridorFrameAPI` exposes only the read operations used by
  `CorridorController.observe()`. The supervisor also reads transmitted age, so
  reconnecting its host need not erase a waiting vehicle's observed age.
  It does not implement traffic-light commands or the pedestrian conflict-zone
  occupancy needed by a physical clearance interlock.

The emulator labels exit data `simulator_full_lane` and turn intent
`simulator_route`. Receivers reject these by default; only tests explicitly
enable `allow_simulator=True`. In particular, limiting incoming range to 200 m
does **not** make the emulator's receiving-road occupancy a real 200 m sensor
measurement. Two-ended link fusion, occlusion/error models, physical movement
classification, clock calibration, controller fallback and hardware safety
interlocks remain field-integration work. Rejecting a frame does not itself
command an all-red or a fixed timer; the physical controller must own that
approved transition.

## Corridor supervisor inputs

`CorridorController.observe()` (`ai/corridor_controller.py`), once per second:

- **Vehicles within 160 m**: `distance_m`, `speed_ms`, `wait_s` and `age_s` come
  from the tracker; `link_index` comes from the lane and the movement.
- **Turn intent**: on the corridor, lane `_2` carries straight, left and U-turn,
  and one-lane arms carry every movement, so a lane's demand splits across
  phases. The head predicts each car's movement from its path and turn signal,
  using that lane's measured turning split until the car commits. At the single
  junction the lane alone decides.
- **People**: `next_crossing` from where each person stands and faces; `wait_s`
  is time standing still. Push-button calls can confirm intent.
- **Exits**: `occupancy`, `tail_m` and `tail_speed_ms`. An exit is blocked when
  it is at least 85 % full, or when the tail is under 12 m away and below 1 m/s.

## Open items

1. **Done, 13 Nov.** The corridor reads occupancy on SUMO's real 0 to 1 scale
   (`ai/occupancy.py`), from vehicle lanes only, against a bumper-to-bumper jam.
   The spillback penalty and the 85 % blocked-exit limit now respond to a jammed
   link, and the four audited runs make the same decisions as before.
2. **Open.** Input 45 stays on its old scale, near 0, until the corridor models
   are retrained: fed the corrected value, the shipped models misbehaved. Three
   retrains on 13 Nov didn't pass and nothing was installed; see
   `docs/corridor-occupancy-fix.md`.
3. **Open.** The agents' speed inputs span 1.5 km of lane. Keep the estimator in
   the head, or train on range-limited frames so the agent never needs it.
4. **Implemented and tested, 14 Nov.** Ideal corridor emulation and wire-only
   reconstruction are in `ai/tsh1_corridor.py`; the three two-hour scenario
   checks reproduce all 46 inputs and supervisor decisions exactly. This
   validates the software contract, not physical sensing accuracy.

## Hardware in brief

From the spec sheet (concept, rev A):

| Part | Choice |
|---|---|
| Edge compute | NVIDIA Jetson Orin NX 16 GB |
| Imaging radar | TI AWR2944, Rogers RO3003 antenna |
| Cameras | 2× Sony IMX678, M12 2.8 mm and 12 mm lenses |
| Thermal | Teledyne FLIR Lepton 3.5 |
| Cellular backup | Quectel RM520N-GL (5G, M.2) |
| Timing, motion | u-blox NEO-M9N GNSS; TDK ICM-42688-P IMU |
| Power | PoE++ 802.3bt Type 4 (TI TPS2373-4), one Cat6A run up to 100 m; about 23 W typical, 53 W peak |
| Housing, mount | A380 die-cast aluminium, IP67; 316 stainless gimbal for top, bottom or side mounting |
| Size, mass | 220 × 120 × 160 mm body; ≤ 3 kg with mount |

## Reproduce

From the repo root:

```bash
.venv/bin/python scripts/validate_tsh1_interface.py
.venv/bin/python scripts/eval_tsh1_sensor_range.py true
.venv/bin/python scripts/eval_tsh1_sensor_range.py r200_blend --seed 42
```

Modes: `true`, `r200`, `r160`, `r200_simspeed`, `r200_blend`, `r160_blend`.
`--scenarios` runs a subset; the default seed is 20260610. `true` also records
the round trip, how often the queue ran past 200 m and 160 m, and how often the
agent would have chosen the same action on range-limited frames.
