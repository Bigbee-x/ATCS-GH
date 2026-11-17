# CLAUDE.md — TrafIQ project brief (authoritative current state)

Project branding is **TrafIQ** (renamed from ATCS-GH). The active checkout is
still `/Users/osborn/Developer/ATCS-GH`. Preserve existing versioned sensor
schema IDs and archived experiment/network files; their identifiers and hashes
are compatibility contracts, not display branding.

> Read this first. Active scope was updated **2026-11-16**. The July history
> and benchmark sections below are retained reference; current corridor
> deployment reports and the active-scope section take precedence. Keep this
> brief and `README.md` in sync when scope or architecture changes. `plan.md`
> and `docs/phase1_notes.md` are historical design records.

## Active scope — 16 November 2026

Interface branding is **monochrome with an orange accent**, not green. The
corridor scene uses `CorridorHUD.gd` with collapsible Traffic/Scene/Controls
inspectors; see `docs/corridor-interface.md`. Preserve its measured-data and
selected-junction command contracts. `UI.gd` is legacy single-junction UI.

**N6 corridor only:** J0 Achimota → J1 Asylum Down → J2 Nima. The redesigned
launcher has one corridor launch/resume action; the single-junction experience
is retired from the product. Keep legacy files/checkpoints for historical
reproduction and shared dependencies, not as a new development target.

The policy/runtime is Python + SUMO (`ai/corridor_env.py`,
`ai/corridor_controller.py`, `scripts/corridor_runtime.py`); the three shipped
policies use 46 observations and five actions. Godot is the presentation client.
Read `docs/traffic-observation-contract.md`: artwork, cameras, lighting and
render rate must not influence semantic traffic observations or decisions.
Physical roads, vehicles, pedestrians, signal state and qualified sensor
measurements remain relevant. Real occlusion belongs in the perception model,
not an implicit dependency on a cosmetic scene edit.

For new intelligence work, use `docs/corridor-next-session-prompt.md` and the
latest deployment/review reports. Historical results below do not supersede
known current corridor failures. Launcher checks:
`visualizer/tools/validate_corridor_launcher.gd`; preview:
`visualizer/tools/preview_launcher.gd`. Launch waits for actual traffic data,
keeps failures visible, supports retry/resume, and offers an optional dashboard.

## What this is
TrafIQ is an adaptive traffic-control simulator for the **three-junction N6
Nsawam Road corridor, Accra**. Double-DQN agents and a safety supervisor control
SUMO traffic; Godot 4 renders the corridor over WebSocket.
Founder: Osborn Dogbe (Valiborn Technologies). Motto: "Valiborn Tech. Build Beyond."
The earlier motto, "Relax, it works.", is retired.

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

## Historical single-junction architecture (retained reference)
- `ai/traffic_env.py` — SUMO env. **STATE_SIZE=41**, **ACTION_SIZE=5**
  (HOLD / NS_THROUGH / NS_LEFT / EW_THROUGH / EW_LEFT — protected-left, no
  all-green). Bounded/clipped reward. `expert_action()` = sustained-green
  protected-left warm-start.
- `ai/dqn_agent.py` — Double-DQN (41→256→256→5), `greedy_action()`, ε-greedy.
- `scripts/train_agent.py` — training. Rotation = continuous_day ×2 + morning +
  evening + weekend. **Maximin best-model selection** (saves on the *worst*
  per-scenario relative wait, baselines floored 60s, ε-gated ≤0.10).
- `scripts/run_baseline.py` — fixed-timer baselines. The realistic benchmark is
  the **"protected" preset** (protected-left 4-phase: NS 40/15, EW 25/10) —
  NOTE: it's API-only (`run_simulation(preset="protected")`, used by
  `_per_scenario_baselines.py`); the CLI exposes only `--tuned`/`--scenario`.
- `scripts/_per_scenario_baselines.py` → `data/scenario_baselines.csv` (the
  per-scenario "naive timer to beat", used for grading).
- `scripts/visualizer_server.py` — SUMO↔Godot WebSocket bridge. `--baseline`
  for fixed-timer mode; default = AI (`ai/best_model.pth`); falls back to
  baseline if the model is missing/incompatible.
