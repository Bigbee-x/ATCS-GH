# CLAUDE.md — ATCS-GH project brief (authoritative current state)

> Read this first. It reflects the project as of **2026-06-26** and supersedes
> `README.md` / `plan.md`, which are from April and are now **stale/misleading**
> (they describe emergency priority + all-procedural visuals — neither current).
> NOTE: the corridor IS now trained AND fully visualized (see the Corridor +
> visualizer sections); only the README/plan wording is stale, not this file.

## What this is
Adaptive Traffic Control System for the **Achimota/Neoplan Junction, Accra**
(GPS 5.6216 N, 0.2193 W). A **Double-DQN** agent controls the signals in a
**SUMO** simulation; a **Godot 4** app renders it in 3D over a WebSocket.
Founder: Osborn Dogbe (Valiborn Technologies). Motto: "Relax, it works."

## The one-paragraph story (how we got here)
The single junction shipped a working model, then we discovered three real
problems and fixed each: (1) the AI had **all-green phases** that greened the
left arrow against oncoming through traffic → junction-box deadlock; removed →
**protected-left only**. (2) Heavy scenarios were **over capacity** (graded the
AI against an impossible target) → recalibrated to solvable demand. (3) The
reward was **unbounded** (gridlock-trap) → bounded + clipped. Then we built a
**continuous "day"** training profile (realistic ramps + the N→S directional
flip) and **removed the ambulance-priority feature** entirely (it was a
hard-coded override, not learned — removing it makes the AI's results honest).

## Current architecture (single junction = the live system)
- `ai/traffic_env.py` — SUMO env. **STATE_SIZE=41**, **ACTION_SIZE=5**
  (HOLD / NS_THROUGH / NS_LEFT / EW_THROUGH / EW_LEFT — protected-left, no
  all-green). Bounded/clipped reward. `expert_action()` = sustained-green
  protected-left warm-start.
- `ai/dqn_agent.py` — Double-DQN (41→256→256→5), `greedy_action()`, ε-greedy.
- `scripts/train_agent.py` — training. Rotation = continuous_day ×2 + morning +
  evening + weekend. **Maximin best-model selection** (saves on the *worst*
  per-scenario relative wait, baselines floored 60s, ε-gated ≤0.10).
- `scripts/run_baseline.py` — fixed-timer baselines. Use **`--preset protected`**
  (protected-left 4-phase: NS 40/15, EW 25/10) — the realistic benchmark.
- `scripts/_per_scenario_baselines.py` → `data/scenario_baselines.csv` (the
  per-scenario "naive timer to beat", used for grading).
- `scripts/visualizer_server.py` — SUMO↔Godot WebSocket bridge. `--baseline`
  for fixed-timer mode; default = AI (`ai/best_model.pth`); falls back to
  baseline if the model is missing/incompatible.
- `visualizer/` — Godot 4.6.3 project (open + F5; binary at
  `~/Downloads/Godot.app/Contents/MacOS/Godot`). Kenney Car Kit vehicles,
  dual signal heads (horizontal overhead + 2-light pole head), township with
  setbacks + gutters. The corridor scene (`CorridorMain`) now
  matches the single junction: dual signal heads + stretched/widened junctions
  (PR #8), day/night + weather + clouds (PR #10), street lights + utility poles +
  pole sensors (PR #11), lengthened road arms (PR #12), and a **zoned township**
  (PR #13) — `EnvironmentBuilder._build_corridor` (gated by its `corridor_mode`
  export) lays themed districts (homes / offices / industrial / schools /
  hospital / market + a new `_place_airport`) across the flanking blocks, with
  `ResidentialTrafficManager` corridor-mode ambient cars on the south suburb's
  street grid. A free-fly **drone** (press **H**: mouse-look + WASD + Space/Ctrl
  + Shift boost — a small **DJI-style quadcopter** via `DroneController`),
  roadside concrete gutters, and utility poles were added (PR #14; the drone was
  reworked from a helicopter to the small quad in PR #15; sensors mount on the
  actual mast-arm side in PR #17; cars cast real headlight beams in PR #18).
  **PR #19** added brand **billboards** (`BillboardBuilder` — Ghanaian brands +
  Valiborn, emissive/night-glow, road-facing; a sign near a junction sits on the
  cross-street, so place them between junctions), **rebuilt the airport** (KOTOKA
  terminal + tower/beacon + hangar + jets, all clear of the runway), **rebuilt
  the football pitch** (mown stripes + full markings), gave the institutional +
  hospital blocks **keep-clear zones** (generic corridor frontage now skips any
  registered exclusion zone — see `_place_corridor_building`) so they hold a car
  park + trees / a hospital campus + GOIL gas station instead of clutter, and put
  **utility poles on ONE curb** only. **Gotchas:** (1) the corridor junction Z anchors + road-segment +
  arm lengths are TRIPLICATED across `CorridorBuilder` / `VehicleManager` /
  `PedestrianManager` — change in lockstep or vehicles/pedestrians drift off the
  lanes; (2) the south-suburb street grid is duplicated in
  `EnvironmentBuilder._corridor_residential` and `ResidentialTrafficManager.
  _configure_corridor` — keep their coords matched or cars drive off the asphalt.
  (No Godot automation here — parse-check with `Godot --headless --check-only
  --script` + a headless scene-load, then verify visually.)

## Scenarios (`simulation/scenarios/`)
`continuous_day` (the centerpiece — quiet→N-heavy morning→lull→S-heavy
evening→quiet, built by `scripts/build_continuous_day.py`), `morning_rush`
(1901/hr N-heavy), `evening_rush` (2350/hr S-heavy — the hardest sustained
peak), `weekend_market` (E-heavy), `off_peak`. Heavy scenarios were
recalibrated to solvable demand (originals in `scenarios/_pre_recal/`).

## Key facts / gotchas (don't re-learn these the hard way)
- **The junction is asymmetric**: northbound saturates before southbound, so
  morning (N-heavy 1901) and evening (S-heavy 2350) need different demand.
- **All-green phases deadlock the box** — never reintroduce them.
- **Reward must stay bounded/clipped** or heavy traffic hits the gridlock trap.
- **No emergency/ambulance feature anywhere** (removed 2026-06-13).
- The continuous-day model alone **gridlocks a sustained 2-hr evening rush**
  (only saw brief peaks) → that's why training also includes constant
  morning/evening (the "v4" hybrid rotation).
- Models live in `ai/best_model.pth` (deployable) + `ai/trained_model.pth`.
  Backups: `ai/_v1_shipped_5eff94f/` (the merged shipped model),
  `ai/_v3_day_only/` (pure continuous-day). Checkpoints/logs are gitignored.

## Current deployable model (v4 — SHIPPED 2026-06-13)
`ai/best_model.pth` is the hardened continuous-day model (41-dim, protected-left).
**Official greedy eval (full 7200s) beats the protected fixed timer 5/5:**
continuous_day 19.5s (−59%), morning 27.5s (−85%), evening 239s (−44%),
weekend 13.9s (−98%), off_peak 9.1s (−36%). The hybrid rotation + maximin
selection fixed v3's evening gridlock (1084s → 239s greedy). Committed on
branch `feat/emergency-removal-continuous-day`. Re-run anytime with
`python scripts/_eval_best.py`.

## Corridor (3-junction, `ai/corridor_env.py`) — TRAINED + ROTATION-HARDENED (PR #9, #20)
Brought in line 2026-06-13 (protected-left 5 actions, emergency removed,
STATE_SIZE 46, per-junction `expert_action`). **Now TRAINED (PR #9).**
**Phase 0–3 done (2026-06-21, PR #4–#7):** (0) local reward ported to the
bounded/normalised + clipped form (MAX_QUEUE 150/lane 75/wait 1200, REWARD_CLIP
±40); (1) `run_corridor_baseline.py` → protected-left (NS 40/15, EW 25/10,
offset-capable); (2) morning demand recalibrated ×0.65 → 2164 veh/hr (baseline
corridor 143s, J0 276s / J1 77s / J2 76s in `data/corridor_baselines.csv`;
pristine in git history + gitignored `simulation/_pre_recal_corridor/`); (3)
`train_corridor.py` ported to the v4 methodology — per-junction `expert_action`
warm-start (EXPERT_FRAC 0.70), maximin best-model selection over JUNCTIONS
(worst-junction rolling wait ÷ baseline, floored 60s, ε-gated ≤0.10), scenario
rotation. **Phase 4 (2026-06-23, PR #9):** trained on the morning scenario only
→ greedy eval corridor 13.6s vs 143.1s (−90.5%). **ROTATION-HARDENED
(2026-07-01, PR #20):** retrained FRESH on a 3-scenario rotation — morning (S→N
heavy) + evening (N→S flip) + off_peak (light) — generated by
`scripts/build_corridor_scenarios.py` from the morning template, baselined via
`run_corridor_baseline.py --route … --label …` (now writes the CSV: evening
134.8s, off_peak 25.6s). Best saved ep 120 (worst junction 0.07×). Official
greedy eval (`eval_corridor.py` now takes `--route`) beats the protected timer on
all three: **morning 14.0s (−90%), evening 11.1s (−92%), off_peak 3.4s (−87%)** —
more robust than the morning-only model (16.4s evening / 4.7s off_peak).
Deployable models force-tracked at `ai/checkpoints/corridor/best_J{0,1,2}.pth`
(morning-only backup in `_v1_morning_only/`; re-eval per scenario with
`eval_corridor.py --route <scenario>.rou.xml`). Separate module — the single
junction is still the flagship.

## Git
Default branch `main`; flagship merged via PR #1 (`5eff94f`); v4 (emergency
removal + continuous-day + corridor modernization) merged via PR #2 (`dc5e72a`).
Commit messages end with `Co-Authored-By: Claude ...`. Don't commit model
`.pth` files mid-retrain (best_model.pth is written live during training).

## Queued / TODO
- Corridor full revival — **DONE** (Phases 0–4 + visualizer): trained, official
  greedy eval corridor 13.6s vs 143.1s baseline (−90.5%), models shipped (PR #9).
  Optional follow-ups: evening/off-peak corridor scenarios for richer rotation.
- `metrics_logger.py` unused emergency tracking — **DONE** (PR #16): removed
  `EMERGENCY_TYPE` / `emergency_log` / `_track_emergency_vehicles` + the dead
  `run_baseline.py` emergency report block; all call sites updated.
