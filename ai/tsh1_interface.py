"""TSH-1 <-> TrafIQ interface (single junction, Achimota/Neoplan J0).

One TSH-1 sensor head watches one arm. Every simulated (or real) second it
publishes an arm frame in the sim's own vocabulary: SUMO lane and walking-area
IDs, metres, m/s, seconds. The agent host merges the four arm frames with the
controller's phase and rebuilds the exact 41-value state that
``TrafficEnv._build_state`` makes. Schema and field map:
docs/tsh1-sensor-interface.md.

Field semantics copy the TraCI calls they replace (checked on SUMO 1.27.1):
  halting          lane.getLastStepHaltingNumber  vehicles slower than 0.1 m/s
  lane_speed_ms    lane.getLastStepMeanSpeed      whole-lane mean; empty lane ->
                                                  lane speed limit. A head sees
                                                  ~200 m, so it estimates the
                                                  unseen stretch (LaneSpeedBlend)
                                                  and also reports window_speed_ms,
                                                  what it measured in view
  wait_sum_s       lane.getWaitingTime            sum of each vehicle's continuous
                                                  standstill time (resets on moving)
  persons          edge.getLastStepPersonIDs      people inside the corner area
Phase one-hot and time-in-phase come from the signal controller, not the head.

Used by scripts/eval_tsh1_sensor_range.py and scripts/validate_tsh1_interface.py.
"""
from __future__ import annotations

import math
import numpy as np

try:
    from . import tsh1_schema as te
except ImportError:
    import tsh1_schema as te

SCHEMA = "atcs-gh/tsh1-arm/1"
HALT_SPEED = 0.1          # m/s, SUMO's halting threshold
DETECTOR_RANGE = 160.0    # m, the corridor supervisor's per-vehicle window

# Arm order follows INCOMING_EDGES (N, S, E, W). Corner i is owned by one head
# so no person is counted twice: N->w0 (NW), E->w1 (NE), S->w2 (SE), W->w3 (SW).
ARMS = {
    "N": {"edge": "ACH_N2J", "lanes": ["ACH_N2J_1", "ACH_N2J_2"], "corner": ":J0_w0"},
    "S": {"edge": "ACH_S2J", "lanes": ["ACH_S2J_1", "ACH_S2J_2"], "corner": ":J0_w2"},
    "E": {"edge": "AGG_E2J", "lanes": ["AGG_E2J_1", "AGG_E2J_2"], "corner": ":J0_w1"},
    "W": {"edge": "GUG_W2J", "lanes": ["GUG_W2J_1", "GUG_W2J_2"], "corner": ":J0_w3"},
}


def emulate_arm_frames(api, range_m: float | None, detail: bool = False) -> list[dict]:
    """What four TSH-1 heads would publish right now, emulated from SUMO.

    range_m=None reports the whole lane (an ideal sensor); a number limits the
    head to vehicles whose front is within that distance of the stop line.
    """
    now = api.simulation.getTime()
    frames = []
    for arm, cfg in ARMS.items():
        lanes = []
        tracks = []
        for lane in cfg["lanes"]:
            length = api.lane.getLength(lane)
            limit = api.lane.getMaxSpeed(lane)
            seen = []
            for vid in api.lane.getLastStepVehicleIDs(lane):
                dist = length - api.vehicle.getLanePosition(vid)
                if range_m is not None and dist > range_m:
                    continue
                seen.append((vid, dist, api.vehicle.getSpeed(vid), api.vehicle.getWaitingTime(vid)))
            halted = [s for s in seen if s[2] < HALT_SPEED]
            far_halt = max((s[1] for s in halted), default=0.0)
            lanes.append({
                "lane": lane,
                "lane_length_m": length,
                "speed_limit_ms": limit,
                "vehicles": len(seen),
                "halting": len(halted),
                "window_speed_ms": (sum(s[2] for s in seen) / len(seen)) if seen else limit,
                "wait_sum_s": sum(s[3] for s in seen),
                "queue_at_range_edge": bool(range_m is not None and far_halt >= range_m - 14.0),
                "tracks": [{"track": vid, "distance_m": dist, "speed_ms": speed}
                           for vid, dist, speed, _wait in seen],
            })
            if detail:
                for vid, dist, speed, wait in seen:
                    if dist > DETECTOR_RANGE:
                        continue
                    nxt = api.vehicle.getNextTLS(vid)
                    tracks.append({"track": vid, "lane": lane, "distance_m": round(dist, 1),
                                   "speed_ms": round(speed, 2), "wait_s": wait,
                                   "link_index": nxt[0][1] if nxt else None,
                                   "class": api.vehicle.getTypeID(vid)})
        persons = list(api.edge.getLastStepPersonIDs(cfg["corner"]))
        frame = {
            "schema": SCHEMA, "junction": te.TL_ID, "arm": arm, "edge": cfg["edge"],
            "sample_time": now, "range_m": range_m, "lanes": lanes,
            "corner": {"area": cfg["corner"], "persons": len(persons)},
        }
        if detail:
            frame["vehicles"] = tracks
            frame["corner"]["waiting"] = [{"next_crossing": api.person.getNextEdge(p),
                                           "wait_s": api.person.getWaitingTime(p)} for p in persons]
        frames.append(frame)
    return frames