- Launcher gotcha (PR #21–#22): the Flask dashboard is local **HTTP**; Osborn's
  default browser is Safari with **HTTPS-Only on**, which refuses http:// URLs
  (and resolves localhost→::1 while Flask binds IPv4). So `ServerManager.gd`
  opens `http://127.0.0.1:5050?tab=live` via `open -a` (Chrome first, then
  Brave/Edge/Chromium/Firefox), not the default browser. Keep local web UIs on
  127.0.0.1 + a non-Safari browser.
- `visualizer/` — Godot 4.6.3 project (open + F5; binary at
  `/Applications/Godot 4.6.3.app/Contents/MacOS/Godot`). Kenney Car Kit vehicles,
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
  **Nov 2026**: the pole camera + separate radar are replaced by the **TSH-1 sensor
  head** (radar, wide/tele cameras, thermal) on a band-clamp saddle above the mast arm
  (`SensorBuilder.gd`). `Sensor_CCTV` / `Sensor_Radar` remain as anchors on the head
  so `tools/validate_street_details.gd` and `preview_street_details.gd` still work.
  Each junction has ONE NEMA TS2 signal cabinet (`SignalCabinet_<jid>`: battery backup + 5G
  antenna, beside the south pole on the SE corner, door facing away from the junction) in place of
  the old box at every pole; each pole has a `PullBox`, and **K** also draws the duct runs to the
  cabinet in magenta. Every approach also has a far-side through head + left arrow
  (`SignalHardware.far_side`, `_lights[approach]["far"]`) on the pole at its far-left corner, lit with
  the approach's own state. Each corner pole also carries two ITE pedestrian heads (hand /
  walking person; `shaders/ped_lens.gdshader`), one per crossing at that corner, run by
  `PedestrianSignals.gd`: WALK while SUMO's crossing is green, a flashing hand while walkers are
  still on a crossing after WALK ends (crossing_safety.py holds traffic for them), steady hand
  otherwise. `validate_street_details.gd` checks all of this.
  Filling stations come from `AccraStreetscape.filling_station` (placed by
  `EnvironmentBuilder._place_petrol_station` with a facing, shop side and driveways) and
  carry the project's own "Sankofa" fuel brand, not a real retailer. The single junction's
  station is reached by an access lane off Achimota Forest Rd; stations sit so street lamps
  land on kerb strips, not driveways.
  The football grounds come from `AccraStreetscape.football_ground` (stand on the side away
  from the junction; masts register night lights in `_stadium_lights`), and both scenes'
  utility poles from `PowerLines.gd`. `EnvironmentBuilder._infill_lots` runs just before the
  backdrop: it rasterises everything built so far (kit batches, scene meshes, exclusion
  zones, plots, arterials, airport) and fills what is left with homes, sheds, smallholdings
  and greenery, so anything new must exist (or reserve its zone) before that call. Ground
  shader kinds 7 (mown turf) and 8 (bare laterite) were added for the pitch, tracks and farms.
  **K** now paints each sensor's road footprint (wide camera, thermal, tele, radar) from
  its true field of view, head height and 10° tilt; ranges are shortened to the scene
  (`COVERAGE` in `SensorBuilder.gd`). The drone airframe (`DroneAirframe.gd`) is now a
  compact folding consumer quad: slate fuselage, top battery, staggered front/rear arms,
  short feet and a single-sided 3-axis gimbal. The `animate_flight` API is unchanged, and the
  `RotorBlur` name stays because `validate_drone.gd` skips it in the envelope check.
  **PR #23**: the corridor overview panel (UI.gd) shows per-approach N/E/S/W
  queue mini-bars per junction (severity-colored, wait tooltips) — fed from the
  per-approach `queues`/`wait_times` the server always sent. **PR #24** added a
  green-wave strip (J0—J1—J2 phase dots; links glow when adjacent greens align),
  a live "vs fixed timer" badge (server tags `scenario` + `baseline_wait` in the
  packet; `corridor_visualizer_server.py` gained `--route` for evening/off-peak),
  per-junction phase hold timers, and a rolling veh/min throughput readout.
  **PR #25**: smooth vehicle/ped motion via **snapshot interpolation**
  (`SnapClock.gd` — adaptive playback clock keyed to the packets' authoritative
  `sim_time`, rendering ~1.5 sim-secs behind newest; entities lerp between KNOWN
  snapshots, never extrapolate). This supersedes the reverted April attempt
  (165df1c) which failed by using client *arrival* times — don't retry that.
  Launcher now defaults to **1.5× sim speed** (`ServerManager.DEFAULT_SIM_SPEED`;
  real-time reads slow on the compressed roads); SnapClock auto-adapts to any
  `--speed`. **PR #26**: procedural **traffic soundscape** (`TrafficAudio.gd`,
  auto-attached by VehicleManager in both scenes — 10 doppler-tracked engine
  emitters pitch-following SUMO speeds w/ petrol + trotro-diesel voices,
  congestion-driven stochastic horns, moving-traffic wash bed; drone buzz
  lowered to −16 dB beneath it).
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

