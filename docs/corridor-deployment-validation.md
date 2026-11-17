# Corridor deployment investigation — 14 November 2026

The training and sensor interfaces are now reproducible and tested against the
deployed corridor runtime. A real signal-transition defect was fixed. **No new
policy passed the replacement gate**, so the shipped weights and their legacy
slot-45 input remain active. Graded exit capacity remains disabled. This is not
a claim that the current system is ready to control a physical junction.

Machine-readable results, checkpoint hashes, individual case metrics and the
live-server check are retained in
[`corridor-deployment-results.json`](corridor-deployment-results.json).
Detailed local outputs are in `logs/corridor-deployment-20261114/` (gitignored).

## What changed

1. **Training uses deployment behaviour.** `train_corridor.py` now delegates
   its CLI to `train_corridor_deployment.py`. The same `CorridorRuntime` attaches
   pedestrian clearance, trotro boarding, per-second detection and signal
   supervision. Policy inputs are bounded identically during training and
   inference. Replay records the proposed action and its actual supervised
   consequence; it does not relabel the proposal after an override.
2. **Experiments cannot overwrite the shipped directory.** Outputs are isolated
   immutable snapshots, with three model hashes, network hash, feature scale
   and graded-capacity setting in each manifest. The live server and evaluators
   load those settings together. An incompatible live bundle causes explicit
   fixed-timer fallback. Complete-episode resume saves replay, optimizers,
   targets, epsilon and Python/NumPy/Torch RNGs. New resumable runs also pin source,
   route, package and parent-model hashes; continuing under changed training
   conditions requires a new isolated run.
3. **Input 45 has an explicit model contract.** The environment can select
   `legacy` or `fullness` per instance. A transfer initialization scales column
   45 of the first layer by `0.004285714285714286`: car jam occupancy × two
   motor lanes / three total lanes / 100. This preserves the first-layer
   function below lane saturation; mixed traffic and clipping still need
   empirical tests. It is a unit conversion, **not additional learning**.
4. **Right-turn yellow is preserved.** The pedestrian guard previously checked
   only straight `Gg` when deciding whether to suppress a right turn. During
   straight yellow it therefore cut the right turn directly to red. In the
   reproduced evening seed 20261116, a car braked from 6.56 m/s to zero at the
   stop line and its follower breached SUMO's minimum gap. Keeping right-turn
   yellow removes that event. Occupied crossings still hold conflicts at red,
   and right turns remain red during protected-left service. This correction
   changes the simulation baseline; pre-fix tables are not final comparisons.
5. **Comparisons use the same demand.** `eval_corridor.py --route ... --compare`
   passes the same resolved route to AI and fixed timer, including project-relative
   paths. The multi-case evaluator fingerprints routes, model manifests,
   runtime sources, network, station config and SUMO version before reusing
   results. It records real stopped vehicle-seconds, completed/unfinished trips,
   colliding vehicle counts and event details, separately from legacy wait scores.
6. **TSH-1 covers the corridor software contract.** `ai/tsh1_corridor.py` builds
   the 46 inputs, receiving-lane observations, age and movement records from
   synchronized JSON frames. A read-only API feeds the existing supervisor
   without querying hidden SUMO state. Invalid, incomplete, stale, replayed,
   unsynchronized or out-of-range data is rejected. See
   [`tsh1-sensor-interface.md`](tsh1-sensor-interface.md) for the wire contract.

## Training and selection evidence

Six independent warm-start fine-tunes completed **72 full two-hour episodes**:

| Cohort | Seeds | Episodes per seed | Learning rate | Anchor weight | Initial epsilon | Runtime |
|---|---|---:|---:|---:|---:|---|
| Initial transfer | 101, 202, 303 | 6 | 2e-5 | 0.25 | 0.05 | Before yellow fix |
| Conservative transfer | 101, 202, 303 | 18 | 2e-6 | 2 | 0.02 | Corrected yellow |

Both use corrected fullness inputs, Double-DQN updates and an anchor to the
calibrated initial policy. These are fine-tunes, not fresh 240-episode retrains.
Six initial and eighteen conservative snapshots were screened. The initial
cohort did not pass. Four conservative snapshots passed the first three cases;
all four failed the additional morning seed 997 case. Examples below show why
an average training reward or three favourable cases cannot select deployment.

Mean stopped vehicles over each identical two-hour audit; lower is better:

| Case | Fixed timer | Shipped | Calibrated, no learning | Fine-tune 303 / episode 12 |
|---|---:|---:|---:|---:|
| Morning 42 | 114.18 | 91.86 | 91.86 | 84.79 |
| Evening 179 | 84.50 | 47.32 | 47.32 | 45.29 |
| Off-peak 316 | 12.27 | 5.58 | 5.58 | 5.38 |
| Morning 997 | 117.73 | 81.42 | 81.42 | 91.28 |

That fine-tune improves the first three cases but increases stopped vehicles
12.1% in the fourth, reduces completions more than the allowed 0.5%, and records
a minimum-gap collision. It is not installed. The other shortlisted candidates
also fail that fourth case (12.5–29.6% stopped-vehicle regressions).

The gate requires zero collisions/teleports, no stopped-vehicle regression in
any case, at least 99.5% of shipped completed trips, and a win against the matched
fixed timer. A development-screen pass or one suite's `eligible` flag is **not**
deployment approval: the four audits and independent holdouts must both pass at
the full duration. The evaluator never installs models.

## Broader traffic checks and remaining failures

The four audit cases were followed by three scenarios × seeds
20261114/20261115/20261116. That first expanded set exposed the yellow bug; after
using it for a fix, it was classified as a **regression set**, not unseen evidence.
The corrected runtime was then checked on three scenarios × fresh seeds
20261121/20261122/20261123. No candidate was tuned against this final set.

