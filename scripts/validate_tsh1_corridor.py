#!/usr/bin/env python3
"""1 Hz corridor frame round trip, both occupancy ABIs and supervisor decisions.

Ideal SUMO emulation is a transport/slot-map test, not physical sensor accuracy.
Requires --allow-simulator on receivers internally; production defaults reject
oracle exit coverage and oracle turn intent.
"""
import argparse
import copy
import json
from pathlib import Path
import sys
import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'ai'), str(ROOT/'scripts')]
from corridor_env import CorridorEnv, JUNCTIONS, JUNCTION_IDS, STATE_SIZE, ACTION_SIZE
from corridor_controller import CorridorController
from corridor_runtime import CorridorRuntime
from dqn_agent import DQNAgent
from tsh1_corridor import CorridorMap, CorridorFrameEmulator, CorridorSensorReceiver
from tsh1_interface import FrameValidationError
import traci


def run(args):
    torch.set_num_threads(1)
    mapping = CorridorMap()
    for jid,cfg in JUNCTIONS.items():
        assert [c['edge'] for c in mapping.arms[jid].values()] == cfg.incoming_edges
        assert [l for c in mapping.arms[jid].values() for l in c['lanes']] == cfg.incoming_lanes
    agents = {}
    for jid in JUNCTION_IDS:
        agent = DQNAgent(STATE_SIZE,ACTION_SIZE,device='cpu')
        agent.load(ROOT/'ai/checkpoints/corridor'/f'best_{jid}.pth'); agent.set_eval_mode(); agents[jid]=agent
    env = CorridorEnv(route_file=str(ROOT/'simulation'/args.route))
    env.reset(seed=args.seed)
    runtime = CorridorRuntime(env)
    emulator = CorridorFrameEmulator(mapping)
    receivers = {f:CorridorSensorReceiver(mapping,occupancy_feature=f,allow_simulator=True) for f in ('legacy','fullness')}
    sensor_controller = CorridorController(env, runtime.clearance)
    report = {'samples':0,'exact_vectors':0,'exact_supervisor_observations':0,'exact_decisions':0,'rejection_checks':0}
    latest = {}

    def check():
        now = traci.simulation.getTime()
        frames = emulator.sample(traci)
        # JSON transport strips Python object conveniences just like a wire packet.
        frames = json.loads(json.dumps(frames,allow_nan=False))
        signals = {j:{'phase':env._jstate[j].phase,'phase_timer':env._jstate[j].phase_timer,'sample_time':now} for j in JUNCTION_IDS}
        for feature, receiver in receivers.items():
            states, api = receiver.receive(frames,signals,now=now)
            env.occupancy_feature = feature
            for j in JUNCTION_IDS:
                expected = env._build_state(j)
                if not np.array_equal(states[j],expected):
                    raise AssertionError(f'{feature}/{j}/{now}: slots {np.where(states[j] != expected)[0]} {states[j]-expected}')
                report['exact_vectors'] += 1
            if feature == 'legacy': latest.update(states)
        env.occupancy_feature = 'legacy'
        sensor_controller.api = api
        measured = sensor_controller.observe()
        truth = runtime.controller.observe()
        assert measured == truth, f'Supervisor frame mismatch at {now}: {measured} / {truth}'
        report['exact_supervisor_observations'] += 3
        report['samples'] += 1
        if report['samples'] == 1:
            def reject(batch, phase=signals, timestamp=now, allow_simulator=True):
                try:
                    CorridorSensorReceiver(mapping,allow_simulator=allow_simulator).receive(batch,phase,now=timestamp)
                except FrameValidationError:
                    report['rejection_checks'] += 1
                else: raise AssertionError('Malformed/unsafe batch was accepted')
            reject(frames,allow_simulator=False)
            reject(frames[:-1]); reject(frames,timestamp=now+3)
            bad=copy.deepcopy(frames); bad[4]['sample_time']+=1; reject(bad)
            bad=copy.deepcopy(frames); bad[0]['exits'][0]['occupancy']=43; reject(bad)
            bad=copy.deepcopy(frames); bad[0]['exits'].pop(); reject(bad)
            bad=copy.deepcopy(frames); bad[0]['exits'][0]['coverage_m']=10; reject(bad)
            bad=copy.deepcopy(frames); bad[0]['network_sha256']='wrong'; reject(bad)
            bad=copy.deepcopy(frames); bad[0]['corner']['waiting']=[{'next_crossing':':J0_c0','wait_s':0}]; reject(bad)
            bad=copy.deepcopy(signals); bad['J1']['sample_time']+=1; reject(frames,bad)
            bad=copy.deepcopy(frames); bad[0]['vehicles']=[{'track':'x','lane':bad[0]['lanes'][0]['lane'],
                'link_index':999,'distance_m':1,'speed_ms':0,'wait_s':1,'age_s':1,'movement_basis':'simulator_route'}]; reject(bad)
            try: receivers['legacy'].receive(frames,signals,now=now)
            except FrameValidationError: report['rejection_checks'] += 1
            else: raise AssertionError('Replayed frame accepted')
    try:
        check()
        after_runtime = env.after_step
        def after_step():
            after_runtime()
            check()
        env.after_step = after_step
        while env._sim_step < args.duration:
            proposals = {j:agents[j].greedy_action(runtime.policy_state(latest[j])) for j in JUNCTION_IDS}
            truth = runtime.select_actions(proposals)
            from_frames = sensor_controller.decide(proposals)
            assert truth == from_frames, f'Different action at {env._sim_step}'
            report['exact_decisions'] += 3
            _,_,done,_ = env.step(from_frames)
            if done: break
        report.update(duration=env._sim_step,seed=args.seed,route=args.route,
                      scope='Ideal emulator only; full-link occupancy and turn intent use labelled SUMO oracles')
    finally:
        env.close()
    if args.output:
        Path(args.output).parent.mkdir(parents=True,exist_ok=True)
        Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--duration',type=int,default=1800)
    p.add_argument('--seed',type=int,default=42)
    p.add_argument('--route',default='corridor_routes.rou.xml')
    p.add_argument('--output')
    run(p.parse_args())