## Metric renderers (15 Nov 2026)

This supersedes the historical compressed-corridor geometry notes above.
`CorridorGeometry.gd` reads `visualizer/assets/network/corridor.json` or
`single.json` (its optional `corridor` argument defaults to true), exported
read-only from the existing SUMO network by `scripts/export_corridor_geometry.py`.
One scene unit is one metre; junction Z anchors are 0/300/600. Roads, stop bars,
crossings, vehicles and pedestrians share those coordinates. Do not reintroduce
the old 0/30/60 mapping or truncate queues to fit it. `MetricRoadBuilder.gd`
builds network surfaces; `EnvironmentBuilder._build_metric_corridor` sets scenery.
The single-junction scene also uses its actual network geometry; decorative
neighbourhood/airport layouts remain separate. Export single.json with
`--single`; both exports support `--check`. Main.gd ground navigation uses
metric body/camera dimensions and generated footway collision.

Run exporter `--check` for both modes, `validate_metric_single.gd`,
`validate_metric_corridor.gd`, `validate_zoning.gd`,
`validate_transit.gd`, `validate_crossings.gd` and `validate_live_traffic.gd` for
related changes. Generate crossing replays with `validate_crossing_safety.py`.
On restricted macOS runs, give Godot a writable `--log-file` under `/private/tmp`.
Keys 1/2/3 focus junctions, 0 overview, H drone; flight retains its speed keys.
No SUMO network, route, observation or checkpoint changes were made for this
migration. Full details and limitations: `docs/streetscape.md`.

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
- **SUMO occupancy is already 0–1** (checked on 1.27.1): `getLastStepOccupancy` is vehicle
  lengths ÷ lane length, gaps excluded, and an edge's value also averages its sidewalk lane.
  Read it through `ai/occupancy.py` (`fullness`: vehicle lanes only, 1.0 = bumper to bumper),
  never ÷100. Corridor state slot 45 stays on the old ÷100 scale (`LINK_OCCUPANCY_FEATURE =
  "legacy"`) because the shipped corridor checkpoints were trained on it; switch to
  `"fullness"` only together with retrained checkpoints. See `docs/corridor-occupancy-fix.md`.
- **The shipped corridor checkpoints are a strong draw**: three fresh 240-episode retrains
  (Nov 2026, including a faithful re-run of their own setup) didn't reproduce them on the
  audited cases. Never swap corridor models on one training run; train several and choose by
  the supervised audited cases + seeded runs.
- **TSH-1 sensor interface** (Nov 2026): `docs/tsh1-sensor-interface.md` has the arm-frame
  schema, the slot map and the sensor-range results. The adapter is `ai/tsh1_interface.py`
  (single junction), checked by `scripts/validate_tsh1_interface.py`.
  `ai/tsh1_corridor.py` now provides the 46-slot corridor receiver, ideal emulator
  and wire-only supervisor API; `scripts/validate_tsh1_corridor.py` checks every
  second. Simulator exit occupancy/turn intent are labelled oracles and rejected
  by physical-input defaults. Exact simulator round trips do not prove hardware
  accuracy; range saturation, turn intent, link fusion and physical interlocks
  still need validation.
- **Corridor deployment training (14 Nov):** the `train_corridor.py` CLI now uses
  `train_corridor_deployment.py`, requiring an isolated `--output`. Use immutable
  model manifests, complete-episode resume and matched `validate_corridor_candidates.py`
  audits. Never install a model from training reward alone. Optional version-matched
  `libsumo==1.27.1` runs experiments much faster (`LIBSUMO_AS_TRACI=quiet`); use
  separate processes and keep the live viewer on normal TraCI. Details/results:
  `docs/corridor-deployment-validation.md`.
  Results: six warm-start runs / 72 full episodes / 24 screened snapshots;
  none passed the replacement gate. Calibrated fullness weights reproduce
  shipped traffic outcomes on all 22 cases, but are not promoted. Keep shipped
  weights, legacy slot 45 and graded capacity off. Fresh holdouts exposed a
  minimum-gap event on morning seed 20261121 and worse-than-fixed stopped
  vehicles on evening 20261121; both are now regression cases, not unseen
  promotion evidence. Exact per-case results/model hashes are retained in
  `docs/corridor-deployment-results.json`.