class LaneSpeedBlend:
    """Sim-compatible lane mean speed from a range-limited head.

    SUMO averages speed over every vehicle on the whole 1.5 km lane, mostly
    free-flowing cars the head cannot see. The head can estimate how many there
    are with Little's law: hidden vehicles ~= inflow at the window edge x time
    to cross the hidden stretch. Inflow and approach speed come from tracks
    that first appear near the far edge of the window.
    """

    def __init__(self, range_m: float, window_s: float = 120.0, *, arms=None, junction='J0', schema=SCHEMA):
        self.range_m, self.window_s = range_m, window_s
        self.validation = {'arms': arms or ARMS, 'junction': junction, 'schema': schema}
        self.seen: dict[tuple[str,str],float] = {}
        self.entries: dict[str, list[tuple[float, float]]] = {}   # lane -> [(t, speed at entry)]

    def blend(self, api, frames: list[dict]) -> list[dict]:
        """Compatibility wrapper; the simulator handle is deliberately unused."""
        return self.update(frames)

    def update(self, frames: list[dict]) -> list[dict]:
        """Estimate from transmitted observations only; no simulator queries.

        lane_length_m comes from surveyed lane configuration. Tracks are limited
        to the sensor window. The unseen count is a model estimate, not a count
        measured by radar, and is labelled as such in the returned frame.
        """
        validate_frames(frames, require_whole_lane_speed=False, allow_truncated=True, **self.validation)
        now = frames[0]['sample_time']
        if getattr(self, 'last_time', None) is not None and now <= self.last_time:
            raise FrameValidationError('Speed estimator needs advancing observations')
        # Validate the complete batch before changing history. A malformed
        # last lane must not poison the timestamp or inflow of earlier lanes.
        identities = set()
        for frame in frames:
            if frame['range_m'] != self.range_m:
                raise FrameValidationError('Estimator range does not match the transmitted observation range')
            for lane in frame['lanes']:
                _nonnegative(lane.get('lane_length_m'), 'lane_length_m')
                tracks = lane.get('tracks')
                if not isinstance(tracks,list) or len(tracks) != lane['vehicles']:
                    raise FrameValidationError('Estimator needs the visible tracks, not hidden SUMO state')
                for track in tracks:
                    if not isinstance(track,dict) or not isinstance(track.get('track'),str) or not track['track']:
                        raise FrameValidationError('A stable track identity is required')
                    identity = (frame['arm'],track['track'])
                    if identity in identities: raise FrameValidationError('Duplicate visible track')
                    identities.add(identity)
                    if _nonnegative(track.get('distance_m'),'track distance') > self.range_m:
                        raise FrameValidationError('Track lies outside the declared sensor range')
                    _nonnegative(track.get('speed_ms'),'track speed')
        visible_now = set()
        for frame in frames:
            if frame['range_m'] != self.range_m:
                raise FrameValidationError('Estimator range does not match the transmitted observation range')
            for lane_rec in frame["lanes"]:
                lane = lane_rec["lane"]
                length = _nonnegative(lane_rec.get('lane_length_m'), 'lane_length_m')
                hist = self.entries.setdefault(lane, [])
                tracks = lane_rec.get('tracks')
                if not isinstance(tracks, list) or len(tracks) != lane_rec['vehicles']:
                    raise FrameValidationError('Estimator needs the visible tracks, not hidden SUMO state')
                for track in tracks:
                    if not isinstance(track.get('track'),str) or not track['track']:
                        raise FrameValidationError('A stable track identity is required')
                    vid = (frame['arm'], track['track'])
                    dist = _nonnegative(track.get('distance_m'), 'track distance')
                    v = _nonnegative(track.get('speed_ms'), 'track speed')
                    if dist > self.range_m:
                        raise FrameValidationError('Track lies outside the declared sensor range')
                    visible_now.add(vid)
                    if vid not in self.seen and dist > self.range_m - 75.0:
                        hist.append((now, v))      # a new track entering from upstream
                hist[:] = [(t, v) for t, v in hist if now - t <= self.window_s]
                limit = lane_rec["speed_limit_ms"]
                inflow = len(hist) / self.window_s
                v_in = (sum(v for _, v in hist) / len(hist)) if hist else limit
                hidden = inflow * max(length - self.range_m, 0.0) / max(v_in, 0.5)
                visible = lane_rec['vehicles']
                n = visible + hidden
                lane_rec["est_hidden_vehicles"] = round(hidden, 2)
                lane_rec["lane_speed_ms"] = ((lane_rec['window_speed_ms'] * visible + hidden * v_in) / n) if n > 0 else limit
                lane_rec['speed_basis'] = 'estimated_whole_lane'
        self.seen = {track:when for track,when in self.seen.items() if now-when<=self.window_s}
        self.seen.update({track:now for track in visible_now})
        self.last_time = now
        return frames


