# Corridor handoff review — 16 November 2026

This review updates `docs/corridor-next-session-prompt.md` for the current TrafIQ workspace at `/Users/osborn/Developer/ATCS-GH`. It inspects the other session's design changes and checks whether the control handoff still applies. It does not implement coordination, train models, change traffic physics or replace the visual design.

Evidence is retained in `logs/corridor-handoff-review-20261116-172818/`. That directory contains source hashes, baseline comparisons, complete diagnostic JSON/logs, validation logs and two fresh scene previews. Logs are gitignored; preserve them locally with the other experiment artifacts.

## What changed, and what the agents actually observe

The corridor and single-junction renderers now use metres, exported from their existing SUMO networks. Corridor junction anchors are Z = 0/300/600; lanes, stop bars, crossing widths, full queues and vehicle dimensions share that geometry. The four named town sections are scenery districts around three controlled junctions.

The current scene has deeper shop fronts, verandas and stocked stalls, painted local architecture, mixed metal roofs, office towers, a lorry park, filling stations, a footbridge, more varied trees and street furniture. The latest concurrent design pass adds paved commercial areas alongside laterite neighbourhoods. Fresh aerial and street-level renders show the assembled scene, including the denser shop frontage and varied buildings. Those views are useful appearance evidence; they do not establish live traffic performance or physical sensing accuracy.

These boundaries matter for the next engineering session:

| Visible feature | Current control meaning |
| --- | --- |
| Four town sections and decorative side streets | No additional signal agents or SUMO traffic links |
| Traders, hawkers, parked trotros/taxis and bridge figures | Batched scenery; excluded from vehicle, pedestrian and boarding telemetry |
| Lorry park | Does not create a new `TrotroService` stop |
| Footbridge | Does not replace SUMO pedestrian routes or clearance demand |
| Airport, shops and malls | Do not automatically generate simulated demand |
| TSH-1 heads and K coverage overlays | Display geometry; not a camera/radar perception pipeline |
| Weather, trees and buildings | Do not automatically degrade the TraCI-derived sensor observations |

The actual corridor boarding stops remain at lane position 320 m on `ACH_J0toS` and `ACH_J2toN`. Their configuration matches the previous deployment audit. `TransitLayout.gd` derives metric positions; old display coordinates in the JSON must not be mistaken for current road distances.

For cooperative training, finite sensing range, occlusion, uncertain movements, missing data and message delay still need explicit models and provenance. Improved scenery alone does not make the policy sensor-realistic.

## Workspace and numerical baseline

Verified environment: Python 3.11.16, Torch 2.14.1, NumPy 2.4.6, SUMO/libsumo 1.27.1; scene checks used Godot 4.6.3. The workspace remains substantially modified and untracked. No cleanup, commit or model installation was performed.

The corridor network, routes, stop configuration and all three shipped model hashes match the retained audit. The controller, occupancy implementation, runtime, crossing guard, boarding service and diagnostic script also match. Two control-source hashes differ: replacing the current `TrafIQ` text with `ATCS-GH` reproduces the historical hashes exactly for `ai/corridor_env.py` and `ai/dqn_agent.py`. That accounts for the branding change without assuming that every dirty file affects control.

Three full diagnostic runs used seed 20261121, explicit `legacy` occupancy, graded capacity disabled, and both crossing clearance and transit enabled. `adaptive` means the shipped DQN with its deployed supervisor. Requested duration was 7200 seconds; output includes the initialization step and reports 7201.

| Case | Mean stopped vehicles | Arrivals | Recorded colliding-vehicle count | Teleports |
| --- | ---: | ---: | ---: | ---: |
| Morning, shipped adaptive | 110.0994306 | 3,797 | 2 | 0 |
| Evening, shipped adaptive | 98.8657131 | 3,981 | 0 | 0 |
| Evening, fixed timer | 91.1709485 | 3,953 | 0 | 0 |

All compared traffic metrics matched the retained final audit exactly, including stopped vehicle-seconds, completed/unfinished trip metrics, demand counts, boarding counts and collision details. See `baseline-comparison.json` for the complete comparison. This is three-case equivalence, not a fresh generalization study.

The morning result contains **one vehicle-pair event**, beginning at 3771 s and last seen at 3782 s, on `ACH_J2toJ1_1`, involving `f_N2S.132` and `f_N2W1.26`. The `collisions` field sums SUMO's colliding-vehicle counter and must not be described as two independent crashes. The event remains unresolved; the next session must distinguish minimum-gap infringement from overlap using targeted traces.

The evening tradeoff also remains: adaptive completed 28 more trips but had a higher mean stopped count. The new prompt retains both metrics and requires analysis before training. No new holdout seeds were consumed in this review.

## Checks and concurrent edits

| Check | Result |
| --- | --- |
| Corridor geometry export `--check` | Pass |
| Single-junction geometry export `--single --check` | Pass |
| Deployment contracts | 13 tests passed |
| Corridor controller | 9 tests passed |
| Occupancy | 7 tests passed |
| Godot metric corridor | Pass; complete 40-vehicle queue retained |
| Godot metric single junction | Pass; complete 40-vehicle queue retained |
| Godot city expansion | Pass |
| Godot street details | Fails two legacy ambient-walker expectations; also indexes the empty array |
| Fresh aerial and street-level rendering | Both captured and visually inspected |

The street-details failure is documented in the current design notes. `PedestrianManager._spawn_ambient()` intentionally uses `range(0)` in metric scenes, while the old test expects those synthetic walkers and accesses element zero. The metric single-junction check verifies an actual supplied SUMO sidewalk actor. The next session should reconcile the obsolete test and keep authoritative pedestrian coverage, rather than add fake walkers to satisfy it. This review did not change that test or claim it passed.

The first corridor check overlapped another session's edits: `CorridorBuilder.gd` referenced `CityDistrictBuilder.PAVED` before that constant had been added. Its script failed to load and the test process timed out after 150 seconds. That log is retained as `metric-corridor-during-concurrent-edit.log`. On recheck, the constant was present, the script loaded, and the metric test passed. **This is not an outstanding missing-constant defect in the final checked snapshot.** Visual-source hashes did not change during the final check batch; see `visual-sources-before.json`, `visual-sources-after.json` and `visual-changes-during-recheck.json`.

Godot emitted a macOS CA-certificate warning and occasional ObjectDB cleanup warnings. These are recorded separately from assertion/script failures. Future test runners should enforce timeouts and inspect logs as well as exit codes.

Previews are `views/aerial.png` and `views/apron.png`, captured with `preview_views.gd`. That tool disables the websocket connection and can load a retained crossing replay; it is not live SUMO playback. Its instantaneous render counters are not an FPS benchmark. This review did not repeat the full TSH-1 equivalence suite, all 22 traffic cases, a live socket-TraCI/dashboard test or a physical sensor test.

## Changes to the implementation prompt

The refreshed prompt preserves the original priorities and adds:

- Current metric geometry, scene/data ownership and protection of the new design.
- Stable source manifests and handling of concurrent edits before drawing conclusions.
- Explicit reproduction commands, correct supervised-controller selection and collision-counter interpretation.
- A preflight task for the obsolete ambient-walker test.
- Simulation-time versus wall-clock semantics for communication and live rendering.
- A broader seen-seed ledger, including prior occupancy and sensor experiments.
- Separate headless control benchmarks and actual live-scene acceptance, with truthful dashboard counts.
- Ordered implementation milestones from failure tracing through communication, capacity-aware control, cooperative training and optional asynchronous Ollama.

The numerical problems survive the redesign, so the next session should investigate and implement control improvements against this verified baseline. There is no evidence here that retraining alone will correct them.