- **Right-turn yellow clearance:** `CrossingSafety` must retain right-turn yellow
  while the straight movement is yellow. Testing only `Gg` there cut right turns
  straight to red and caused emergency braking/minimum-gap collisions. Pedestrian
  occupancy still overrides conflicting movements; protected-left right turns
  remain red.
- **No emergency/ambulance feature anywhere** (removed 2026-06-13).
- **`simulation/intersection.net.xml` is gitignored** — a fresh clone must generate it with
  `python scripts/build_network.py`. That script passes `simulation/connections.con.xml`
  (inner lane = left + u-turn only) so the junction has the 20 signal links `PHASE_SIGNALS`
  expects; without it netconvert makes 24 and SUMO dies with "Mismatching phase size in tls 'J0'".
- The Godot launcher (`ServerManager.gd`) uses `<repo>/.venv/bin/python3` when it exists, then
  the pyenv/Homebrew/system Pythons.
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

## Compact corridor town (16 November 2026)
`CityDistrictBuilder.gd` fills a 368 × 1000 m developed strip around the three
metric junctions. The previous metropolitan sprawl has been replaced with
larger high-street premises, mixed-height corner blocks, shared paved courts,
interior compounds and connected local streets. Reserve those streets before
building the frontage; clip their footways at main and local junctions.
The later section-by-section pass removes the uniform square-lot infill and
town-wide laterite slab. CityDistrictBuilder.sections() describes four bands:
J0–J1 commercial, J1–J2 civic, north of J2 residential/workshops, south of J0
market. UrbanBlockKit composes asymmetric building wings, service canopies,
solar panels, courtyard parking and covered market aisles. Keys 5–8 focus these
sections outside drone mode. Surface kinds 9/10 use non-periodic urban/natural
ground; do not reintroduce a repeated small ground photo over the whole town.
`AirportBuilder.gd` is the active detailed two-stand airport, uniformly scaled
by 1.5. AirportLayout reserves a 144 × 213 m site at (135,50) plus its J0 access
road. The airfield is compressed scenery. Key 4 frames it. Use
validate_city_expansion.gd, validate_airport_weather.gd, validate_zoning.gd and
validate_metric_corridor.gd for current placement checks. Roads still match
SUMO metre for metre; scenery changes do not alter the network or checkpoints.

## Accra street character (16 November 2026)
The earlier scenery read as a tidy temperate suburb (brick-brown blocks, grey
paved courts, lawns, nobody on the roadside). This pass gives the shared kit
and, above all, the **corridor** an Accra look. Roads, lanes, crossings,
footways, signals, stations, vehicles, networks, routes and checkpoints are
untouched. Full notes: the last section of `docs/streetscape.md`.

- **Kit (`AccraStreetscape.gd`)**: painted sandcrete over a darker dado; storey
  buildings with shops under a verandah; lock-up stores with steel doors, stock
  and a signboard each; long-span roofs in oxide red/blue/green/zinc or a flat
  slab with polytank, dish and starter bars; container kiosks; `uncompleted()`,
  `walled_plot()`, `telecom_mast()`, `footbridge()`, `tank_stand()`,
  `banana()`, `yard_parking()`. Trees are mango/neem/almond/flamboyant; palms
  are batched crowns. Shop, church and school names are invented in the style
  of Accra signboards. Keep to invented names and the project's own Sankofa /
  Valiborn brands; no real retailer, telecom or fuel brand.
- **Street life (`AccraStreetLife.gd`)**: umbrella traders, table sellers,
  produce heaps, hawkers with head pans, okadas, hand carts, direction boards,
  the open drain. Batched scenery only, never on a carriageway or footway,
  never counted as SUMO pedestrians or vehicles.
