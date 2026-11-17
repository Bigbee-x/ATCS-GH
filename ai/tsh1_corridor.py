"""TSH-1 corridor observation contract. No SUMO import or live signal writes.

The emulator is explicitly a simulator oracle for receiving-road occupancy.
A physical head must supply verified full-link coverage (possibly fused across
heads); a 200 m observation cannot silently stand in for a 1.5 km exit.
"""
from __future__ import annotations
from collections import defaultdict
import hashlib
from pathlib import Path
from types import SimpleNamespace
from xml.etree import ElementTree as ET
import numpy as np

try:
    from .tsh1_interface import FrameValidationError, validate_frames, _nonnegative, HALT_SPEED, DETECTOR_RANGE
    from . import tsh1_schema as scale
    from .occupancy import fullness_from_occupancy
except ImportError:
    from tsh1_interface import FrameValidationError, validate_frames, _nonnegative, HALT_SPEED, DETECTOR_RANGE
    import tsh1_schema as scale
    from occupancy import fullness_from_occupancy

SCHEMA = 'atcs-gh/tsh1-corridor-arm/1'
INCOMING = {
    'J0': ['ACH_J1toJ0', 'AGG_E2J0', 'ACH_S2J0', 'GUG_W2J0'],
    'J1': ['ACH_J2toJ1', 'ASD_E2J1', 'ACH_J0toJ1', 'RNG_W2J1'],
    'J2': ['ACH_N2J2', 'NMA_E2J2', 'ACH_J1toJ2', 'TSN_W2J2'],
}
NEIGHBORS = {'J0': (None, 'J1'), 'J1': ('J0', 'J2'), 'J2': ('J1', None)}


class CorridorMap:
    """Surveyed lane/movement configuration, pinned to a network hash."""
    def __init__(self, network=None):
        path = Path(network or Path(__file__).resolve().parents[1]/'simulation/corridor.net.xml')
        self.digest = hashlib.sha256(path.read_bytes()).hexdigest()
        root = ET.parse(path).getroot()
        edges = {e.get('id'): e for e in root.findall('edge')}
        self.arms, self.topology, self.lanes, self.edge_lanes, self.links = {}, {}, {}, {}, {}
        for edge, element in edges.items():
            self.edge_lanes[edge] = [l.get('id') for l in element.findall('lane')]
            for lane in element.findall('lane'):
                self.lanes[lane.get('id')] = {'length': float(lane.get('length')), 'limit': float(lane.get('speed'))}
        def motor(edge):
            return [l.get('id') for l in edges[edge].findall('lane') if l.get('allow') != 'pedestrian']
        for jid, incoming in INCOMING.items():
            self.arms[jid] = {}
            self.links[jid] = []
            for index, (arm, edge) in enumerate(zip('NESW', incoming)):
                other = edges[edge].get('from')
                outgoing = next(e for e, v in edges.items() if v.get('from') == jid and v.get('to') == other)
                self.arms[jid][arm] = {'edge': edge, 'lanes': motor(edge), 'corner': f':{jid}_w{index}',
                                       'exit_edge': outgoing, 'exits': motor(outgoing)}
                if other in INCOMING: self.links[jid].append(outgoing)
            self.topology[jid] = {int(c.get('linkIndex')): {
                'incoming': c.get('from')+'_'+c.get('fromLane'),
                'outgoing': c.get('to')+'_'+c.get('toLane'), 'direction': c.get('dir')}
                for c in root.findall('connection') if c.get('tl') == jid and not c.get('from', '').startswith(':')}


