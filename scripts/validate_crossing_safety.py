"""Exercise pedestrian clearance against real SUMO geometry and traffic.
Writes authoritative playback samples for the Godot spatial checks.
"""
import argparse
import json
import sys
from pathlib import Path
import sumo
sys.path.insert(0, str(Path(sumo.SUMO_HOME) / 'tools'))
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import traci
from ai.traffic_env import PHASE_SIGNALS
from ai.corridor_env import JUNCTIONS
from crossing_safety import CrossingSafety


def run(corridor, output):
    name = 'corridor' if corridor else 'intersection'
    guard = CrossingSafety(traci, ROOT / 'simulation' / (name + '.net.xml'))
    traci.start([str(Path(sumo.SUMO_HOME) / 'bin/sumo'), '-c', str(ROOT/'simulation'/(name+'.sumocfg')),
                 '--no-step-log', '--no-warnings', '--seed', '42'])
    packets, tracks, finished = [], {}, set()
    holds = 0
    collisions = 0
    try:
        # Put a walker near each arm in both directions so every crossing is
        # exercised without waiting for a 1.5 km walk from the network boundary.
        for eid, crossing in guard.crossings.items():
            edges = sorted(crossing['edges'])
            for i, edge in enumerate(edges):
                other = edges[1-i]
                lane = edge + '_0'
                start = traci.lane.getShape(lane)[0]
                end = traci.lane.getShape(lane)[-1]
                cx, cy = guard.centres[crossing['junction']]
                incoming = (end[0]-cx)**2+(end[1]-cy)**2 < (start[0]-cx)**2+(start[1]-cy)**2
                pos = traci.lane.getLength(lane)-4 if incoming else 4
                pid = f'qa:{eid}:{i}'
                traci.person.add(pid, edge, pos, typeID='ped_fast')
                traci.person.appendWalkingStage(pid, [edge, other], arrivalPos=4 if incoming else traci.lane.getLength(other+'_0')-4)
        for t in range(420):
            # Includes through, protected left, yellow and green transitions.
            timeline = [(0, 22), (2, 3), (3, 22), (5, 3), (1, 14), (2, 3), (4, 14), (5, 3)]
            clock = t % sum(d for _, d in timeline)
            for phase, duration in timeline:
                if clock < duration: break
                clock -= duration
            requested = {jid: (JUNCTIONS[jid].phase_signals if corridor else PHASE_SIGNALS)[phase] for jid in guard.centres}
            occupied = {eid for eid in guard.crossings if traci.edge.getLastStepPersonIDs(eid)}
            guard.apply(requested)
            for jid, state in guard.states.items():
                for index, link in guard.links[jid].items():
                    conflicts = [eid for eid in occupied if guard.crossings[eid]['junction']==jid and
                                 (link['from'] in guard.crossings[eid]['edges'] or link['to'] in guard.crossings[eid]['edges'])]
                    if conflicts:
                        assert state[index] == 'r', (t,jid,index,'occupied crossing has a conflicting green')
                        holds += requested[jid][index] in 'GgyY'
            traci.simulationStep()
            collisions += traci.simulation.getCollidingVehiclesNumber()
            vehicles = []
            for vid in traci.vehicle.getIDList():
                x,y = traci.vehicle.getPosition(vid)
                vehicles.append(dict(id=vid,x=x,y=y,type=traci.vehicle.getTypeID(vid),angle=traci.vehicle.getAngle(vid),
                                     speed=traci.vehicle.getSpeed(vid),edge=traci.vehicle.getRoadID(vid),lane=traci.vehicle.getLaneID(vid),lane_position=traci.vehicle.getLanePosition(vid)))
            for vehicle in vehicles:
                vehicle.update(guard.vehicle_geometry(vehicle))
            pedestrians = []
            current = set()
            for pid in traci.person.getIDList():
                x,y = traci.person.getPosition(pid)
                ped = dict(id=pid,x=x,y=y,edge=traci.person.getRoadID(pid),angle=traci.person.getAngle(pid),speed=traci.person.getSpeed(pid))
                ped.update(guard.pedestrian_geometry(ped))
                pedestrians.append(ped)
                if ped['edge'] in guard.crossings:
                    current.add(pid)
                    if pid not in tracks: tracks[pid] = [t, t, ped['crossing_progress'], ped['crossing_progress']]
                    tracks[pid][1] = t
                    tracks[pid][3] = ped['crossing_progress']
                elif pid in tracks:
                    finished.add(pid)
            for pid in tracks.keys() - set(traci.person.getIDList()): finished.add(pid)
            state = {'junctions': {jid:{'phase':phase,**guard.snapshot(jid)} for jid in guard.centres}} if corridor else {'phase':phase,**guard.snapshot('J0')}
            packets.append(dict(sim_time=t+1, mode='corridor' if corridor else 'single', vehicles=vehicles,pedestrians=pedestrians,**state))
        qa = [p for p in tracks if p.startswith('qa:')]
        assert len(qa) == len(guard.crossings)*2, ('Not all seeded pedestrians crossed', qa)
        assert all(p in finished for p in qa), ('Pedestrians stranded', set(qa)-finished)
        assert holds > 0, 'Did not exercise pedestrian clearance'
        assert collisions == 0, f'{collisions} colliding vehicle observations'
        if output:
            Path(output + ('-corridor' if corridor else '-single') + '.json').write_text(json.dumps(packets))
        print(f'CROSSING SAFETY {name}: {len(tracks)} crossing pedestrians, {len(finished)} completed, {holds} conflicting movements held, {collisions} collisions')
    finally:
        traci.close()

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output')
    args=parser.parse_args()
    for corridor in [False,True]: run(corridor,args.output)
