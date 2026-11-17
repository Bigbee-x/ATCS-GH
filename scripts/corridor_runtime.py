"""One live corridor pipeline for the server and reproducible evaluations."""
from pathlib import Path
import time
from corridor_controller import CorridorController
from corridor_env import JUNCTIONS, JUNCTION_IDS
from crossing_safety import CrossingSafety
from trotro_service import TrotroService
from live_dashboard import incoming_metrics
import traci


class CorridorRuntime:
    def __init__(self, env, transit_enabled=True, clearance_enabled=True,
                 supervise=True, observe_every_second=True, stations=None, graded_exit_capacity=None):
        self.env = env
        self.clearance = CrossingSafety(traci,Path(__file__).resolve().parents[1]/'simulation/corridor.net.xml')
        self.transit = TrotroService(traci,corridor=True,enabled=transit_enabled)
        if stations is not None and transit_enabled:
            self.transit.stations = stations
        self.controller = CorridorController(env,self.clearance,graded_exit_capacity=graded_exit_capacity) if supervise else None
        self.clearance_enabled = clearance_enabled
        self.observe_every_second = observe_every_second
        self.sensor_ms = 0.0
        self.max_sensor_ms = 0.0
        self.current_wait = {}
        self.current_approaches = {}
        self.active_vehicles = 0
        self.stopped_vehicle_seconds = 0
        self.elapsed_steps = 0
        env.before_step = self.before_step
        env.after_step = self.after_step

    def before_step(self):
        if self.clearance_enabled:
            self.clearance.apply({j:JUNCTIONS[j].phase_signals[self.env._jstate[j].phase] for j in JUNCTION_IDS})
        self.transit.tick()

    def after_step(self):
        self.elapsed_steps += 1
        for jid, cfg in JUNCTIONS.items():
            measured = incoming_metrics(traci, dict(zip(("north", "east", "south", "west"), cfg.incoming_edges)))
            self.current_approaches[jid] = measured
            vehicle_count = measured['incoming_vehicles']
            waiting_sum = measured['waiting_sum_seconds']
            self.current_wait[jid] = {'vehicles':vehicle_count, 'waiting_sum':waiting_sum,
                'mean_seconds':waiting_sum/max(vehicle_count,1)}
            self.stopped_vehicle_seconds += measured['current_stopped_vehicles']
        self.active_vehicles = len(traci.vehicle.getIDList())
        if self.controller and self.observe_every_second:
            started = time.perf_counter()
            self.controller.observe()
            self.sensor_ms = (time.perf_counter()-started)*1000
            self.max_sensor_ms = max(self.max_sensor_ms,self.sensor_ms)

    def select_actions(self, proposals, locked=()):
        if self.controller is None:
            return proposals
        actions = self.controller.decide(proposals)
        for jid in locked:
            actions[jid] = proposals[jid]
            self.controller.decisions[jid]['applied_action'] = actions[jid]
            self.controller.decisions[jid]['reason'] = 'manual_override'
        return actions

    def policy_state(self, state):
        return CorridorController.policy_state(state) if self.controller else state

    def snapshot(self, jid):
        if self.controller is None:
            return {'kind':'raw_dqn'}
        decision = self.controller.decisions.get(jid,{})
        observation = self.controller.observations.get(jid,{})
        return {**decision, 'decision_time':decision.get('sample_time'),
                'sample_time':self.controller.time, 'sensor_ms':round(self.sensor_ms,2),
                'lane_detectors':observation.get('lanes',{}),
                'receiving_lanes':observation.get('receiving',{})}

    def junction_traffic(self, jid):
        measured = self.current_approaches.get(jid, {})
        approaches = measured.get('approaches', {})
        return {
            'approaches': approaches,
            'queues': {arm: data['stopped'] for arm, data in approaches.items()},
            'wait_times': {arm: data['mean_wait_seconds'] for arm, data in approaches.items()},
            'avg_wait': measured.get('current_mean_wait_seconds'),
            'incoming_vehicles': measured.get('incoming_vehicles'),
            'sample_time': self.env._sim_step,
        }

    def traffic_metrics(self, vehicles_completed=None):
        total_vehicles = sum(m['vehicles'] for m in self.current_wait.values())
        total_wait = sum(m['waiting_sum'] for m in self.current_wait.values())
        return {'current_mean_wait_seconds':total_wait/max(total_vehicles,1),
                'current_stopped_vehicles':sum(m['current_stopped_vehicles'] for m in self.current_approaches.values()),
                'incoming_vehicles':total_vehicles,
                'active_vehicles':self.active_vehicles,
                'vehicles_completed':self.env.total_arrived if vehicles_completed is None else vehicles_completed,
                'sample_time':self.env._sim_step,
                'scope':'incoming_edges',
                'mean_stopped_vehicles':self.stopped_vehicle_seconds/max(self.elapsed_steps,1),
                'stopped_vehicle_seconds':self.stopped_vehicle_seconds}