- **Trading apron**: shop fronts stand `_frontage_setback` behind the footway
  (7 m corridor, 6 m single). Lamps and poles keep the first strip, then the
  corridor's drain, then swept earth with traders. `CityDistrictBuilder.
  _reserved()` keeps infill 8.9 m off the arterials for that reason; pass
  `roadside = true` only for boards, riders and shade trees.
- **Corridor landmarks** claim exclusion zones in `_build_metric_corridor`
  before the shop rows: two Sankofa filling stations, a footbridge at z 462
  (piers solid, deck has no collider because it crosses the road), three
  telecom masts, the lorry park beside the market, three metre-scale office
  towers and 16 × 12 m apartment blocks.
- **Ground**: GREEN, by the user's choice on 17 Nov 2026 (asked between the
  red-brown rework and the green ground of PR #29). Kind 3 (single) is
  rainy-season grass, olive where it dries, laterite only in small worn
  patches. Kind 10 (corridor plane, tint `4f6a33`) is green savanna. Inside the
  `town_rect` uniform (frayed edge) it is still mostly grass, worn to swept
  laterite in broad patches. Red earth stays in the roadside aprons, shoulders,
  yards and tracks, and the paved districts stay paved. Do not turn the open
  ground back to red-brown or straw. Kind 11 is blockwork. Kind 0 has a wall
  branch and an upward-face branch: the carriageway mesh uses kind 0, so leave
  the upward branch alone.
- **Gotchas**: (1) `StreetscapeMaterials.solid()` and coloured `surface()`
  materials carry `paint`/`shared` metadata; `_batch()` draws through the
  shared white material with the colour per instance. Do not mutate such a
  material afterwards to restyle batched geometry. (2) Trim emitted between
  `_detail = true/false` casts no shadow and hides beyond 140 m. (3) Earth
  plates thinner than about 2 cm above the ground plane shade dark at a
  distance; the corridor ground no longer casts shadows and shoulders are laid
  in 120 m lengths. (4) Call `set_metric_dimensions()` on a `VehicleActor`
  after assigning its transform, or the scale is lost and the car is toy-sized.
  (5) `validate_street_details.gd` still expects ambient sidewalk walkers that
  the metric migration disabled (`_spawn_ambient` loops over `range(0)`); that
  failure predates this pass.
- `tools/preview_views.gd` renders named camera views of either scene in one
  launch: `-- corridor /abs/out 13 0 "name=px,py,pz>lx,ly,lz@fov" ...`.

## Night, paved districts, lamps and sound (16 November 2026, later pass)
Details in the last section of `docs/streetscape.md`.
- **Night**: `TimeOfDayManager` owns a shadowless `MoonLight` and a brighter
  night ambient; `StreetLamp` has a wide 24 m cone; `LampPools.gd` (corridor)
  is one MultiMesh of additive quads that takes over as lamp spot lights fade
  with distance. Do not lower these back toward black: the user found night,
  and the road above all, too dark.
- **Vehicle lamps**: shared lens materials (off / on / brake), additive halo and
  road-pool meshes via `shaders/vehicle_glow.gdshader`, per-instance `boost`
  for braking. `validate_transit.gd` reads `_lamps` / `_brakes`.
- **Paved districts**: `CityDistrictBuilder.PAVED` (business quarter J0–J1 and
  the mall/bank frontage north of J1) are block-paved and clean; the rest of
  town keeps laterite aprons and worn patches on green ground (see Ground).
  `paved_at()` drives aprons, covered drains, kerbed side streets, tidy courts
  and frontages, and the kit's `clean_rects`. The user wants both kinds of
  Accra visible, not red earth everywhere.
- **Sound**: NO continuous engine, traffic-roar or murmur layer. Two synthesised
  attempts were both heard by the user as a fake engine noise that starts with
  the sim and never stops; do not add one back without real recordings and the
  user's go-ahead. `TrafficAudio.gd` plays only occasional horn taps, night
  crickets and day birds (quiet), owns the `AudioListener3D` and the master
  limiter, and **M** mutes everything. `scripts/build_soundscape.py` writes the
  six WAVs in `visualizer/assets/audio/` (`.gdignore`d, read with
  `AudioStreamWAV.load_from_file`). `AudioManager`'s 110 Hz hum is retired.
- **Drawn window**: `CorridorGeometry.VIEW` (x ±380, z −430…1030) is all the
  corridor scene draws of its 1.5 km approaches; roads, lamps, poles and
  shoulders are clipped to it, forest closes each end
  (`CityDistrictBuilder._road_ends`) and `VehicleManager._get_boundary_fade`
  fades vehicles at its edge. SUMO positions and all counts are untouched. The
  user asked for this because the long roads into nothing looked fake; a queue
  longer than a visible approach continues out of sight by design.
- **Weather** is Clear / Overcast / Rain (indices 0 / 1 / 2). Harmattan was
  removed at the user's request; do not bring it back.

