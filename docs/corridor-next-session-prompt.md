You are taking over engineering work on my TrafIQ traffic simulation. Work in the existing local project at:

/Users/osborn/Developer/ATCS-GH

The N6 three-junction corridor is now the sole active simulation product. The single-junction experience is retired from the launcher and is not a development or training target; retain its files only for historical evidence and shared compatibility. My priority is effective, reliable corridor traffic control, eventually using TSH-1 roadside sensors. Implement and validate the next stage: diagnose the remaining failures, enable useful communication between neighbouring junctions, benchmark coordinated control, and train a replacement policy only against a sound observation/control design. Evaluate Ollama as an optional analytical assistant. This is an implementation task, not just a request for advice or a research proposal.

Work autonomously through the feasible implementation and experiments. Give concise progress updates with findings and decisions. Ask only for material missing information you cannot recover from the repository. Keep a persistent progress note so work can continue across context limits. Do not promise a performance improvement before measuring it.

Handoff refreshed on 16 November 2026 after reviewing the metric-road migration and the latest Accra streetscape work. The two documented control failures were reproduced on the current runtime; visual improvements have not resolved them. Preserve the new design while doing the engineering below.

1. Start from the actual workspace

This repository contains substantial modified and untracked work, including sensor interfaces, controller fixes, dashboards and visual improvements. Nothing from the previous investigation was committed. Inspect git status and applicable AGENTS.md instructions first. Preserve existing work. A clean checkout or new worktree will omit important files unless you deliberately carry the current working state into it. Do not reset, clean, overwrite or discard changes. Do not commit, push or deploy to physical traffic hardware.

Read these sources before redesigning anything:

- /Users/osborn/Developer/ATCS-GH/CLAUDE.md
- /Users/osborn/Developer/ATCS-GH/docs/corridor-handoff-review-20261116.md
- /Users/osborn/Developer/ATCS-GH/docs/traffic-observation-contract.md
- /Users/osborn/Developer/ATCS-GH/docs/corridor-interface.md
- /Users/osborn/Developer/ATCS-GH/docs/streetscape.md (especially the metric migration and latest Accra street-character sections)
- /Users/osborn/Developer/ATCS-GH/docs/corridor-deployment-validation.md
- /Users/osborn/Developer/ATCS-GH/docs/corridor-deployment-results.json
- /Users/osborn/Developer/ATCS-GH/docs/corridor-occupancy-fix.md
- /Users/osborn/Developer/ATCS-GH/docs/corridor-control-audit.md
- /Users/osborn/Developer/ATCS-GH/docs/tsh1-sensor-interface.md

The private Claude canvas is not required; the local TSH-1 document replaces it. Treat historical write-ups as evidence about the runtime that produced them, not necessarily the current code. Verify important claims against code and retained results.

Current simulation contract:

- The renderer now uses one Godot unit per metre, with J0/J1/J2 at Z = 0/300/600. The four town sections are visual districts, not four signal agents. Read `CorridorGeometry.gd`, `TrafficLayout.gd`, `MetricRoadBuilder.gd` and the exported network JSON before touching position, distance, capacity, camera or queue logic. Do not restore the historical compressed 0/30/60 layout. Keep complete queues and actual vehicle dimensions; `set_metric_dimensions()` must run after assigning the vehicle transform.
- SUMO owns the traffic network, vehicle dynamics, routes, crossings and active demand. The decorated back streets and airport are not additional simulated traffic links. Do not infer receiving capacity from a wide-looking mesh or add shopping/airport demand because a building is visible. Any deliberate network/demand change requires a separate version and matched reruns of every comparator.
- Preserve the redesigned shops and trading aprons, paved commercial districts, laterite neighbourhoods, local roofs and vegetation, towers, filling stations, lorry park, footbridge, airport, drone and weather. Read `AccraStreetLife.gd`, `CityDistrictBuilder.gd`, `UrbanBlockKit.gd` and `EnvironmentBuilder.gd` when a control change touches their interfaces. Shared batched materials must not be mutated per instance.
- Traders, street-life figures, parked trotros/taxis and bridge figures are scenery. They are not sensor observations, SUMO actors, completed trips or boarding passengers. The new lorry park is not a new stop in `TrotroService`; the footbridge is not a routed SUMO crossing replacement. Preserve actual pedestrian clearance and boarding. The existing corridor boarding stops remain on ACH_J0toS and ACH_J2toN, at lane position 320 m, off the short inter-junction links. Derive renderer positions through `TransitLayout.gd`; legacy display coordinates in `stations.json` are not authoritative distances.
- TSH-1 heads and the K coverage view are visualizations, not a rendered-camera/radar detector. Current policies consume TraCI-derived data or explicitly constructed sensor frames. Buildings, bridge occlusion, rain and darkness do not currently change the policy's measurements automatically. Model finite visibility and uncertainty explicitly; do not claim physical or vision robustness from a more realistic scene. A future image-perception experiment needs a separate measured/ground-truth interface and its own validation.

