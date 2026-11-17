#!/usr/bin/env python3
"""Train isolated corridor bundles in the exact supervised deployment runtime.

No checkpoint is promoted here. Compare immutable snapshots with
validate_corridor_candidates.py before deployment. All randomness is seeded;
complete-episode resume includes replay buffers, optimizers and RNG state.
"""
from __future__ import annotations
import argparse
import copy
import json
from importlib.metadata import version
from pathlib import Path
import random
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'ai'), str(ROOT/'scripts')]
import numpy as np
import torch
import torch.nn.functional as F
from corridor_env import CorridorEnv, JUNCTION_IDS, CORRIDOR_LINKS, STATE_SIZE, ACTION_SIZE
from corridor_controller import CorridorController
from corridor_runtime import CorridorRuntime
from corridor_bundle import settings, write_manifest, sha256
from dqn_agent import DQNAgent
from occupancy import JAM_OCCUPANCY

ROUTES = ['corridor_routes.rou.xml', 'corridor_routes_evening.rou.xml', 'corridor_routes_offpeak.rou.xml']


def training_contract(args):
    sources = ['ai/corridor_env.py','ai/corridor_controller.py','ai/occupancy.py','ai/dqn_agent.py',
               'scripts/corridor_runtime.py','scripts/crossing_safety.py','scripts/trotro_service.py',
               'scripts/train_corridor_deployment.py','simulation/corridor.net.xml',
               'visualizer/assets/transit/stations.json']
    return {'sources':{p:sha256(ROOT/p) for p in sources},
            'routes':{p:sha256(ROOT/'simulation'/p) for p in ROUTES},
            'packages':{p:version(p) for p in ('eclipse-sumo','torch','numpy')},
            'parents':{j:sha256(Path(args.init_dir)/f'best_{j}.pth') for j in JUNCTION_IDS}
                      if args.initialization != 'fresh' else {}}


def calibration_factor():
    """Approximate unit conversion, exact below per-lane fullness saturation.

    Empty sidewalks contributed to the legacy edge average. Calibrate the first
    layer rather than exposing a trained network to an input 233 times larger.
    Mixed vehicle gaps and saturation still require evaluation and fine-tuning.
    """
    root = ET.parse(ROOT/'simulation/corridor.net.xml').getroot()
    factors = set()
    for edge_id in {e for pair in CORRIDOR_LINKS.values() for e in pair}:
        lanes = root.find(f"edge[@id='{edge_id}']").findall('lane')
        motor = [lane for lane in lanes if lane.get('allow') != 'pedestrian']
        factors.add(JAM_OCCUPANCY * len(motor) / len(lanes) / 100)
    if len(factors) != 1:
        raise ValueError('Lane topology does not support one occupancy calibration factor')
    return factors.pop()


def learn(agent, anchor, anchor_weight):
    if len(agent.memory) < agent.MIN_BUFFER_SIZE:
        return None
    states, actions, rewards, next_states, dones = agent.memory.sample(agent.BATCH_SIZE)
    s, ns = torch.as_tensor(states), torch.as_tensor(next_states)
    a, r, d = torch.as_tensor(actions).long(), torch.as_tensor(rewards), torch.as_tensor(dones)
    q = agent.policy_net(s)
    with torch.no_grad():
        selected = agent.policy_net(ns).argmax(1)
        target = r + agent.GAMMA * agent.target_net(ns).gather(1, selected[:,None]).squeeze(1) * (1-d)
        teacher = F.softmax(anchor(s), dim=1)
    td = F.smooth_l1_loss(q.gather(1,a[:,None]).squeeze(1), target)
    regularizer = F.kl_div(F.log_softmax(q,dim=1), teacher, reduction='batchmean')
    loss = td + anchor_weight * regularizer
    agent.optimiser.zero_grad()
    loss.backward()
    torch.nn.utils.clip_grad_norm_(agent.policy_net.parameters(), 1.0)
    agent.optimiser.step()
    agent.step_count += 1
    if agent.step_count % agent.TARGET_UPDATE_FREQ == 0:
        agent._sync_target()
    return float(loss.item())


