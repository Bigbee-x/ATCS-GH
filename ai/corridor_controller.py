"""Live DQN supervisor driven by movement detectors and receiving-road capacity.

The neural policy proposes phases. The supervisor rejects empty/blocked service,
limits prolonged greens and serves ageing demand. It never skips the environment's
minimum-green/yellow transition rules, nor the pedestrian-clearance interlock.
"""
from __future__ import annotations
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET
import numpy as np
from corridor_env import (JUNCTIONS, JUNCTION_IDS, ACTION_TO_PHASE, ACTION_HOLD,
                          NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT, PHASE_NAMES)
from occupancy import fullness_from_occupancy
import traci

PHASES = (NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT)
PHASE_ACTION = {p:a for a,p in ACTION_TO_PHASE.items()}
DETECTOR_RANGE = 160.0
MAX_DEMAND_AGE = 90.0
MAX_THROUGH_GREEN = 90.0
MAX_LEFT_GREEN = 25.0
# Graded exit capacity: discount movements into partly full exits by
# 1 - fullness/0.9. Until 13 Nov 2026 occupancy was read 100x too small, so this
# never acted and the audited results were measured without it. Switched on, it
# moved the four matched runs (morning 42, evening 179, off-peak 316, morning
# 997) by -3.9 %, +3.4 %, -3.5 % and +9.2 % mean stopped vehicles, so it stays
# off until it is evaluated as a feature. Exits at >= 85 % fullness are blocked
# either way (docs/corridor-occupancy-fix.md).
GRADED_EXIT_CAPACITY = False