Record hashes and timestamps of relevant source, maps, routes, stops, schemas and checkpoints before testing. Another design session was actively writing files during the 16 November review: an initial missing-`PAVED` parse error disappeared after its edits completed, and the final metric checks passed. Do not treat a partially written scene as a stable regression, overwrite another session's changes, or combine results across changing control inputs. Recheck dependencies after each test batch; rerun affected checks against a stable snapshot. Preserve incomplete-run logs with their provenance.

Preflight must run the corridor geometry-export `--check`, metric corridor, launcher and city-layout checks. The single-junction product is retired: only run its compatibility checks if a shared module change requires them; do not spend this task reviving its UI or training. Inspect script errors as well as exit codes; a failed Godot coroutine can leave a process running. Use bounded test subprocesses and writable log files. `validate_street_details.gd` currently fails its two ambient-walker expectations and then indexes an empty array, while metric scenes deliberately disable those decorative walkers. Reconcile the corridor portion of this obsolete test with the intended metric contract and retain meaningful checks for actual SUMO sidewalk/crossing actors; avoid expanding work into the retired single-junction experience. Do not enable synthetic walkers just to make the old test pass, or suppress unrelated failures. This test issue is separate from the two control failures.

Visual independence is an explicit acceptance requirement. Follow `docs/traffic-observation-contract.md`: agents operate on versioned road topology/capacity, vehicle flows, pedestrian demand/clearance, actual signal state and qualified sensor measurements. Materials, building styles, decorative actors, camera position, drone motion, lighting, LOD and render frame rate must not alter those observations, rewards or action timing. With identical ordered observations, neighbour messages, simulation times and RNG state, the controller must produce identical actions with Godot absent or visually restyled. Add a replay regression that verifies this boundary and keep experiment-cache dependencies on semantic inputs, not unrelated artwork.

Distinguish cosmetic edits from physical changes. A real lane closure, changed crossing, new boarding service or detected pedestrian is relevant and must reach the controller through the versioned traffic/sensor interface. If a camera/radar perception layer is later introduced, its measured occlusion and uncertainty are relevant too; do not fake perfect visibility. Train that perception layer for appearance robustness and pass semantic estimates plus confidence/freshness to the controller. Never feed scene decoration IDs or rendered building counts into the signal policy. The simulator must remain operable and benchmarkable headlessly during large art updates.

2. Understand the established findings

- The corridor is J0, J1 and J2. Current agents use 46 observations and five actions. They already receive each neighbour's aggregate queue and phase in slots 41–44. There is also an offset-based green-wave reward. This is limited simulator state sharing, not a richer communication protocol with arrival forecasts and service intentions.
- SUMO lane/edge occupancy was incorrectly divided by 100. The physical occupancy/spillback calculations now use the correct fraction and vehicle-lane fullness. The shipped model's slot 45 deliberately retains its legacy scale because its weights were trained on that scale.
- A calibrated weight conversion for corrected slot 45 reproduces the shipped traffic outcomes in all 22 audited cases. This is a unit conversion, not new learning or proof of robust control.
- Six warm-start runs completed 72 full two-hour episodes; 24 snapshots were screened. Four conservative candidates passed the first three cases but failed morning seed 997. No replacement was promoted. These results do not prove all RL approaches will fail.
- Graded exit capacity remains disabled because it caused material regressions. Merely turning that switch on is not a solution.
- A real guard defect was fixed: right-turn yellow was being changed directly to red during the straight yellow phase. Preserve the correction and its regression test. Occupied pedestrian crossings still require clearance protection.
- The expanded audit still found a minimum-gap event in morning seed 20261121 at 3771 s on ACH_J2toJ1_1, involving f_N2S.132 and f_N2W1.26. Distinguish SUMO minimum-gap events from physical vehicle overlap; neither should be hidden by changing reporting thresholds.
- In evening seed 20261121, shipped adaptive control recorded 98.87 mean stopped vehicles versus 91.17 for the fixed timer, although it completed more trips. Diagnose that tradeoff rather than reporting only the favourable metric.
- The 16 November review reran these cases with clearance and transit enabled, legacy slot 45 and graded capacity disabled. Morning adaptive returned the same event and 3,797 arrivals; evening adaptive/fixed returned 3,981/3,953 arrivals. All selected traffic metrics matched the retained final audit exactly. The network, stops, routes and model hashes match; the only differences in the audit's control-source fingerprint are the TrafIQ text rename in `corridor_env.py` and `dqn_agent.py`. This does not certify other scenarios or explain the remaining causes.
- TSH-1 corridor reconstruction passed 129,618 exact input-vector comparisons, 64,809 supervisor-observation comparisons and 12,960 decision comparisons across three ideal-emulator scenarios. These establish software equivalence, not physical sensing accuracy.
- Ideal receiving-road occupancy and turn intent are explicitly labelled SUMO oracles. Physical-input defaults reject them. A 200 m head cannot silently claim complete 1.5 km lane or exit measurements. The historical single-junction 1.71 m/s estimate error was measured at five-second estimator cadence, not the intended 1 Hz hardware cadence.

