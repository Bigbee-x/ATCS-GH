# Live traffic dashboard

Open `http://127.0.0.1:5050/` after starting a simulation from Godot. The dashboard follows the latest running traffic server for this project. Training and evaluation CSV reports remain at `/analytics` and are not used to populate live metrics.

The dashboard uses the same WebSocket packets as the 3D viewer. Both single-junction and corridor servers publish measured telemetry after each SUMO step, including a session ID, run ID, simulation timestamp and source. The display does not generate sample traffic, estimate missing counts, or substitute historical benchmark scores.

## What the numbers mean

| Metric | Source and definition |
| --- | --- |
| Active vehicles | All vehicles returned by SUMO's vehicle list, including junction interiors and parking bays. |
| Stopped vehicles | SUMO halting counts on the junctions' incoming edges, using its below-0.1 m/s threshold. This is not every stationary vehicle in the whole town. |
| Current mean wait | Sum of current vehicle waiting counters on incoming edges divided by **all vehicles** on those edges. Junction means are weighted by their vehicle counts. This is not completed-trip delay or an episode score. |
| Completed trips | SUMO arrivals accumulated through the current simulation second, including arrivals between AI decision steps. |
| Observed throughput | Difference in completed trips across at least 60 observed simulation seconds, expressed as trips per minute. The actual measured interval is displayed. No value is shown during initial warm-up. |
| Approach demand | Measured stopped counts and current mean waits for each incoming road. Bar lengths compare the four observed queues; they do not claim road capacity. |
| Signal heads | Actual main, left-turn and pedestrian aspects from the crossing-safety signal snapshot. A left arrow is green or unlit, matching the 3D signal hardware. Colors are not inferred from the requested controller phase. |
| AI explanation | Reported supervisor reason, proposed/applied action, detector sample time and decision time. No explanation is invented when a controller does not provide one. |

Charts contain observations received by the browser, with 5/15-minute simulation-time windows. Same-time vehicle/state packets replace one sample instead of creating duplicates. Disconnects leave chart gaps; a new run resets history. Export includes up to 30 simulated minutes of the browser's observed measurements, with missing values left blank. Inspect data shows the actual packet used for the displayed snapshot.

The live badge requires a traffic snapshot, not only a WebSocket handshake. Silent feeds become “Data paused” after eight wall-clock seconds; repeated frozen timestamps also become stale. A disconnected or paused view retains its last readings and shows their age. A completed run retains its final readings.

## Implementation and validation

- `scripts/live_dashboard.py`: current-measurement helper and per-project local endpoint registry.
- `dashboard/static/live-model.mjs`: metric interpretation, observation history, freshness, reset and throughput calculations.
- `dashboard/static/live.js`: connection lifecycle, SVG schematic/charts, junction views, packet inspector and CSV export.
- `dashboard/templates/live.html` and `dashboard/static/live.css`: responsive presentation, with no CDN dependency.

Run from the repository root:

```sh
node scripts/validate_dashboard_model.mjs
.venv/bin/python3 scripts/validate_dashboard_telemetry.py --live
node scripts/validate_live_dashboard.mjs
```

The telemetry validation compares both production simulation streams against SUMO through 360 simulated seconds per mode, including intermediate vehicle updates. Browser validation requires a running dashboard and traffic server; see its command-line options for the URL and screenshot location.
