# Traffic intelligence and visual independence

The active TrafIQ product is the N6 corridor: J0 Achimota, J1 Asylum Down and
J2 Nima. Single-junction code and checkpoints are retained as historical and
shared dependencies; they are not a second active product.

## The boundary

The signal controller consumes traffic meaning, not the appearance of the town:

- Versioned lane topology, direction, length, permitted movements, crossings,
  stop lines and receiving-road capacity.
- Vehicle counts, queues, speeds, waiting, arrivals, discharge and boarding
  disruption, with explicit units and measurement ownership.
- Actual pedestrian demand, crossing occupancy and clearance requirements.
- Actual signal state, elapsed simulation time and legal transitions.
- Qualified sensor estimates and neighbour messages, including timestamps,
  uncertainty, freshness and missing-data indicators.

In the current implementation, SUMO/TraCI supplies the traffic and the Python
runtime supplies control. Godot consumes their state to draw the scene. The
TSH-1 adapters reconstruct observations from sensor-style frames; the displayed
heads and K coverage overlays are not an implemented vision/radar pipeline.
The current 46-input checkpoint ABI is unchanged by the launcher redesign.

Materials, roof styles, decorative buildings/actors, landscaping, sky, camera
position, drone movement, detail level and rendering frame rate must not enter
policy observations, rewards, vehicle physics or decision timing. The new
launcher's route diagram is static orientation, not simulated live telemetry.

The lorry park's parked trotros, roadside traders and footbridge figures must
not become traffic counts. A decorative back street is not a new network edge.
Four scenery districts do not mean four agents. Store and test physical map
geometry separately from the exported/rendered representation.

## What must remain sensitive to change

Visual independence does not mean ignoring road users or real-world constraints.
A physical lane closure, altered road capacity, changed crossing, actual boarding
service or observed pedestrian changes the traffic problem and must reach the
controller through the appropriate versioned interface. Changing those inputs
requires new matched evaluations; it is not a cosmetic edit.

If real or rendered-camera perception is later introduced, it must extract the
same semantic traffic quantities. Real occlusion, poor visibility, missed
tracks and uncertainty belong in that perception interface. They cannot be
wished away to preserve decisions. Train and test perception across appearance
changes; keep the controller separate, with explicit quality/freshness and a
defined local fallback. An ideal SUMO detector is a labelled research reference,
not evidence of physical sensing accuracy.

## Required acceptance contract for the next intelligence implementation

Given the same ordered traffic observations, neighbour messages, simulation
clock, controller/model configuration and random state, the action sequence
must be identical with Godot absent, with a different camera, or after purely
cosmetic changes. Verify this using an observation/message replay through the
actual policy and supervisor. Compare complete actions, legal transitions and
safety overrides, not only a final score. This replay regression is a required
handoff milestone, not a claim that a new perception system already exists.

Use simulation time for deterministic control/sensor cadence and message expiry.
Track wall-clock stream freshness and processing latency separately. A slow
renderer, reconnect, paused view or open dashboard must not modify the traffic
policy's clock or create observations. Headless benchmarks remain available
while the city is being redesigned.

Keep distinct manifests for traffic/control dependencies and presentation.
Experiment caches must include semantic maps, demand, services, sensor schemas,
estimators, controllers, messages, seeds and models. Unrelated material edits
should not invalidate numerical control results; a changed perception model or
physical map must. If another session is editing dependencies, record a stable
snapshot before interpreting test results.

## Current launcher and validation

F5 opens a corridor-only lobby with launch/resume, an optional browser dashboard,
actual process/startup status, session stop and logs. It opens the corridor only
after the existing server readiness check receives traffic data. It makes no
unmeasured throughput or agent-coordination claims. Legacy source files were
preserved; the shell launcher also defaults to the corridor backend.

`visualizer/tools/validate_corridor_launcher.gd` checks corridor dispatch,
readiness, duplicate-launch protection, failure/retry, resume, dashboard choice,
stop and responsive layout using a fake service (no live traffic). The preview
tool renders the actual lobby at desktop and compact sizes. The isolated live
socket-TraCI check also passed: 74 rendered vehicles, 73 moving, two observed
signal phases, fresh supervisor data and signal/playback agreement. Evidence is
in `logs/corridor-launcher-20261116/`; its temporary server was stopped after
the check. This startup check does not resolve the known two-hour control
failures recorded in the deployment audit.

The engineering sequence remains diagnosis → communication/capacity-aware
control → independent evaluation → justified cooperative training. The detailed
instructions are in `docs/corridor-next-session-prompt.md`.