Protect the shipped files under /Users/osborn/Developer/ATCS-GH/ai/checkpoints/corridor/. Their SHA-256 hashes at handoff are:

J0: 7b513242c875664fa075da2b20d5f4b3675183ba4c484f32569d98a900beb274
J1: 2b666ee825e77a3f7949499c46a362d3d37c83cfd034bebe71c696e11c0004c3
J2: 82fc7626de34230fb5b092c7f645f994c9c0f83c20fc3657fc2f69554399e40a

3. Diagnose the remaining failures before broad retraining

Reproduce the known morning/evening failures with exact routes, seeds, model hashes and service settings. Capture a useful interval before and after each failure: observed lanes and intended movements, positions, speeds, gaps, leader braking, requested/actual signal states, pedestrian occupancy, boarding events, receiving capacity, policy proposals and supervisor overrides.

Use `--controller adaptive` for the shipped supervised DQN; the diagnostic script's default `dqn` bypasses that supervisor and is not the audited comparator. From the project root, create a fresh output directory and use these explicit settings:

```sh
LIBSUMO_AS_TRACI=quiet OMP_NUM_THREADS=1 .venv/bin/python3 scripts/diagnose_corridor.py --controller adaptive --route corridor_routes.rou.xml --duration 7200 --seed 20261121 --clearance --transit --occupancy-feature legacy --no-graded-exit-capacity --output YOUR_NEW_RUN_DIR/adaptive-morning.json
LIBSUMO_AS_TRACI=quiet OMP_NUM_THREADS=1 .venv/bin/python3 scripts/diagnose_corridor.py --controller adaptive --route corridor_routes_evening.rou.xml --duration 7200 --seed 20261121 --clearance --transit --occupancy-feature legacy --no-graded-exit-capacity --output YOUR_NEW_RUN_DIR/adaptive-evening.json
LIBSUMO_AS_TRACI=quiet OMP_NUM_THREADS=1 .venv/bin/python3 scripts/diagnose_corridor.py --controller fixed --route corridor_routes_evening.rou.xml --duration 7200 --seed 20261121 --clearance --transit --occupancy-feature legacy --no-graded-exit-capacity --output YOUR_NEW_RUN_DIR/fixed-evening.json
```

Replace `YOUR_NEW_RUN_DIR` with an actual new directory; do not overwrite prior results. The diagnostic output includes the initialization step (duration 7201). Its `collisions` field accumulates SUMO's colliding-vehicle count, not unique events: the morning result is 2, with one recorded vehicle-pair event spanning 3771–3782 s. Preserve both raw counts and event details. The existing 300-second summary series is insufficient for root-cause analysis: add targeted per-step tracing around the event and the periods of evening queue growth.

Determine whether the causes lie in vehicle following/lane changes, crossing or yellow logic, short-link blockage, fairness overrides, reward design, perception assumptions, or interactions among them. Use controlled ablations to separate these causes. Do not assume every failure belongs to the neural network. Do not disable crossing protection, collision detection, boarding, traffic demand or difficult seeds to obtain a better result. If a physics defect requires a correction, rerun every comparator under the same corrected physics and keep the previous evidence.

4. Implement explicit neighbour communication

