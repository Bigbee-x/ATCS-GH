# Corridor control interface — 16 November 2026

The active corridor scene now uses `visualizer/scripts/CorridorHUD.gd`.
`UI.gd` remains the retired single-junction interface for historical compatibility.
The Valiborn interface palette is monochrome with an orange accent; the launcher
and drone instruments use the same palette. Physical traffic-light colours are
unchanged.

The default view has a compact top status bar and a bottom strip for J0/J1/J2.
Click a junction to focus the camera and select its detail/command target.
The Traffic, Scene and Controls buttons open one inspector at a time. Escape
closes an open inspector before the existing drone/lobby escape behaviour.

- **Traffic:** actual phase and elapsed time, applied decision and reason,
  actual signal aspects, per-approach queues/waits, crossing WALK states and
  selected-junction wait/queue history. Orange marks selection, not a claimed
  green light or performance score.
- **Scene:** clock, clock mode, weather and pedestrian visibility. Hiding
  pedestrians changes their rendering only; simulated demand and crossing
  protection stay active.
- **Controls:** server-confirmed adaptive/fixed-timer mode and explicitly
  targeted J0/J1/J2 requests for N–S or E–W through phases. The existing backend
  transition/clearance rules still apply. Sending a request is not presented as
  confirmation that the phase changed.

Top-level mean wait is the server's current corridor mean wait, not trip delay.
Missing or invalid numerical measurements display a dash. Histories use actual
simulation timestamps, replace duplicate timestamps, retain up to ten minutes
(600 samples maximum), show missing values as gaps and reset on a new run.
They are not seeded with example measurements. Historical fixed-timer comparisons
and training rewards have been removed from the default visual interface.

Connection state and the last received snapshot remain distinct. After 15 seconds
without a full state packet the display says Data delayed and disables mode and
manual commands. Disconnection preserves the last readings with a reconnecting
label. Mode requests wait for a server acknowledgement and become retryable if
unconfirmed after ten seconds. Completion disables commands; restart clears the
old readings/history. Wall-clock freshness affects UI availability only, never
the agents' simulation-time policy cadence.

`WebSocketClient.send_override` now accepts an optional junction argument. Its
J0 default keeps legacy callers compatible; the corridor sends the selected
junction through the backend's existing `junction` field. No policy, SUMO
physics, network, reward, demand or checkpoint change is part of this redesign.

Validation:

- `visualizer/tools/validate_corridor_hud.gd`: fixture-based checks for real-value
  formatting, missing data, duplicate timestamps, restart, stale/disconnected
  command guards, explicit junction targeting, acknowledgement, scene controls,
  completion and layout at 1280×720, 960×600 and 800×600.
- Existing metric-corridor and launcher checks.
- `visualizer/tools/validate_live_traffic.gd`: real socket-TraCI vehicles, phases,
  supervisor freshness and displayed signal agreement. Its optional rendering
  arguments `-- /absolute/output/directory --hud` capture the overview and all
  three inspectors, plus a real packet for provenance.

Logs and captured images for this change live in
`logs/corridor-hud-20261116/`. Use an isolated TMPDIR and the test's private
server log to avoid interfering with the user's running dashboard/session.
