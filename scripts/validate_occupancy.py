"""Occupancy regressions: SUMO's 0..1 scale, sidewalk lanes and reachable limits.

Fills corridor link ACH_J0toJ1 with stopped cars, starting 30 m past J0 so the
supervisor's "tail within 12 m" rule cannot be what flags it, and checks that
the env's state slot 45, its spillback reward and the supervisor's blocked
exits all see a jammed road. Uses a route file with vehicle types only, so no
other traffic takes part.
"""
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'ai'), str(ROOT / 'scripts')]
import corridor_env
from corridor_env import CorridorEnv, JUNCTIONS, EW_THROUGH, SPILLBACK_THRESH, W_SPILLBACK
from corridor_controller import CorridorController
from occupancy import (JAM_OCCUPANCY, LinkOccupancy, fullness_from_occupancy,
                       legacy_link_feature)
import traci

LINK = 'ACH_J0toJ1'          # northbound J0 -> J1, 279 m, sidewalk lane 0 + two vehicle lanes
CAR = ('<vType id="car" accel="2.6" decel="4.5" emergencyDecel="9.0" sigma="0.5" '
       'length="4.5" minGap="2.5" maxSpeed="19.44"/>')


class FakeLanes:
    """Just enough TraCI for LinkOccupancy without a running SUMO."""
    def __init__(self, allowed, occupancy):
        self.edge = self
        self.lane = self
        self._allowed, self._occupancy = allowed, occupancy
    def getLaneNumber(self, edge): return len(self._allowed)
    def getAllowed(self, lane): return self._allowed[int(lane.rsplit('_', 1)[1])]
    def getLastStepOccupancy(self, lane): return self._occupancy[int(lane.rsplit('_', 1)[1])]


class Scale(unittest.TestCase):
    def test_fullness_reaches_one_at_a_car_jam(self):
        self.assertAlmostEqual(fullness_from_occupancy(JAM_OCCUPANCY), 1.0)
        self.assertEqual(fullness_from_occupancy(0.0), 0.0)
        self.assertEqual(fullness_from_occupancy(0.9), 1.0)       # trotro jams cap at 1
        self.assertEqual(fullness_from_occupancy(-0.1), 0.0)

    def test_sidewalk_lane_is_not_averaged_in(self):
        api = FakeLanes([('pedestrian',), (), ('passenger', 'bus')], [0.0, JAM_OCCUPANCY, JAM_OCCUPANCY])
        links = LinkOccupancy()
        self.assertEqual(links.vehicle_lanes(api, 'L'), ['L_1', 'L_2'])
        self.assertAlmostEqual(links.fullness(api, 'L'), 1.0)


class JammedLink(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        routes = Path(cls.tmp.name) / 'types_only.rou.xml'
        routes.write_text(f'<routes>{CAR}</routes>')
        cls.env = CorridorEnv(route_file=str(routes))
        cls.env.reset(seed=1)
        # Hold J1's south approach at red so the queue stays on the link.
        traci.trafficlight.setRedYellowGreenState('J1', JUNCTIONS['J1'].phase_signals[EW_THROUGH])
        traci.route.add('jam', [LINK, 'ACH_J1toJ2'])
        cls.cars = []
        for lane in (1, 2):
            for i in range(35):                       # fronts at 34.5 .. 272.5 m, 7 m apart
                vid = f'jam_{lane}_{i}'
                traci.vehicle.add(vid, 'jam', typeID='car', departLane=str(lane),
                                  departPos=f'{34.5 + 7.0 * i:.1f}', departSpeed='0')
                cls.cars.append(vid)
        traci.simulationStep()
        for vid in cls.cars:
            traci.vehicle.setSpeed(vid, 0.0)
        for _ in range(3):
            traci.simulationStep()

    @classmethod
    def tearDownClass(cls):
        cls.env.close()
        cls.tmp.cleanup()

    def test_all_cars_are_parked_on_the_link(self):
        on_link = [v for v in traci.vehicle.getIDList() if traci.vehicle.getRoadID(v) == LINK]
        self.assertEqual(len(on_link), 70)
        self.assertTrue(all(traci.vehicle.getSpeed(v) < 0.1 for v in on_link))

    def test_sumo_occupancy_is_already_a_fraction(self):
        lane = f'{LINK}_1'
        ids = traci.lane.getLastStepVehicleIDs(lane)
        lengths = sum(traci.vehicle.getLength(v) for v in ids) / traci.lane.getLength(lane)
        self.assertAlmostEqual(traci.lane.getLastStepOccupancy(lane), lengths, places=3)
        self.assertGreater(fullness_from_occupancy(traci.lane.getLastStepOccupancy(lane)), 0.85)

    def test_state_slot_45(self):
        legacy = self.env._build_state('J0')[45]
        self.assertAlmostEqual(float(legacy), legacy_link_feature(traci, LINK), places=6)
        self.assertLess(legacy, 0.01)                 # what the shipped checkpoints see
        corridor_env.LINK_OCCUPANCY_FEATURE = 'fullness'
        try:
            fixed = self.env._build_state('J0')[45]
        finally:
            corridor_env.LINK_OCCUPANCY_FEATURE = 'legacy'
        self.assertGreater(fixed, 0.85)

    def test_spillback_reward_fires(self):
        full = self.env._links.fullness(traci, LINK)
        self.assertGreater(full, SPILLBACK_THRESH)
        reward = self.env._compute_corridor_reward('J0')
        self.assertAlmostEqual(reward, -W_SPILLBACK * (full - SPILLBACK_THRESH), places=6)

    def test_supervisor_marks_the_exit_blocked(self):
        controller = CorridorController(self.env, None)
        receiving = controller.observe()['J0']['receiving']
        for lane in (f'{LINK}_1', f'{LINK}_2'):
            data = receiving[lane]
            self.assertTrue(data['blocked'], lane)
            self.assertEqual(data['capacity'], 0.0)
            self.assertGreater(data['fullness'], 0.85)
            self.assertLess(data['occupancy'] / 100.0, 0.85)   # the old reading never blocked


if __name__ == '__main__':
    unittest.main(verbosity=2)