Start with J0 <-> J1 <-> J2. Use structured, versioned messages and a transport abstraction. A deterministic in-process broker is sufficient for the first simulator implementation; controllers must consume messages through that interface rather than secretly reading neighbour environment internals. Avoid unnecessary distributed infrastructure until its behaviour is proven.

Publish at approximately 1 Hz, retaining the existing five-second decision cadence initially. Define units, ownership and quality for:

- Junction/session identity, sequence number, sample and receive times, schema/map version, expiry and measurement confidence.
- Per-movement queues and waits, observed inflow/outflow, and receiving-lane capacity/blockage.
- Approaching vehicle groups: estimated count, direction, arrival time/window and uncertainty.
- Actual phase, elapsed time, earliest legal transition and tentative next service window. An adaptive timing intention is not a guaranteed future green.
- Relevant pedestrian clearance and trotro boarding disruptions.
- Whether each field is measured, estimated, fused, unavailable or simulator-only.

Specify deterministic update ordering so one junction does not see another's future action in the same tick. Test delayed, dropped, duplicated, reordered and stale messages, as well as a neighbour restart. Expired/unknown capacity must not become an invented zero queue or unlimited space. Each junction needs a defined local fallback when coordination information is unavailable; communication loss must not hang the simulation or violate signal transitions.

Prevent double counting when two heads observe the same connecting road. Derive travel-time estimates from observations and mapped geometry. Do not invent arrival counts or use hidden SUMO routes/speeds while presenting them as deployable sensor data.

Use simulation time for deterministic sensing, expiry, travel windows and control, and record wall-clock delivery/processing latency separately for live operation. The denser scene can reduce rendering frame rate; neither frame rate nor websocket reconnect time should change simulated message age or policy cadence. Define behaviour for a paused simulation and a new run/session explicitly.

5. Benchmark a coordinated controller before selecting a new learning algorithm

Implement a transparent controller that considers upstream demand and downstream finite road capacity, such as capacity-aware max-pressure control. Account for switching losses, minimum greens, yellow/clearance, pedestrians and bounded service fairness. Explain its scoring and arbitration in code and telemetry. Ordinary max-pressure theory alone is not proof of safe or optimal behaviour on short links with spillback.

Compare, under identical conditions:

- Fixed timer.
- Shipped supervised DQN.
- The new capacity-aware controller without explicit predictive coordination.
- The same controller with neighbour communication and arrival estimates.

This comparison must establish what communication actually contributes. Preserve local safeguards regardless of which controller proposes a phase. Keep the new modes selectable for experiments; do not silently replace the default controller before evaluation.

6. Train cooperative agents against the validated design

Use the baseline results and failure analysis to choose a focused cooperative-learning experiment. Consider a neighbour-aware DQN/graph approach or centralized training with decentralized execution; do not assume a named algorithm is automatically superior. Review relevant primary research and explain the choice against this small three-junction topology and local compute budget.

If the observation vector or action semantics change, version the schema, normalizers, freshness masks and model manifest together. Do not append fields to the old 46-value vector and load incompatible weights. Preserve compatibility for the shipped models.

Use the actual deployed runtime during training, including crossing clearance, boarding, supervision and communication effects. Train on realistic sensor-visible information or explicitly labelled estimates, with the intended 1 Hz sensing cadence, communication delay/loss and sensor uncertainty. Keep an ideal-SUMO ablation separate. Account for uncertain turn intent and finite visibility; do not claim that the present ideal emulator already solves them.

Design rewards and evaluation around corridor outcomes: delay/stopped vehicle-seconds, completed and unfinished trips, spillback, fairness and pedestrian waiting. Do not reward moving a queue into a neighbouring junction or maximizing phase-offset agreement regardless of actual flow. Compare multiple seeded training runs against a matched control. Use isolated checkpoint directories, reproducible seeds, bounded resource use and complete resume state. Record the experiment plan and training budget before launching batches, and stop unpromising variants based on declared screening criteria.

7. Keep Ollama optional and outside signal authority

Ollama is a model runtime, not the communication protocol or an automatic replacement for the traffic policy. If available locally, implement an optional asynchronous, read-only analytical component that can summarize measured congestion, explain recorded controller decisions and flag incidents. Every explanation must reference the actual run, junction and observation times and distinguish measured facts from hypotheses.

