"""Integration regression: actual SUMO stops, rider boarding and departure.
Run with the project venv. --replay writes authoritative packets for Godot QA.
"""
import argparse
import json
import sys
from pathlib import Path
import sumo
sys.path.insert(0, str(Path(sumo.SUMO_HOME) / 'tools'))
import traci
from trotro_service import TrotroService

ROOT = Path(__file__).resolve().parents[1]


def run(corridor, replay_path=None):
    config = 'corridor.sumocfg' if corridor else 'intersection.sumocfg'
    traci.start([str(Path(sumo.SUMO_HOME) / 'bin/sumo'), '-c', str(ROOT/'simulation'/config),
                 '--no-step-log', '--no-warnings', '--seed', '42'])
    packets = []
    try:
        service = TrotroService(traci, corridor=corridor)
        for i, station in enumerate(service.stations):
            route = f'qa_route{i}'
            traci.route.add(route, [station['edge']])
            traci.vehicle.add(f'00_transit{i}', route, typeID='trotro', departPos=str(station['pos']-80), departSpeed='8', departLane='1')
        stopped = set()
        verified_parked_packet = set()
        parked_frames = {}
        departed = set()
        for t in range(80):
            service.tick()
            traci.simulationStep()
            vehicles = []
            for vid in traci.vehicle.getIDList():
                if not vid.startswith('00_transit'):
                    continue
                state = service.vehicle_state(vid)
                x, y = traci.vehicle.getPosition(vid)
                speed = traci.vehicle.getSpeed(vid)
                vehicles.append({'id':vid,'type':'trotro','x':x,'y':y,'angle':traci.vehicle.getAngle(vid),'speed':speed,**state})
                if state.get('boarding'):
                    assert speed < 0.1, 'Bus boards while moving'
                    stopped.add(vid)
                    if corridor:
                        assert state.get('offroad'), 'Boarding bus is still blocking the road lane'
                        parked_frames[vid] = parked_frames.get(vid,0)+1
                        if parked_frames[vid] > 1:
                            assert vid not in traci.lane.getLastStepVehicleIDs(service.assignments[vid]['station']['edge']+'_1'), 'Parked bus occupies a travel lane'
                        if parked_frames[vid] > 1 and vid not in verified_parked_packet:
                            import corridor_visualizer_server as server
                            server._transit_service = service
                            packets_by_id = {v['id']:v for v in server._collect_vehicle_data()}
                            assert packets_by_id[vid]['offroad'] and 'bay_x' in packets_by_id[vid], 'Parked bus disappears from live vehicle packets'
                            assert abs(packets_by_id[vid]['x']-1500) < 20 and abs(packets_by_id[vid]['y']-service.assignments[vid]['station']['sumo_y']) < 2, 'Parked bus has invalid display coordinates'
                            verified_parked_packet.add(vid)
                if vid in stopped and not state.get('boarding') and speed > 1:
                    departed.add(vid)
            packets.append({'sim_time':t+1, 'vehicles':vehicles, 'transit':service.snapshot()})
        assert stopped == {'00_transit0','00_transit1'}, stopped
        assert departed == stopped, departed
        if corridor: assert verified_parked_packet == stopped, 'Parked vehicle packet coverage missing'
        assert service.boarded_total >= 6, service.boarded_total
        for station in service.stations:
            assert traci.lane.getAllowed(station['edge']+'_1') != ('pedestrian',)
        print(f"TRANSIT PASS {'corridor' if corridor else 'single'}: {len(stopped)} stops, {service.boarded_total} actual boardings, {len(departed)} departures")
        if replay_path:
            Path(replay_path).write_text(json.dumps(packets))
    finally:
        traci.close()



def check_internal_departure():
    """A bus beyond its stop can retain that edge's route index in a junction."""
    traci.start([str(Path(sumo.SUMO_HOME) / 'bin/sumo'), '-c', str(ROOT/'simulation/corridor.sumocfg'),
                 '--no-step-log', '--no-warnings', '--seed', '179'])
    try:
        traci.route.add('qa_late_route',['ACH_J0toJ1','ACH_J1toJ2'])
        traci.vehicle.add('00_late_bus','qa_late_route',typeID='trotro',departPos='260',departSpeed='5',departLane='1')
        service = TrotroService(traci,corridor=True)
        reached_internal = False
        for _ in range(180):
            traci.simulationStep()
            if '00_late_bus' in traci.vehicle.getIDList() and traci.vehicle.getRoadID('00_late_bus').startswith(':'):
                service.tick()
                assert '00_late_bus' not in service.assignments
                assert '00_late_bus' not in service.completed, 'An invalid stop was attempted and rejected'
                reached_internal = True
                break
        assert reached_internal, 'Did not exercise junction internals'
        print('TRANSIT PASS internal departure: no stop scheduled behind the bus')
    finally:
        traci.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--replay')
    parser.add_argument('--corridor-replay')
    args = parser.parse_args()
    run(False, args.replay)
    run(True, args.corridor_replay)
    check_internal_departure()