The calibrated occupancy conversion produced identical traffic actions, phase
durations, arrivals, stopped-vehicle totals, trip statistics, boarding and
incident counts to the shipped agents in **all 22 cases**. This establishes a
tested migration path for the input scale; it does not improve the policy.

The final holdout also exposes limitations in the shipped controller:

- Morning seed **20261121** records one minimum-gap event involving two vehicles
  on `ACH_J2toJ1_1` at 3771 s. There are no teleports. This is a remaining
  simulator failure, not a claim of proven physical collision avoidance.
- Evening seed **20261121** has **98.87** mean stopped vehicles versus **91.17**
  for the fixed timer (8.4% worse), although it completes more trips (3981 vs
  3953). Aggregate averages must not hide this case.
- Graded exit capacity regresses the worst audit case by **22.0%**, the worst
  regression-set case by **19.9%**, and the worst new holdout by **9.8%**. It also
  records a minimum-gap event in a new holdout. It remains disabled.

The next policy investigation should target these recorded cases and the
interaction between fairness overrides, short-link queues, movement intent and
crossing holds. They are now reproducible regression cases; any subsequent
promotion study must reserve a new untouched seed set. More training alone is
not evidence that a replacement is better.

## Sensor and runtime validation

- At **1 Hz**, morning/evening/off-peak each checked 7201 samples, all three
  junctions, both occupancy contracts, and JSON serialization. Across the three
  runs: **129,618 exact 46-value vectors**, **64,809 exact junction supervisor
  observations**, and **12,960 matching junction decisions**. The simulation
  actually executed the decisions reconstructed from frames.
- Twelve negative corridor-frame checks cover missing heads/exits, stale and
  replayed frames, clock skew, wrong network, percent occupancy, partial exit
  coverage, invalid movements, missing pedestrian intent and simulator-only
  data presented to the physical-input gate. Additional contract regressions
  cover nonfinite values, input-domain mismatches, estimator history integrity,
  model hashes, lane order/scales and yellow preservation.
- The single-junction compatibility test reproduces **360/360 exact vectors**
  and **1.71 m/s** estimated lane-speed error. It uses the historical five-second
  estimator cadence; that number is not a 1 Hz corridor sensor accuracy claim.
- Seven occupancy tests and nine controller tests pass. The real SUMO crossing
  test completes all 29 single-junction and 119 corridor crossing pedestrians,
  with zero recorded colliding vehicles in those checks.
- A learned two-episode run (5100 s per episode) was executed uninterrupted and
  across a process restart. Policy/target tensors, optimizer state, replay and
  all RNG states match exactly. The off-peak `eval_corridor.py --route ...
  --compare` CLI also completes with both controllers on the requested route.
- An isolated **actual TraCI socket live server** loaded the calibrated fullness
  manifest and streamed 12 advancing full AI packets with real vehicles, all
  three supervisors, current signal states and synchronized traffic metrics.
  The test server was shut down; the user's editor and default launcher were
  not replaced.

These sensor checks use **ideal emulation**. Receiving-road occupancy and turn
intent are explicitly labelled simulator oracles and rejected by default on
physical input. Full-link fusion, uncertain turn classification, visibility and
occlusion errors, physical crossing-zone occupancy, synchronized hardware
clocks and an independently approved signal-controller fallback remain required.
A wire-format match is not field certification.

## Reproduce

Python 3.11.16, Torch 2.14.1, NumPy 2.4.6, SUMO/libsumo 1.27.1 on Apple Silicon.
Version-matched libsumo is optional and used only for experiment processes:

```bash
python -m pip install -r requirements-experiments.txt

LIBSUMO_AS_TRACI=quiet .venv/bin/python3 scripts/train_corridor.py \
  --output ai/checkpoints/corridor/my-run --seed 101 --episodes 18 \
  --learning-rate 0.000002 --anchor-weight 2 --epsilon 0.02

LIBSUMO_AS_TRACI=quiet .venv/bin/python3 scripts/validate_corridor_candidates.py \
  --output logs/my-audit --suite audit --workers 3 --graded-study \
  --candidate candidate=ai/checkpoints/corridor/my-run/episode-018

LIBSUMO_AS_TRACI=quiet .venv/bin/python3 scripts/validate_tsh1_corridor.py \
  --duration 7200 --route corridor_routes_evening.rou.xml --seed 179

.venv/bin/python3 scripts/validate_deployment_contracts.py
```

Resume by repeating a run's configuration with `--resume` and a larger episode
limit. Resume files made before source-contract recording can be inspected or
used as immutable warm-start snapshots; they cannot silently continue training
under an unverified runtime. `--duration` shorter than 7200 is a smoke test,
never promotion evidence.

Full morning and evening audits matched across socket TraCI and libsumo on all
recorded traffic outcomes (only timings, paths and cache metadata excluded).
The morning audit measured about 10 s with libsumo versus 360 s with socket
TraCI under concurrent load; this is an environment-specific measurement.
Use separate OS processes for simultaneous libsumo simulations, as described in
the [SUMO libsumo documentation](https://sumo.dlr.de/docs/Libsumo.html).

Raw folders: `audit/`, `screen/` and `holdout/` are the pre-yellow-fix study;
`conservative-screen/` and `final/` are the corrected-runtime study.
`backend-parity/`, `environment.json`, `tsh1-*.json` and
`live-server-check.json` retain the supporting checks. Models are local under
`ai/checkpoints/corridor/_deployment_20261114/`; checkpoints and logs are
gitignored. The three shipped checkpoint hashes are unchanged. Nothing was
committed.
