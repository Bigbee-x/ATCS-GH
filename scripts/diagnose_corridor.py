"""Reproducible corridor control audit, including the live service effects.

Compare controllers with identical routes/seeds. Actual stopped vehicle-seconds
and completed/unfinished trips are reported separately from legacy wait scores.
"""
from __future__ import annotations
import argparse
from collections import Counter
import contextlib
import json
import os
from pathlib import Path
import sys
import time
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'ai'), str(ROOT/'scripts')]
from corridor_env import CorridorEnv, JUNCTIONS, JUNCTION_IDS, STATE_SIZE, ACTION_SIZE
from dqn_agent import DQNAgent
from crossing_safety import CrossingSafety
from trotro_service import TrotroService
from corridor_runtime import CorridorRuntime
from corridor_bundle import settings, sha256
import traci
import torch


def run(args):
    torch.set_num_threads(1)
    model_dir = Path(getattr(args, 'model_dir', None) or ROOT/'ai/checkpoints/corridor')
    config = settings(model_dir) if args.controller in ('dqn', 'adaptive') else {}
    feature = getattr(args, 'occupancy_feature', None) or config.get('occupancy_feature', 'legacy')
    graded = getattr(args, 'graded_exit_capacity', None)
    if graded is None: graded = config.get('graded_exit_capacity', False)
    agents = {}
    if args.controller in ('dqn', 'adaptive'):
        for jid in JUNCTION_IDS:
            agent = DQNAgent(STATE_SIZE, ACTION_SIZE, device='cpu')
            agent.load(model_dir/f'best_{jid}.pth')
            agent.set_eval_mode()
            agents[jid] = agent
    env = CorridorEnv(route_file=str(ROOT/'simulation'/args.route), occupancy_feature=feature)
    states = env.reset(seed=args.seed)
    stations = json.loads(Path(args.stations).read_text())['corridor'] if args.stations else None
    runtime = CorridorRuntime(env, transit_enabled=args.transit, clearance_enabled=args.clearance,
        supervise=args.controller == 'adaptive', stations=stations, graded_exit_capacity=graded)
    guard, transit, controller = runtime.clearance, runtime.transit, runtime.controller
    edges = sorted({e for cfg in JUNCTIONS.values() for e in cfg.incoming_edges})
    totals = dict(stopped_vehicle_seconds=0, collisions=0, teleports=0, departed=0, arrived=0)
    collision_events = []
    collision_keys = {}
    max_phase = {j:0 for j in JUNCTION_IDS}
    actions_count = {j:Counter() for j in JUNCTION_IDS}
    phases_count = {j:Counter() for j in JUNCTION_IDS}
    reasons = {j:Counter() for j in JUNCTION_IDS}
    departs, trip_durations = {}, []
    series = []
    state_peak = np.zeros(STATE_SIZE)
    original_step = traci.simulationStep
    start = time.monotonic()

    def tick(*a, **kw):
        result = original_step(*a, **kw)
        now = traci.simulation.getTime()
        totals['stopped_vehicle_seconds'] += sum(traci.edge.getLastStepHaltingNumber(e) for e in edges)
        totals['collisions'] += traci.simulation.getCollidingVehiclesNumber()
        for collision in traci.simulation.getCollisions():
            key = (collision.collider, collision.victim, collision.lane)
            if key in collision_keys and now-collision_keys[key]['last_seen'] <= 1:
                collision_keys[key]['last_seen'] = now
            else:
                event = {'time':now, 'last_seen':now, **{k:getattr(collision,k) for k in
                    ('collider','victim','colliderSpeed','victimSpeed','type','lane','pos')}}
                collision_events.append(event)
                collision_keys[key] = event
        totals['teleports'] += traci.simulation.getStartingTeleportNumber()
        for v in traci.simulation.getDepartedIDList(): departs[v] = now
        totals['departed'] += traci.simulation.getDepartedNumber()
        totals['arrived'] += traci.simulation.getArrivedNumber()
        for v in traci.simulation.getArrivedIDList():
            if v in departs: trip_durations.append(now-departs.pop(v))
        for j in JUNCTION_IDS:
            js = env._jstate[j]
            if not js.in_yellow: max_phase[j] = max(max_phase[j], js.phase_timer)
            phases_count[j][js.phase] += 1
        return result

    traci.simulationStep = tick
    try:
        while env._sim_step < args.duration:
            if args.controller == 'dqn': actions = {j:agents[j].greedy_action(states[j]) for j in JUNCTION_IDS}
            elif args.controller == 'expert': actions = {j:env.expert_action(j) for j in JUNCTION_IDS}
            elif args.controller == 'adaptive':
                actions = runtime.select_actions({j:agents[j].greedy_action(runtime.policy_state(states[j])) for j in JUNCTION_IDS})
            else:
                def fixed(j):
                    t = max(0,env._sim_step-JUNCTION_IDS.index(j)*22)%90
                    return 1 if t<40 else 2 if t<55 else 3 if t<80 else 4
                actions = {j:fixed(j) for j in JUNCTION_IDS}
            if controller:
                for j in JUNCTION_IDS: reasons[j][controller.decisions[j]["reason"]] += 1
            for j in JUNCTION_IDS:
                actions_count[j][actions[j]] += 1
                state_peak = np.maximum(state_peak, states[j])
            states, rewards, done, infos = env.step(actions)
            if env._sim_step % 300 == 1:
                print(f'AUDIT {args.controller} t={env._sim_step} arrived={env.total_arrived}',flush=True)
                series.append({'time':env._sim_step, 'arrived':env.total_arrived,
                    'queues':{j:sum(infos[j]['queues']) for j in JUNCTION_IDS},
                    'phases':{j:env._jstate[j].phase for j in JUNCTION_IDS}})
            if done: break
        report = {'controller':args.controller,'seed':args.seed,'route':args.route,
            'occupancy_feature':feature, 'graded_exit_capacity':graded,
            'sumo_version':list(traci.getVersion()),
            'simulation_backend':'libsumo' if os.environ.get('LIBSUMO_AS_TRACI') else 'traci',
            'model_dir':str(model_dir) if agents else None,
            'model_hashes':{j:sha256(model_dir/f'best_{j}.pth') for j in agents},
            'clearance':args.clearance,'transit':args.transit,'stations':args.stations or 'current',
            'duration':env._sim_step,**totals,'active_at_end':traci.vehicle.getIDCount(),
            'collision_events':collision_events,
            'remaining_expected':traci.simulation.getMinExpectedNumber(),
            'mean_stopped_vehicles':totals['stopped_vehicle_seconds']/env._sim_step,
            'completed_mean_trip_seconds':float(np.mean(trip_durations)) if trip_durations else None,
            'completed_p95_trip_seconds':float(np.percentile(trip_durations,95)) if trip_durations else None,
            'unfinished_mean_age_seconds':float(np.mean([env._sim_step-t for t in departs.values()])) if departs else 0,
            'legacy_wait_score':env.corridor_avg_wait(),
            'junction_wait_score':{j:float(np.mean(env.episode_waits[j])) for j in JUNCTION_IDS},
            'max_green_seconds':max_phase,'actions':actions_count,'phase_seconds':phases_count,
            'decision_reasons':reasons,'state_peak':state_peak.tolist(),'boarded':transit.boarded_total,'series':series,
            'max_sensor_ms':runtime.max_sensor_ms,
            'wall_seconds':round(time.monotonic()-start,2)}
        if args.output:
            Path(args.output).parent.mkdir(parents=True,exist_ok=True)
            Path(args.output).write_text(json.dumps(report,indent=2))
        print(json.dumps({k:v for k,v in report.items() if k not in ('series','state_peak','phase_seconds')},indent=2))
        return report
    finally:
        traci.simulationStep = original_step
        env.close()

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--controller',choices=['dqn','fixed','expert','adaptive'],default='dqn')
    p.add_argument('--route',default='corridor_routes.rou.xml')
    p.add_argument('--duration',type=int,default=7200)
    p.add_argument('--seed',type=int,default=42)
    p.add_argument('--clearance',action=argparse.BooleanOptionalAction,default=True)
    p.add_argument('--transit',action=argparse.BooleanOptionalAction,default=True)
    p.add_argument('--stations')
    p.add_argument('--output')
    p.add_argument('--model-dir', help='Immutable candidate bundle or legacy shipped checkpoints')
    p.add_argument('--occupancy-feature', choices=['legacy','fullness'], help='Explicit ablation override; otherwise read the model manifest')
    p.add_argument('--graded-exit-capacity', action=argparse.BooleanOptionalAction, default=None)
    run(p.parse_args())