It must have timeouts and validated outputs. Slow or failed inference must have no effect on simulation stepping or signal decisions. It cannot directly set phases, override clearance, invent sensor values or become a dependency of the core controller. If Ollama or a suitable model is unavailable, complete the main work and document the optional integration without blocking it. A later LLM controller experiment, if justified, belongs in simulation/shadow mode and must undergo the same benchmarks; do not connect it to physical signals.

8. Evaluate without leaking the test set

The old audit cases are morning 42, evening 179, off-peak 316 and morning 997. The scenario-wide seeds 20261114/20261115/20261116 and 20261121/20261122/20261123 have all now been inspected. They are regression cases. The older occupancy study also inspected 11/42/137/1024/20260610; sensor studies used 20260610/42/271/503. Build a seen-seed ledger from retained reports, run manifests and results, including training and tuning seeds; do not assume this paragraph is exhaustive. The current evaluator still calls 20261121–23 HOLDOUT; update the bookkeeping so a label does not falsely imply independence. The 16 November review used only existing regression cases, not a new test set.

Before choosing a winning controller/model, reserve a genuinely new seed set, preferably at least five seeds per scenario, and keep it out of training and model selection. Fix the candidate before opening final results. If you tune against a failed holdout, reclassify it as regression data and reserve another untouched set. Add targeted cases for spillback, heavy pedestrians, boarding, restricted visibility and communication faults.

Use matched routes/seeds, duration, vehicle physics, detector assumptions, service settings and safety rules for all comparators. Report per-case outcomes, averages, worst cases and uncertainty where justified. Keep completed-trip statistics separate from unfinished demand and use consistent denominators. Cache reuse must depend on all relevant code, schema, model, network, route and configuration versions.

Separate control benchmarks from visual/live acceptance. Run deterministic control comparisons without Godot; then verify actual socket-TraCI playback, signal agreement, queue positions, boarding and dashboard counts in the updated scene. A static preview or recorded replay is not a live integration test. Record render frame time, stream freshness and controller inference latency separately. Keep render/perception provenance distinct from the numerical control cache; include all new broker, estimator, sensor-adapter and schema sources in experiment fingerprints. Decorative actor counts must never inflate live telemetry.

Retain the existing replacement requirements: zero recorded collisions/teleports, no stopped-vehicle regression on the required audited cases, at least 99.5% of shipped completions, and better performance than the matched fixed timer. Require independent holdout evidence, acceptable pedestrian/fairness outcomes and communication-failure behaviour as well. Do not silently loosen a gate after seeing the results. A screening pass or one JSON `eligible` flag does not authorize promotion. If the defined gates are unmet, keep the active model, report the specific failures and leave the tested alternative reproducible.

9. Use the existing implementation and experiment tools

Core code to inspect:

- /Users/osborn/Developer/ATCS-GH/ai/corridor_env.py
- /Users/osborn/Developer/ATCS-GH/ai/corridor_controller.py
- /Users/osborn/Developer/ATCS-GH/ai/corridor_bundle.py
- /Users/osborn/Developer/ATCS-GH/ai/occupancy.py
- /Users/osborn/Developer/ATCS-GH/ai/tsh1_interface.py
- /Users/osborn/Developer/ATCS-GH/ai/tsh1_corridor.py
- /Users/osborn/Developer/ATCS-GH/ai/tsh1_schema.py
- /Users/osborn/Developer/ATCS-GH/scripts/corridor_runtime.py
- /Users/osborn/Developer/ATCS-GH/scripts/crossing_safety.py
- /Users/osborn/Developer/ATCS-GH/scripts/trotro_service.py
- /Users/osborn/Developer/ATCS-GH/scripts/train_corridor_deployment.py
- /Users/osborn/Developer/ATCS-GH/scripts/diagnose_corridor.py
- /Users/osborn/Developer/ATCS-GH/scripts/validate_corridor_candidates.py
- /Users/osborn/Developer/ATCS-GH/scripts/corridor_visualizer_server.py

Use /Users/osborn/Developer/ATCS-GH/.venv/bin/python3. The recorded environment is Python 3.11.16, Torch 2.14.1, NumPy 2.4.6 and SUMO/libsumo 1.27.1; verify it. LIBSUMO_AS_TRACI=quiet enables the fast experiment backend. Full morning/evening traffic outcomes previously matched socket TraCI. Run simultaneous libsumo simulations in separate processes, with sensible CPU/RAM limits. Use actual TraCI for the final live-server smoke test. Do not kill unrelated listeners or the user's Godot editor.