class CorridorFrameEmulator:
    """Sample at 1 Hz; ideal exits and SUMO turn intent are labelled oracles.

range_m limits incoming detections only. This is not a radar/vision model and
does not implement overlap fusion or infer a driver's turn before commitment.
"""
    def __init__(self, mapping=None):
        self.mapping = mapping or CorridorMap()
        self.first_seen = {}
        self.last_time = -1

    def sample(self, api, range_m=None):
        now = api.simulation.getTime()
        if now <= self.last_time: raise FrameValidationError('Emulator requires advancing 1 Hz samples')
        self.last_time = now
        seen_ids, frames = set(), []
        for jid, arms in self.mapping.arms.items():
            for arm, cfg in arms.items():
                lanes, vehicles, exits = [], [], []
                for lid in cfg['lanes']:
                    spec = self.mapping.lanes[lid]
                    seen = []
                    for vid in api.lane.getLastStepVehicleIDs(lid):
                        distance = spec['length'] - api.vehicle.getLanePosition(vid)
                        if range_m is not None and distance > range_m: continue
                        speed, wait = api.vehicle.getSpeed(vid), api.vehicle.getWaitingTime(vid)
                        seen.append((vid, distance, speed, wait))
                        if distance > DETECTOR_RANGE: continue
                        tls = api.vehicle.getNextTLS(vid)
                        if not tls or tls[0][0] != jid: continue
                        seen_ids.add(vid)
                        self.first_seen.setdefault(vid, now)
                        vehicles.append({'track': vid, 'lane': lid, 'distance_m': distance, 'speed_ms': speed,
                            'wait_s': wait, 'age_s': now-self.first_seen[vid], 'link_index': tls[0][1],
                            'intended_lane': self.mapping.topology[jid][tls[0][1]]['incoming'],
                            'movement_basis': 'simulator_route', 'class': api.vehicle.getTypeID(vid)})
                    halted = [v for v in seen if v[2] < HALT_SPEED]
                    lanes.append({'lane': lid, 'lane_length_m': spec['length'], 'speed_limit_ms': spec['limit'],
                        'vehicles': len(seen), 'halting': len(halted), 'wait_sum_s': sum(v[3] for v in seen),
                        'window_speed_ms': sum(v[2] for v in seen)/len(seen) if seen else spec['limit'],
                        'queue_at_range_edge': bool(range_m is not None and any(v[1] >= range_m-14 for v in halted)),
                        'tracks': [{'track': v, 'distance_m': d, 'speed_ms': s} for v,d,s,_w in seen]})
                for lid in cfg['exits']:
                    ids = api.lane.getLastStepVehicleIDs(lid)
                    tail = min(ids, key=api.vehicle.getLanePosition) if ids else None
                    exits.append({'lane': lid, 'occupancy': api.lane.getLastStepOccupancy(lid),
                        'coverage_m': self.mapping.lanes[lid]['length'], 'occupancy_basis': 'simulator_full_lane',
                        'tail_state': 'observed' if tail else 'empty',
                        'tail_m': api.vehicle.getLanePosition(tail) if tail else None,
                        'tail_speed_ms': api.vehicle.getSpeed(tail) if tail else None})
                persons = api.edge.getLastStepPersonIDs(cfg['corner'])
                frames.append({'schema': SCHEMA, 'network_sha256': self.mapping.digest, 'junction': jid,
                    'arm': arm, 'edge': cfg['edge'], 'sample_time': now, 'range_m': range_m, 'lanes': lanes,
                    'vehicles': vehicles, 'exits': exits, 'corner': {'area': cfg['corner'], 'persons': len(persons),
                    'waiting': [{'next_crossing': api.person.getNextEdge(p), 'wait_s': api.person.getWaitingTime(p)} for p in persons]}})
        self.first_seen = {v: t for v,t in self.first_seen.items() if v in seen_ids}
        return frames


