# Corridor occupancy fix — 13 November 2026

## What was wrong

SUMO 1.27.1 returns `lane.getLastStepOccupancy` and `edge.getLastStepOccupancy`
as a fraction from 0 to 1: the summed vehicle lengths divided by the lane length,
gaps excluded. The corridor code treated it as a percentage and divided it by 100
again in three places:

| Where | Used for | Effect of the extra ÷100 |
|---|---|---|
| `ai/corridor_env.py` `_build_state` | state slot 45, max corridor link occupancy | never above ~0.004 |
| `ai/corridor_env.py` `_compute_corridor_reward` | spillback penalty above `SPILLBACK_THRESH = 0.8` | never fired |
| `ai/corridor_controller.py` `observe()` | receiving-lane `blocked` (≥ 0.85) and `capacity` | no exit was ever blocked by occupancy |

Two more problems kept those thresholds out of reach even without the ÷100:

- An edge's occupancy averages all of its lanes, including lane 0, which on the
  corridor links is a pedestrian-only sidewalk. A fully jammed two-lane link
  reads about 0.43.
- Without gaps, a bumper-to-bumper car queue covers only 4.5 / 7.0 ≈ 0.64 of a
  lane, so 0.8 and 0.85 could never be reached.

## What changed

- `ai/occupancy.py` (new) is the one place occupancy is read. `fullness` is
  SUMO's occupancy divided by the car jam level (0.643), capped at 1.0, so 1.0
  means bumper to bumper and the existing 0.8 / 0.85 thresholds mean what they
  say. `LinkOccupancy` averages vehicle lanes only.
- Spillback reward: uses link fullness. This affects training only; the
  deployed policy never reads rewards.