def state_from_frames(frames: list[dict], phase: int, phase_timer: float,
                      speed_field: str = "lane_speed_ms", *, now: float | None = None,
                      allow_truncated: bool = False) -> np.ndarray:
    """Rebuild TrafficEnv's 41-value state from four arm frames + controller phase.

    A limited-range frame must explicitly provide the whole-lane estimate.
    Research ablations may request window_speed_ms explicitly. Never silently
    substitute a different measurement domain for the deployed policy.
    """
    if speed_field not in ('lane_speed_ms','window_speed_ms'):
        raise FrameValidationError('Unknown speed measurement domain')
    validate_frames(frames, now=now, require_whole_lane_speed=speed_field=='lane_speed_ms',
                    allow_truncated=allow_truncated)
    if type(phase) is not int or not 0 <= phase < te.NUM_PHASES:
        raise FrameValidationError('Invalid signal-controller phase')
    _nonnegative(phase_timer, 'phase_timer')
    by_lane = {l["lane"]: l for f in frames for l in f["lanes"]}
    by_edge = {f["edge"]: f for f in frames}
    by_area = {f["corner"]["area"]: f["corner"]["persons"] for f in frames}

    lq = np.array([float(by_lane[l]["halting"]) for l in te.INCOMING_LANES], dtype=np.float32)
    ls = np.array([max(0.0, float(by_lane[l].get(speed_field, by_lane[l]["window_speed_ms"])))
                   for l in te.INCOMING_LANES], dtype=np.float32)
    lw = np.array([float(by_lane[l]["wait_sum_s"]) for l in te.INCOMING_LANES], dtype=np.float32)
    aq = np.array([float(sum(l["halting"] for l in by_edge[e]["lanes"])) for e in te.INCOMING_EDGES],
                  dtype=np.float32)
    ph = np.zeros(te.NUM_PHASES, dtype=np.float32)
    ph[phase] = 1.0
    t_norm = np.float32(min(phase_timer / te.MAX_PHASE_T, 1.0))
    peds = np.array([float(by_area[a]) for a in te.WALKING_AREAS], dtype=np.float32)
    state = np.concatenate([
        lq / te.MAX_QUEUE_LANE, ls / te.MAX_SPEED, lw / te.MAX_WAIT, aq / te.MAX_QUEUE,
        ph, [t_norm], peds / te.MAX_PED_QUEUE,
    ])
    return state.astype(np.float32)


class FrameValidationError(ValueError):
    """Decline the AI observation; the signal controller owns fallback timing."""