class CorridorSensorReceiver:
    """Validate a synchronized batch before exposing either policy or supervisor data.

Rejects missing/stale/replayed/ambiguous/incomplete data. Caller must route an
error to an independently approved signal controller; this class issues no
signal commands. now and sample_time must share a synchronized clock domain.
"""
    def __init__(self, mapping=None, *, occupancy_feature='legacy', allow_simulator=False):
        if occupancy_feature not in ('legacy', 'fullness'): raise ValueError('Unknown occupancy feature')
        self.mapping = mapping or CorridorMap()
        self.occupancy_feature = occupancy_feature
        self.allow_simulator = allow_simulator
        self.last_time = -1

    def receive(self, frames, signals, *, now):
        if not isinstance(frames, list) or len(frames) != 12:
            raise FrameValidationError('All 12 corridor heads are required')
        grouped = {j: [] for j in INCOMING}
        for frame in frames:
            if not isinstance(frame, dict) or not isinstance(frame.get('junction'),str) or frame['junction'] not in grouped:
                raise FrameValidationError('Unknown corridor junction')
            if frame.get('network_sha256') != self.mapping.digest:
                raise FrameValidationError('Sensor lane calibration does not match the network')
            grouped[frame['junction']].append(frame)
        for jid, group in grouped.items():
            validate_frames(group, now=now, arms=self.mapping.arms[jid], junction=jid, schema=SCHEMA)
        times = [f['sample_time'] for f in frames]
        if max(times)-min(times) > .25: raise FrameValidationError('Corridor and neighbour frames are not synchronized')
        if min(times) <= self.last_time: raise FrameValidationError('Duplicate or out-of-order corridor observation')
        if not isinstance(signals, dict) or set(signals) != set(INCOMING):
            raise FrameValidationError('All controller signal states are required')
        for signal in signals.values():
            if not isinstance(signal, dict) or type(signal.get('phase')) is not int or not 0 <= signal['phase'] < 8:
                raise FrameValidationError('Invalid controller phase')
            _nonnegative(signal.get('phase_timer'), 'phase_timer')
            stamp = _nonnegative(signal.get('sample_time'), 'signal sample_time')
            if abs(stamp-min(times)) > .25: raise FrameValidationError('Controller phase and sensors are not synchronized')
        exits = {}
        for frame in frames:
            jid, arm = frame['junction'], frame['arm']
            cfg = self.mapping.arms[jid][arm]
            rows = frame.get('exits')
            if not isinstance(rows, list) or any(not isinstance(x, dict) or not isinstance(x.get('lane'),str) for x in rows):
                raise FrameValidationError('Receiving-lane observations are required')
            if len(rows) != len(cfg['exits']) or {x.get('lane') for x in rows} != set(cfg['exits']):
                raise FrameValidationError('Missing, duplicate or misassigned exit')
            for row in rows:
                occupancy = _nonnegative(row.get('occupancy'), 'occupancy')
                if occupancy > 1: raise FrameValidationError('Exit occupancy must be a fraction, not percent')
                coverage = _nonnegative(row.get('coverage_m'), 'exit coverage')
                if coverage < self.mapping.lanes[row['lane']]['length']-.01:
                    raise FrameValidationError('Partial exit occupancy cannot represent full-lane capacity')
                basis = row.get('occupancy_basis')
                if basis not in ('measured_full_lane', 'fused_full_lane') and not (self.allow_simulator and basis == 'simulator_full_lane'):
                    raise FrameValidationError('Unverified exit occupancy source')
                if row.get('tail_m') is None:
                    # Last-step occupancy can remain nonzero just after the
                    # final vehicle leaves. Empty is an explicit observation,
                    # never a default for an unknown or occluded tail.
                    if row.get('tail_state') != 'empty' or row.get('tail_speed_ms') is not None:
                        raise FrameValidationError('Missing exit-tail observation')
                else:
                    if row.get('tail_state') != 'observed':
                        raise FrameValidationError('Exit-tail quality is missing')
                    distance = _nonnegative(row['tail_m'], 'tail_m')
                    if distance > self.mapping.lanes[row['lane']]['length']+.01:
                        raise FrameValidationError('Exit tail outside mapped lane')
                    _nonnegative(row.get('tail_speed_ms'), 'tail_speed_ms')
                exits[row['lane']] = row
            tracks = frame.get('vehicles')
            if not isinstance(tracks, list): raise FrameValidationError('Supervisor vehicle tracks are required')
            identities = set()
            for track in tracks:
                if not isinstance(track, dict) or not isinstance(track.get('track'), str) or not track['track'] or track['track'] in identities:
                    raise FrameValidationError('Missing or duplicate track identity')
                identities.add(track['track'])
                index = track.get('link_index')
                link = self.mapping.topology[jid].get(index) if type(index) is int else None
                if (link is None or link['incoming'] != track.get('intended_lane')
                        or link['incoming'] not in cfg['lanes'] or track.get('lane') not in cfg['lanes']):
                    raise FrameValidationError('Movement does not belong to the detected lane')
                basis = track.get('movement_basis')
                if basis != 'confirmed' and not (self.allow_simulator and basis == 'simulator_route'):
                    raise FrameValidationError('Uncertain turn intent is not a confirmed movement')
                for key in ('distance_m', 'speed_ms', 'wait_s', 'age_s'): _nonnegative(track.get(key), key)
                if track['distance_m'] > min(DETECTOR_RANGE, frame['range_m'] or DETECTOR_RANGE):
                    raise FrameValidationError('Supervisor track outside sensor coverage')
            visible = {}
            for lane in frame['lanes']:
                if lane.get('lane_length_m') != self.mapping.lanes[lane['lane']]['length']:
                    raise FrameValidationError('Lane length does not match surveyed configuration')
                entries = lane.get('tracks')
                if not isinstance(entries,list) or len(entries) != lane['vehicles']:
                    raise FrameValidationError('Visible track list is incomplete')
                for track in entries:
                    if (not isinstance(track,dict) or not isinstance(track.get('track'),str)
                            or not track['track'] or track['track'] in visible):
                        raise FrameValidationError('Missing or duplicate visible track')
                    distance = _nonnegative(track.get('distance_m'),'visible distance')
                    speed = _nonnegative(track.get('speed_ms'),'visible speed')
                    if distance > min(frame['range_m'] or float('inf'),self.mapping.lanes[lane['lane']]['length'])+.01:
                        raise FrameValidationError('Visible track outside lane coverage')
                    visible[track['track']] = (lane['lane'],distance,speed)
            expected = {v for v,(_,d,_) in visible.items() if d <= DETECTOR_RANGE}
            if identities != expected:
                raise FrameValidationError('Supervisor tracks omit or invent visible approaching vehicles')
            for track in tracks:
                if visible[track['track']] != (track['lane'],track['distance_m'],track['speed_ms']):
                    raise FrameValidationError('Aggregate and supervisor tracks disagree')
            waiting = frame['corner'].get('waiting')
            if not isinstance(waiting, list) or len(waiting) != frame['corner']['persons']:
                raise FrameValidationError('Pedestrian intent observations are incomplete')
            for person in waiting:
                if not isinstance(person, dict) or not isinstance(person.get('next_crossing'), str):
                    raise FrameValidationError('Pedestrian intent is missing')
                _nonnegative(person.get('wait_s'), 'pedestrian wait')
        states = {}
        for jid, group in grouped.items():
            by_arm = {f['arm']: f for f in group}
            ordered = [by_arm[a] for a in 'NESW']
            lanes = {l['lane']: l for f in group for l in f['lanes']}
            lane_order = [l for cfg in self.mapping.arms[jid].values() for l in cfg['lanes']]
            values = np.zeros(46, dtype=np.float32)
            for i, lid in enumerate(lane_order):
                lane = lanes[lid]
                values[i] = lane['halting']; values[8+i] = lane.get('lane_speed_ms', lane['window_speed_ms'])
                values[16+i] = lane['wait_sum_s']
            values[:8] /= scale.MAX_QUEUE_LANE; values[8:16] /= scale.MAX_SPEED; values[16:24] /= scale.MAX_WAIT
            values[24:28] = np.array([sum(l['halting'] for l in f['lanes']) for f in ordered], dtype=np.float32)/scale.MAX_QUEUE
            values[28+signals[jid]['phase']] = 1
            values[36] = min(signals[jid]['phase_timer']/scale.MAX_PHASE_T, 1)
            values[37:41] = np.array([f['corner']['persons'] for f in ordered], dtype=np.float32)/scale.MAX_PED_QUEUE
            for offset, neighbor in zip((41,43), NEIGHBORS[jid]):
                if neighbor:
                    values[offset] = min(sum(l['halting'] for f in grouped[neighbor] for l in f['lanes'])/scale.MAX_QUEUE, 1)
                    values[offset+1] = signals[neighbor]['phase']/7
            link_values = []
            for edge in self.mapping.links[jid]:
                motor = [exits[l]['occupancy'] for l in self.mapping.edge_lanes[edge] if l in exits]
                if self.occupancy_feature == 'legacy':
                    link_values.append(sum(motor)/len(self.mapping.edge_lanes[edge])/100)
                else:
                    link_values.append(sum(fullness_from_occupancy(o) for o in motor)/len(motor))
            values[45] = max(link_values, default=0)
            states[jid] = values
        api = CorridorFrameAPI(frames, self.mapping)
        self.last_time = max(times)
        return states, api