class CorridorController:
    def __init__(self, env, clearance, api=None, graded_exit_capacity=None):
        self.env, self.clearance = env, clearance
        self.api = api or traci
        self.graded_exit_capacity = GRADED_EXIT_CAPACITY if graded_exit_capacity is None else bool(graded_exit_capacity)
        self.time = -1.0
        self.first_seen = {}
        self.observations = {}
        self.decisions = {}
        self.lengths = {}
        self.topology = {j:{} for j in JUNCTION_IDS}
        root = ET.parse(Path(__file__).resolve().parents[1]/'simulation/corridor.net.xml').getroot()
        for c in root.findall('connection'):
            jid = c.get('tl')
            if jid in self.topology and not c.get('from','').startswith(':'):
                self.topology[jid][int(c.get('linkIndex'))] = {
                    'incoming':c.get('from')+'_'+c.get('fromLane'),
                    'outgoing':c.get('to')+'_'+c.get('toLane'),
                    'direction':c.get('dir')}

    @staticmethod
    def policy_state(state):
        # Keep checkpoint feature order/scales. Bound sensor saturation instead
        # of extrapolating Q-values from waits hundreds of times the train scale.
        return np.clip(np.nan_to_num(state, nan=0.0, posinf=1.0, neginf=0.0),0.0,1.0).astype(np.float32)

    def _length(self, lane):
        if lane not in self.lengths: self.lengths[lane] = self.api.lane.getLength(lane)
        return self.lengths[lane]

    def observe(self):
        api = self.api
        now = api.simulation.getTime()
        if now == self.time: return self.observations
        if now < self.time: self.first_seen.clear()
        self.time = now
        if hasattr(api, 'begin_receiving_observations'): api.begin_receiving_observations()
        receiving = {}
        for links in self.topology.values():
            for link in links.values():
                lane = link['outgoing']
                if lane in receiving: continue
                ids = api.lane.getLastStepVehicleIDs(lane)
                # SUMO already returns 0..1; fullness rescales it so 1.0 is a
                # bumper-to-bumper jam and the 85 %/90 % limits below can be met.
                occupancy = api.lane.getLastStepOccupancy(lane)
                full = fullness_from_occupancy(occupancy)
                tail_distance, tail_speed = self._length(lane), 13.89
                if ids:
                    # Select the actual upstream tail; do not rely on ID ordering.
                    tail = min(ids, key=api.vehicle.getLanePosition)
                    tail_distance = api.vehicle.getLanePosition(tail)
                    tail_speed = api.vehicle.getSpeed(tail)
                blocked = full >= 0.85 or (tail_distance < 12 and tail_speed < 1.0)
                capacity = 0.0 if blocked else (max(0.1,1.0-full/0.9) if self.graded_exit_capacity else 1.0)
                receiving[lane] = {'occupancy':occupancy,'fullness':full,'blocked':blocked,
                    'capacity':capacity}
        seen = set()
        if hasattr(api, 'begin_approach_observations'): api.begin_approach_observations()
        for jid in JUNCTION_IDS:
            cfg = JUNCTIONS[jid]
            movement = {p:{'score':0.0,'vehicles':0,'serviceable':0,'oldest':0.0,'pedestrians':0} for p in PHASES}
            lanes = {}
            for lane in cfg.incoming_lanes:
                length = self._length(lane)
                vehicles = []
                for vid in api.lane.getLastStepVehicleIDs(lane):
                    distance = length-api.vehicle.getLanePosition(vid)
                    if distance > DETECTOR_RANGE: continue
                    tls = api.vehicle.getNextTLS(vid)
                    if not tls or tls[0][0] != jid: continue
                    index = tls[0][1]
                    link = self.topology[jid].get(index)
                    if link is None: continue
                    speed = api.vehicle.getSpeed(vid)
                    wait = api.vehicle.getWaitingTime(vid)
                    seen.add(vid)
                    self.first_seen.setdefault(vid,now)
                    age = max(wait,now-self.first_seen[vid])
                    if hasattr(api.vehicle, 'getDetectionAge'):
                        age = max(wait, api.vehicle.getDetectionAge(vid))
                    vehicles.append({'id':vid,'distance':distance,'index':index,
                        'speed':speed,'wait':wait,'age':age,'outgoing':link['outgoing']})
                vehicles.sort(key=lambda v:v['distance'])
                lanes[lane] = {'detected':len(vehicles),'queue':api.lane.getLastStepHaltingNumber(lane),
                    'oldest_seconds':max((v['age'] for v in vehicles),default=0.0),
                    'nearest_metres':vehicles[0]['distance'] if vehicles else None}
                if not vehicles: continue
                head = vehicles[0]
                for phase in PHASES:
                    signal = cfg.phase_signals[phase]
                    # The current live hardware does not offer right-on-red.
                    def served(v):
                        link = self.topology[jid][v['index']]
                        return signal[v['index']] in 'Gg' and not (phase in (NS_LEFT,EW_LEFT) and link['direction']=='r')
                    eligible = [v for v in vehicles if served(v)]
                    m = movement[phase]
                    m['vehicles'] += len(eligible)
                    if not served(head) or receiving[head['outgoing']]['blocked']: continue
                    m['serviceable'] += 1
                    m['oldest'] = max(m['oldest'],head['age'])
                    for v in eligible:
                        capacity = receiving[v['outgoing']]['capacity']
                        arrival = 1.0 if v['speed'] < 1 else max(0.15,1.0-v['distance']/DETECTOR_RANGE)
                        m['score'] += capacity*arrival*(1+min(v['age'],120)/60)
            # Read each waiting person's next crossing instead of treating an
            # occupied corner as a request for every road at that corner.
            for area in cfg.walking_areas:
                for pid in api.edge.getLastStepPersonIDs(area):
                    edge = api.person.getNextEdge(pid)
                    if edge not in cfg.crossing_edges: continue
                    index = cfg.crossing_edges.index(edge)
                    wait = api.person.getWaitingTime(pid)
                    phase = EW_THROUGH if index in (0,2) else NS_THROUGH
                    movement[phase]['pedestrians'] += 1
                    movement[phase]['oldest'] = max(movement[phase]['oldest'],wait)
                    movement[phase]['score'] += 0.5+min(wait,MAX_DEMAND_AGE)/30
            outgoing = {link['outgoing']:receiving[link['outgoing']] for link in self.topology[jid].values()}
            self.observations[jid] = {'sample_time':now,'lanes':lanes,'movements':movement,'receiving':outgoing}
        self.first_seen = {v:t for v,t in self.first_seen.items() if v in seen}
        return self.observations

    def decide(self, proposals):
        self.observe()
        actions = {}
        for jid in JUNCTION_IDS:
            js = self.env._jstate[jid]
            proposal = int(proposals[jid])
            requested = ACTION_TO_PHASE.get(proposal,js.phase)
            movements = self.observations[jid]['movements']
            available = [p for p,m in movements.items() if m['score'] > 0 and (m['serviceable'] or m['pedestrians'])]
            chosen, reason = js.phase, 'minimum_green' if not self.env._can_switch(jid) else 'dqn'
            if self.env._can_switch(jid) and available:
                # Switching loses discharge time. A small holding bonus prevents
                # queue-pressure noise from chopping a useful green into fragments.
                def utility(phase):
                    hold = 3.0 if phase == js.phase else 0.0
                    return movements[phase]['score'] + hold
                best = max(available,key=utility)
                ageing = [p for p in available if p != js.phase and movements[p]['oldest'] >= MAX_DEMAND_AGE]
                alternatives = [p for p in available if p != js.phase]
                max_green = MAX_LEFT_GREEN if js.phase in (NS_LEFT,EW_LEFT) else MAX_THROUGH_GREEN
                if ageing:
                    chosen = max(ageing,key=lambda p:(movements[p]['oldest'],movements[p]['score']))
                    reason = 'serve_waiting_approach'
                elif js.phase_timer >= max_green and alternatives:
                    chosen = max(alternatives,key=lambda p:movements[p]['score'])
                    reason = 'maximum_green'
                elif requested not in available:
                    chosen, reason = best, 'empty_or_blocked_movement'
                elif utility(requested) < utility(best)*0.75:
                    chosen, reason = best, 'balance_queue_pressure'
                elif (requested != js.phase and js.phase in available
                      and js.phase_timer < 20 and utility(js.phase) >= utility(requested)*0.8):
                    chosen, reason = js.phase, 'maintain_green_flow'
                else:
                    chosen = requested
            elif self.env._can_switch(jid):
                reason = 'no_serviceable_demand'
            action = PHASE_ACTION[chosen] if chosen != js.phase else ACTION_HOLD
            actions[jid] = action
            self.decisions[jid] = {'kind':'dqn_supervised','proposed_action':proposal,'applied_action':action,
                'reason':reason,'requested_phase':PHASE_NAMES.get(chosen,'YELLOW'),
                'sample_time':self.time,'oldest_demand_seconds':round(max(m['oldest'] for m in movements.values()),1),
                'movement_demand':{PHASE_NAMES[p]:{'vehicles':m['vehicles'],'serviceable_lanes':m['serviceable'],
                    'pedestrians':m['pedestrians'],'pressure':round(m['score'],2),'oldest_seconds':round(m['oldest'],1)} for p,m in movements.items()},
                'blocked_exits':[lane for lane,data in self.observations[jid]['receiving'].items() if data['blocked']]}
        return actions