def snapshot(agents, directory, args, episode, **extra):
    directory.mkdir(parents=True, exist_ok=False)
    for jid, agent in agents.items():
        agent.save(directory/f'best_{jid}.pth')
    return write_manifest(directory, args.occupancy_feature, args.graded_exit_capacity,
        training_seed=args.seed, training_episodes=episode, services={'crossings':True,'boarding':True,'supervised':True},
        initialization=args.initialization, parent_models={j:sha256(Path(args.init_dir)/f'best_{j}.pth') for j in JUNCTION_IDS} if args.initialization != 'fresh' else {},
        learning_rate=args.learning_rate, anchor_weight=args.anchor_weight, input_clipping=True,
        training_scenarios=ROUTES, **extra)


def run(args):
    torch.set_num_threads(1)
    random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed)
    torch.use_deterministic_algorithms(True)
    output = Path(args.output).resolve()
    if output == (ROOT/'ai/checkpoints/corridor').resolve():
        raise ValueError('Training must use an isolated output directory, never the shipped model directory')
    if output.exists() and not args.resume:
        raise FileExistsError(f'{output} exists; use a new run directory or --resume')
    output.mkdir(parents=True, exist_ok=True)
    agents, anchors = {}, {}
    source = settings(args.init_dir) if args.init_dir and args.initialization != 'fresh' else None
    if args.initialization != 'fresh' and source is None:
        raise ValueError('Warm-start requires --init-dir')
    factor = 1.0
    if source and source['occupancy_feature'] != args.occupancy_feature:
        if source['occupancy_feature'] != 'legacy' or args.occupancy_feature != 'fullness':
            raise ValueError('Only legacy-to-fullness transfer is supported')
        factor = calibration_factor() if args.initialization == 'calibrated' else 0.0
    for jid in JUNCTION_IDS:
        ag = DQNAgent(STATE_SIZE, ACTION_SIZE, device='cpu')
        if args.initialization != 'fresh':
            ag.load(Path(args.init_dir)/f'best_{jid}.pth')
            with torch.no_grad(): ag.policy_net.net[0].weight[:,45].mul_(factor)
            ag._sync_target()
        # Old optimizer moments have incompatible units after rescaling; start
        # a fresh optimizer while retaining the useful policy representation.
        ag.optimiser = torch.optim.Adam(ag.policy_net.parameters(), lr=args.learning_rate)
        ag.epsilon = args.epsilon
        agents[jid] = ag
        anchors[jid] = copy.deepcopy(ag.policy_net).eval()
        for parameter in anchors[jid].parameters(): parameter.requires_grad_(False)
    start_episode = 0
    contract = training_contract(args)
    if args.resume:
        state = torch.load(output/'resume.pth', map_location='cpu', weights_only=False)
        if state['episode'] < args.episodes and state.get('training_contract') != contract:
            raise ValueError('Resume runtime/data/parent models changed or lack provenance; warm-start an isolated new run instead')
        for key in ('seed','occupancy_feature','graded_exit_capacity','initialization','init_dir','learning_rate','anchor_weight','duration','epsilon'):
            if state['config'][key] != vars(args)[key]: raise ValueError(f'Resume configuration changed: {key}')
        for jid, ag in agents.items():
            saved = state['agents'][jid]
            ag.policy_net.load_state_dict(saved['policy']); ag.target_net.load_state_dict(saved['target'])
            ag.optimiser.load_state_dict(saved['optimizer']); ag.memory.buffer = saved['replay']
            ag.epsilon = saved['epsilon']; ag.step_count = saved['steps']
        random.setstate(state['random']); np.random.set_state(state['numpy']); torch.set_rng_state(state['torch'])
        start_episode = state['episode']
        last_snapshot = output/f'episode-{start_episode:03d}'
        if start_episode and start_episode % args.checkpoint_every == 0 and not last_snapshot.exists():
            snapshot(agents,last_snapshot,args,start_episode)
    else:
        (output/'config.json').write_text(json.dumps(vars(args),indent=2)+'\n')
        (output/'training-contract.json').write_text(json.dumps(contract,indent=2)+'\n')
        snapshot(agents, output/'episode-000', args, 0, occupancy_weight_scale=factor)
    for episode in range(start_episode+1, args.episodes+1):
        started = time.monotonic()
        route = ROUTES[(episode-1)%len(ROUTES)]
        sumo_seed = args.seed * 1009 + episode * 137
        env = CorridorEnv(route_file=str(ROOT/'simulation'/route),occupancy_feature=args.occupancy_feature)
        losses = []
        collisions = teleports = 0
        try:
            states = env.reset(seed=sumo_seed)
            runtime = CorridorRuntime(env,graded_exit_capacity=args.graded_exit_capacity)
            import traci
            after_runtime = env.after_step
            def after_step():
                nonlocal collisions, teleports
                after_runtime()
                collisions += traci.simulation.getCollidingVehiclesNumber()
                teleports += traci.simulation.getStartingTeleportNumber()
            env.after_step = after_step
            states = {j:runtime.policy_state(s) for j,s in states.items()}
            done = False
            while not done and env._sim_step < args.duration:
                proposals = {j:ag.select_action(states[j]) for j,ag in agents.items()}
                applied = runtime.select_actions(proposals)
                next_states, rewards, done, _ = env.step(applied)
                next_states = {j:runtime.policy_state(s) for j,s in next_states.items()}
                for j,ag in agents.items():
                    # The chosen proposal is the policy action. Its consequence
                    # includes the supervisor's intervention; don't relabel it
                    # with a different action after the environment has executed.
                    ag.remember(states[j],proposals[j],rewards[j],next_states[j],done)
                    value = learn(ag,anchors[j],args.anchor_weight)
                    if value is not None: losses.append(value)
                states = next_states
                if env._sim_step % 1200 == 1:
                    print(f'PROGRESS seed={args.seed} episode={episode} sim_time={env._sim_step} arrived={env.total_arrived}',flush=True)
            row = {'episode':episode,'scenario':route,'seed':sumo_seed,
                   'sim_time':env._sim_step,'mean_stopped_vehicles':runtime.traffic_metrics()['mean_stopped_vehicles'],
                   'arrived':env.total_arrived,'collisions':collisions,'teleports':teleports,
                   'loss':float(np.mean(losses)) if losses else None,
                   'wall_seconds':round(time.monotonic()-started,2)}
        finally:
            env.close()
        for ag in agents.values(): ag.epsilon = max(0.01,ag.epsilon*.9)
        state = {'episode':episode,'config':vars(args),'training_contract':contract,
                 'random':random.getstate(),'numpy':np.random.get_state(),
                 'torch':torch.get_rng_state(),'agents':{j:{'policy':ag.policy_net.state_dict(),
                 'target':ag.target_net.state_dict(),'optimizer':ag.optimiser.state_dict(),'replay':ag.memory.buffer,
                 'epsilon':ag.epsilon,'steps':ag.step_count} for j,ag in agents.items()}}
        torch.save(state,output/'resume.tmp'); (output/'resume.tmp').replace(output/'resume.pth')
        if episode % args.checkpoint_every == 0 or episode == args.episodes:
            snapshot(agents,output/f'episode-{episode:03d}',args,episode)
        with (output/'training.jsonl').open('a') as file: file.write(json.dumps(row)+'\n')
        print('TRAIN '+json.dumps(row),flush=True)
    print(f'TRAIN COMPLETE: {output}; snapshots require supervised evaluation before promotion',flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',required=True)
    p.add_argument('--seed',type=int,default=101)
    p.add_argument('--episodes',type=int,default=9)
    p.add_argument('--duration',type=int,default=7200)
    p.add_argument('--checkpoint-every',type=int,default=3)
    p.add_argument('--init-dir',default=str(ROOT/'ai/checkpoints/corridor'))
    p.add_argument('--initialization',choices=['calibrated','zero-occupancy','fresh'],default='calibrated')
    p.add_argument('--occupancy-feature',choices=['legacy','fullness'],default='fullness')
    p.add_argument('--graded-exit-capacity',action=argparse.BooleanOptionalAction,default=False)
    p.add_argument('--epsilon',type=float,default=.05)
    p.add_argument('--learning-rate',type=float,default=2e-5)
    p.add_argument('--anchor-weight',type=float,default=.25)
    p.add_argument('--resume',action='store_true')
    args=p.parse_args()
    if args.episodes<0 or args.duration<5 or args.checkpoint_every<1: p.error('Invalid episode/duration/checkpoint limit')
    run(args)

if __name__=='__main__': main()