Retained results: /Users/osborn/Developer/ATCS-GH/logs/corridor-deployment-20261114/
Prior checkpoints: /Users/osborn/Developer/ATCS-GH/ai/checkpoints/corridor/_deployment_20261114/
Older occupancy study: /Users/osborn/Developer/ATCS-GH/logs/corridor-occupancy-fix-20261113/
Current handoff review: /Users/osborn/Developer/ATCS-GH/logs/corridor-handoff-review-20261116-172818/ (source hashes, three reproduced cases, check logs and two static scene previews)

Logs/checkpoints are gitignored but present locally. New runs need new output directories. Preserve the old artifacts. Resume must respect source/data/parent-model fingerprints; use a new warm-start run when conditions change.

Run relevant existing checks, including:

- /Users/osborn/Developer/ATCS-GH/scripts/validate_deployment_contracts.py
- /Users/osborn/Developer/ATCS-GH/scripts/validate_corridor_control.py
- /Users/osborn/Developer/ATCS-GH/scripts/validate_occupancy.py
- /Users/osborn/Developer/ATCS-GH/scripts/validate_crossing_safety.py
- /Users/osborn/Developer/ATCS-GH/scripts/validate_tsh1_corridor.py
- /Users/osborn/Developer/ATCS-GH/scripts/export_corridor_geometry.py --check
- /Users/osborn/Developer/ATCS-GH/visualizer/tools/validate_metric_corridor.gd
- /Users/osborn/Developer/ATCS-GH/visualizer/tools/validate_corridor_launcher.gd
- /Users/osborn/Developer/ATCS-GH/visualizer/tools/validate_city_expansion.gd

Run Godot tools using `/Applications/Godot 4.6.3.app/Contents/MacOS/Godot --headless --path visualizer --log-file /private/tmp/UNIQUE_NAME.log --script res://tools/TOOL_NAME.gd`. Give each run a distinct log. Use a rendering display for visual previews; do not count headless tests as image inspection. The review observed the macOS CA-certificate warning and occasional ObjectDB shutdown warnings; report script/assertion failures separately instead of ignoring every line labelled ERROR.

Extend them with meaningful communication, coordination, schema, fallback and causality regressions. Preserve the live dashboard's truthful measurements, the corridor HUD's monochrome/orange theme and its collapsed-by-default inspectors, and the existing streetscape, drone, airport and weather work. Use `CorridorHUD.gd` for active corridor UI changes; `UI.gd` is legacy. Retain explicit junction targeting, stale-data command guards and server acknowledgements. Only add focused coordination telemetry if useful: message age, predicted arrivals, downstream capacity, selected strategy, overrides and actual measured outcomes.

10. Deliver working code and evidence

Produce a root-cause report for the known failures, a versioned neighbour-message contract, working coordinated control, seeded comparison results, the justified cooperative-training experiment, and an optional Ollama adapter when feasible. Provide runnable commands, model/config hashes, source provenance, all failed as well as successful cases, and a clear selected/retained-model decision.

Update /Users/osborn/Developer/ATCS-GH/CLAUDE.md and the appropriate project documentation with the final state and remaining limits. Separate simulator evidence from physical deployment readiness. Hardware sensing, conflict monitoring, approved controller transitions and field validation cannot be certified by these experiments.

Carry the work through these milestones, recording evidence and remaining failures at each boundary:

- M0: establish a stable workspace manifest, validate the corridor launcher and metric/render contract, reconcile the corridor ambient-walker test, and reproduce both known control failures with targeted traces.
- M1: diagnose and correct confirmed runtime defects, then rerun matched regression comparators. Keep unexplained policy failures visible; do not wait for retraining to investigate them.
- M2: implement and test the versioned neighbour broker, causal update order, finite-capacity controller, coordination ablation and local fallbacks.
- M3: benchmark all four comparators on regression/tuning cases, freeze the candidate and evaluate untouched seeds. Report capacity, fairness, pedestrian and fault outcomes as well as throughput.
- M4: train the justified cooperative variant with the validated runtime and realistic sensor contract; assess it against the same gates using independent evaluation data. Retain shipped models if it fails.
- M5: complete optional asynchronous Ollama analysis and the actual live-scene/dashboard acceptance check. Neither optional model availability nor cosmetic polishing should block the core engineering.

Begin with M0. Implement the communication-and-coordination milestone and carry it through matched tests before broad training; do not stop after describing an architecture.