class CorridorFrameAPI:
    """Read-only subset consumed by CorridorController.observe(), using wire data.

No simulator handle or hidden-road queries. Construct only after validation.
The extra getDetectionAge preserves head tracker age when a host reconnects.
"""
    def __init__(self, frames, mapping):
        lane_rows = {l['lane']: l for f in frames for l in f['lanes']}
        exit_rows = {e['lane']: e for f in frames for e in f['exits']}
        tracks, lane_ids, people, areas = {}, defaultdict(list), {}, {}
        for frame in frames:
            jid, arm = frame['junction'], frame['arm']
            for t in frame['vehicles']:
                identity = f'{jid}/{arm}/{t["track"]}'
                tracks[identity] = {**t, 'junction': jid, 'position': mapping.lanes[t['lane']]['length']-t['distance_m']}
                lane_ids[t['lane']].append(identity)
            area = frame['corner']['area']
            areas[area] = []
            for i, p in enumerate(frame['corner']['waiting']):
                identity = f'{area}/{i}'; people[identity] = p; areas[area].append(identity)
        # A short corridor lane is both an exit and a neighbour's approach.
        # Keep exit tails separate so supervisor capacity sees the full exit,
        # even when that tail is outside the next head's incoming detector.
        self._exit_ids = {}
        for lid, row in exit_rows.items():
            identity = 'tail/'+lid
            self._exit_ids[lid] = [identity] if row['tail_m'] is not None else []
            tracks[identity] = {'position': row['tail_m'], 'speed_ms': row['tail_speed_ms']}
        self._incoming_ids = lane_ids
        self._reading_exits = True
        self.simulation = SimpleNamespace(getTime=lambda: frames[0]['sample_time'])
        self.lane = SimpleNamespace(getLength=lambda l: mapping.lanes[l]['length'],
            getLastStepVehicleIDs=lambda l: self._exit_ids.get(l, []) if self._reading_exits else lane_ids[l],
            getLastStepOccupancy=lambda l: exit_rows[l]['occupancy'],
            getLastStepHaltingNumber=lambda l: lane_rows[l]['halting'])
        self.vehicle = SimpleNamespace(getLanePosition=lambda v: tracks[v]['position'],
            getSpeed=lambda v: tracks[v]['speed_ms'], getWaitingTime=lambda v: tracks[v]['wait_s'],
            getDetectionAge=lambda v: tracks[v]['age_s'],
            getNextTLS=lambda v: [(tracks[v]['junction'], tracks[v]['link_index'], tracks[v]['distance_m'], '')])
        self.edge = SimpleNamespace(getLastStepPersonIDs=lambda a: areas[a])
        self.person = SimpleNamespace(getNextEdge=lambda p: people[p]['next_crossing'], getWaitingTime=lambda p: people[p]['wait_s'])

    def begin_receiving_observations(self): self._reading_exits = True
    def begin_approach_observations(self): self._reading_exits = False