- Supervisor: an exit at 85 % fullness or more is now blocked (the "tail within
  12 m and slower than 1 m/s" rule still applies). Its `receiving_lanes`
  telemetry carries the raw `occupancy` (0–1) and `fullness`.
- Graded exit capacity (`1 − fullness / 0.9`) was written into the supervisor
  but had never acted. It is now behind `GRADED_EXIT_CAPACITY = False` in
  `ai/corridor_controller.py`; see the matched runs below.
- State slot 45: `LINK_OCCUPANCY_FEATURE` in `ai/corridor_env.py`. `"legacy"`
  (the default) gives the shipped checkpoints exactly the values they were
  trained on; `"fullness"` is the corrected signal for retraining.

## Validation

`scripts/validate_occupancy.py` parks 70 cars on `ACH_J0toJ1` (both vehicle
lanes, from 30 m past J0 to the J1 stop line, 88 % of the link bumper to
bumper), then reads it:

| Reading | Before | After |
|---|---|---|
| Lane occupancy as used | 0.0056 | fullness 0.878 |
| Edge occupancy | 0.376, sidewalk averaged in | vehicle lanes 0.878 |
| State slot 45 | 0.0038 | 0.0038 legacy · 0.878 fullness |
| J0 spillback reward | 0.0 | −0.39 |
| Both exit lanes | not blocked | blocked, capacity 0 |

`validate_corridor_control.py` (9 tests) and `validate_crossing_safety.py`
(0 collisions) still pass.

## Matched runs

`diagnose_corridor.py --controller adaptive`, full 2 hours, live services on.
Mean stopped vehicles, with completed trips in brackets; lower is better.
"Before" reproduces the corridor control audit table exactly.

| Case | Fixed timer | Before | Final (default) | Graded capacity on | Graded capacity on + slot 45 corrected |
|---|---|---|---|---|---|
| Morning, seed 42 | 117.7 (3,872) | 90.0 (3,884) | 90.0 (3,884) | 86.5 (3,909) | 96.3 (3,865) |
| Evening, seed 179 | 83.1 (3,996) | 44.0 (4,087) | 44.0 (4,087) | 45.5 (4,083) | 44.9 (4,076) |
| Off-peak, seed 316 | 12.2 (2,008) | 5.7 (2,021) | 5.7 (2,021) | 5.5 (2,018) | 5.5 (2,015) |
| Morning holdout, seed 997 | 111.8 (3,889) | 85.1 (3,910) | 85.1 (3,910) | 92.9 (3,900) | 89.2 (3,911) |

- **Final**: every decision and action matches "before" in all four cases. In
  these scenarios a jam deep enough to reach 85 % fullness is always caught by
  the tail rule too, so the reachable occupancy block changes nothing here; it
  matters when a queue fills a link without reaching the junction exit.
- **Graded capacity on**: mixed, −3.9 %, +3.4 %, −3.5 % and +9.2 %. Single runs
  per case; the two morning seeds moved in opposite directions, so this needs
  several seeds per scenario before it is switched on.
- **Slot 45 corrected on the shipped checkpoints**: the policy proposed empty or
  blocked movements far more often (supervisor overrides rose from 31–231 to
  218–853 per run), and the holdout run had 4 collisions, against 0 in every
  other run. Keep `"legacy"` until the models are retrained.

## Current workflow — supersedes the original retrain plan

The 14 November implementation and measured results are in
[`corridor-deployment-validation.md`](corridor-deployment-validation.md).
Training now requires an isolated `--output` directory, attaches the same
`CorridorRuntime` as deployment, seeds every RNG, bounds observations identically,
and checkpoints replay/optimizer/RNG state for complete-episode resume.

Do not change `LINK_OCCUPANCY_FEATURE` globally or overwrite the shipped models.
A new bundle declares its own occupancy scale and hashes all three checkpoints
and the network. Evaluation uses identical route files/seeds for candidate,
shipped and fixed controllers, with crossing and boarding services attached.
Candidates must pass the four audited cases and independent holdouts before
replacement. The historical results below remain evidence about the old runtime;
the new yellow-transition correction changes the comparison baseline.

## First retrain, 13 November 2026: not installed

Trained with the unchanged `train_corridor.py` methodology (fresh, 240
episodes, three-scenario rotation, 125 minutes on the M3), slot 45 and the
spillback reward on fullness. The run's own selection kept episode 216, worst
junction 0.18× its baseline; the shipped run's recorded figure is 0.07×. The
shipped checkpoints were backed up to
`ai/checkpoints/corridor/_v2_legacy_occupancy/` and never overwritten; the
candidates are in `ai/checkpoints/corridor/_v3_fullness/` (gitignored).

Audited cases, mean stopped vehicles (completed trips):

| Case | Fixed timer | Final (shipped) | Retrained | |
|---|---|---|---|---|
| Morning, seed 42 | 117.7 (3,872) | 90.0 (3,884) | 97.7 (3,850) | fails |
| Evening, seed 179 | 83.1 (3,996) | 44.0 (4,087) | 41.3 (4,114) | passes |
| Off-peak, seed 316 | 12.2 (2,008) | 5.7 (2,021) | 5.5 (2,019) | passes |
| Morning holdout, seed 997 | 111.8 (3,889) | 85.1 (3,910) | 83.8 (3,916) | passes |

Five seeds per scenario (11, 42, 137, 1024, 20260610), supervised runtime via
`eval_corridor.evaluate_model`:

| Scenario | Shipped | Retrained |
|---|---|---|
| Morning | 86.0 (81.2–90.2) | 99.8 (95.4–109.1) |
| Evening | 42.7 (38.6–47.7) | 42.8 (37.6–45.6) |
| Off-peak | 5.4 (5.2–5.7) | 5.6 (5.3–5.7) |

The morning loss is not the new spillback penalty holding traffic back at J0:
J0 gave northbound traffic slightly more green (1,742 s vs 1,686 s on seed 42)
and its peak queue fell (169 to 144). The loss is spread across J0, J1 and J2,
which with the weaker selection score points to ordinary training-run variance.
A control retrain on the legacy setting would show how much of the shipped
models' edge any fresh run reproduces. Until a retrained set passes, the
shipped models and `LINK_OCCUPANCY_FEATURE = "legacy"` stay.

## Second round, 13 November 2026: control run and a second corrected run

Two more fresh runs side by side, same methodology (240 episodes, ~126 minutes
each):

- **Control**, the setup the shipped models were trained on: slot 45 legacy and
  `W_SPILLBACK = 0` (before the fix the spillback penalty never fired). In
  `ai/checkpoints/corridor/_v4_control_legacy/`, selection score 0.23×.
- **Corrected #2**: slot 45 fullness, spillback penalty on. In
  `ai/checkpoints/corridor/_v5_fullness_b/`, selection score 0.22×.

Audited cases, mean stopped vehicles (✗ fails the acceptance bar):

| Case | Fixed timer | Shipped | Corrected #1 | Control | Corrected #2 |
|---|---|---|---|---|---|
| Morning, seed 42 | 117.7 | 90.0 | 97.7 ✗ | 85.4 | 113.7 ✗ |
| Evening, seed 179 | 83.1 | 44.0 | 41.3 | 45.5 ✗ | 44.6 ✗ |
| Off-peak, seed 316 | 12.2 | 5.7 | 5.5 | 5.4 | 5.6 |
| Morning holdout, seed 997 | 111.8 | 85.1 | 83.8 | 94.2 ✗ | 79.6 |

Fifteen seeded runs each (five seeds × three scenarios), relative to the
shipped models: control 1.02× on average (better in 7 of 15), corrected #1
1.07× (4 of 15), corrected #2 1.06× (2 of 15). Single runs ranged from 0.89×
to 1.33×. Every fresh set, the control included, had a few collisions in some
2-hour runs (2 per affected run); the shipped models had none.

What this shows:

- **The shipped models are a strong draw.** A faithful re-run of their own
  training setup doesn't reproduce them reliably, so a single retrain is not a
  fair test of any change.
- **The corrected input has not shown a benefit.** Both corrected runs are
  about 4 % behind the control, inside the run-to-run spread but in the same
  direction twice. Slot 45 and the now-active spillback penalty changed at the
  same time, so this does not say which one, if either, costs anything.
- **Nothing was installed.** The shipped models and the legacy setting stay.

To retrain the corridor in future, train several runs at once and choose by
the supervised audited cases and seeded runs above, not the training's own
selection score. Training with `CorridorRuntime` attached (crossing clearance
and boarding), as the control audit recommends, may also remove the collisions
the fresh sets showed.

## Raw results

The per-run JSON behind every table here, the retrains' console logs and the
wrappers that ran them are in `logs/corridor-occupancy-fix-20261113/` (gitignored,
local to this machine). Its README maps each folder to a table column.