def _nonnegative(value, name):
    if isinstance(value, bool) or not isinstance(value, (int,float)) or not math.isfinite(value) or value < 0:
        raise FrameValidationError(f'{name} must be a finite nonnegative measurement')
    return value


def validate_frames(frames, *, now=None, max_age=2.5, max_skew=.25,
                    require_whole_lane_speed=True, allow_truncated=False,
                    arms=None, junction='J0', schema=SCHEMA):
    arms = arms or ARMS
    if not isinstance(frames,list) or len(frames)!=4:
        raise FrameValidationError('Exactly four approach frames are required')
    seen_arms=set(); times=[]
    for frame in frames:
        if not isinstance(frame,dict): raise FrameValidationError('Approach frame must be an object')
        arm=frame.get('arm')
        if not isinstance(arm,str) or arm not in arms or arm in seen_arms:
            raise FrameValidationError('Unknown or duplicate approach')
        seen_arms.add(arm); cfg=arms[arm]
        if frame.get('schema')!=schema or frame.get('junction')!=junction or frame.get('edge')!=cfg['edge']:
            raise FrameValidationError('Frame schema/junction/lane mapping mismatch')
        times.append(_nonnegative(frame.get('sample_time'),'sample_time'))
        coverage=frame.get('range_m')
        if coverage is not None and _nonnegative(coverage,'range_m') <= 0:
            raise FrameValidationError('Sensor range must be positive')
        lanes=frame.get('lanes',[])
        if not isinstance(lanes,list) or any(not isinstance(lane,dict) or not isinstance(lane.get('lane'),str) for lane in lanes):
            raise FrameValidationError('Lane observations must be objects')
        if len(lanes)!=len(cfg['lanes']) or {lane.get('lane') for lane in lanes}!=set(cfg['lanes']):
            raise FrameValidationError('Missing, duplicate or misassigned lane')
        for lane in lanes:
            for key in ('vehicles','halting','wait_sum_s','window_speed_ms','speed_limit_ms'):
                _nonnegative(lane.get(key),key)
            if lane['vehicles']%1 or lane['halting']%1 or lane['halting']>lane['vehicles']:
                raise FrameValidationError('Invalid vehicle/halting counts')
            if 'lane_speed_ms' in lane: _nonnegative(lane['lane_speed_ms'],'lane_speed_ms')
            if coverage is not None and require_whole_lane_speed and 'lane_speed_ms' not in lane:
                raise FrameValidationError('Whole-lane speed estimate is missing; visible-window speed is not equivalent')
            if coverage is not None and not isinstance(lane.get('queue_at_range_edge'),bool):
                raise FrameValidationError('Queue coverage quality is missing')
            if coverage is not None and lane['queue_at_range_edge'] and not allow_truncated:
                raise FrameValidationError('Queue reaches sensor boundary; full-lane queue/wait is unknown')
        corner=frame.get('corner',{})
        if not isinstance(corner,dict): raise FrameValidationError('Corner observation must be an object')
        if corner.get('area')!=cfg['corner']: raise FrameValidationError('Missing or misassigned pedestrian area')
        people=_nonnegative(corner.get('persons'),'persons')
        if people%1: raise FrameValidationError('Person count must be an integer')
    if max(times)-min(times)>max_skew: raise FrameValidationError('Approach observations are not synchronized')
    if now is not None:
        _nonnegative(now,'controller observation time')
        if now-min(times)>max_age or max(times)>now+.25:
            raise FrameValidationError('Stale or future sensor observation')


class TSH1Receiver:
    """Strict single-junction input gate; produces observations, never signals.

    Real use requires a shared clock, stable head identities, calibrated lane
    mapping, and a controller-owned fallback when FrameValidationError occurs.
    """
    def __init__(self):
        self.last_sample_time = None

    def state(self, frames, phase, phase_timer, *, now):
        state=state_from_frames(frames,phase,phase_timer,now=now)
        sample=min(frame['sample_time'] for frame in frames)
        if self.last_sample_time is not None and sample<=self.last_sample_time:
            raise FrameValidationError('Duplicate or out-of-order sensor observation')
        self.last_sample_time=sample
        return state
