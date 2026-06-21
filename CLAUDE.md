# CLAUDE.md — ATCS-GH project brief (authoritative current state)

> Read this first. It reflects the project as of **2026-06-21** and supersedes
> `README.md` / `plan.md`, which are from April and are now **stale/misleading**
> (they describe emergency priority, all-procedural visuals, and a trained
> corridor — none of which is current).

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
  setbacks + gutters.

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

## Corridor (3-junction, `ai/corridor_env.py`) — code-modernized, NOT trained
Brought in line 2026-06-13 (protected-left 5 actions, emergency removed,
STATE_SIZE 46, per-junction `expert_action`). **Has no trained models.**
Before any corridor retrain it STILL needs: bounded/clipped reward + MAX_QUEUE
raise (its `_compute_local_reward` is still the old unbounded form — flagged
with a NOTE in code), a protected-left corridor baseline, scenario
recalibration, then multi-agent training. It is a separate, currently-unused
module — the single junction is the flagship.

## Git
Default branch `main`; flagship merged via PR #1 (`5eff94f`); v4 (emergency
removal + continuous-day + corridor modernization) merged via PR #2 (`dc5e72a`).
Commit messages end with `Co-Authored-By: Claude ...`. Don't commit model
`.pth` files mid-retrain (best_model.pth is written live during training).

## Queued / TODO
- Corridor full revival (reward redesign → baseline → retrain) — see the
  corridor section above; its `_compute_local_reward` is still unbounded.
- `metrics_logger.py` has self-contained (unused) emergency tracking to clean.
