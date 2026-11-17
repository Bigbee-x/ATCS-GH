"""Control regressions: starvation, capacity, phase stability and yellow timing."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'ai'),str(ROOT/'scripts')]
from corridor_env import (CorridorEnv,JUNCTION_IDS,NS_THROUGH,NS_LEFT,NS_YELLOW,EW_THROUGH,EW_LEFT)
from corridor_controller import CorridorController,PHASES

class ControllerChecks(unittest.TestCase):
    def make_controller(self, timer=20):
        env=CorridorEnv()
        c=CorridorController(env,None)
        c.time=100.0
        c.observations={j:{'movements':{p:{'score':0.0,'vehicles':0,'serviceable':0,'oldest':0.0,'pedestrians':0} for p in PHASES},'receiving':{}} for j in JUNCTION_IDS}
        c.observe=lambda:c.observations
        for j in JUNCTION_IDS:env._jstate[j].phase_timer=timer
        return env,c
    def demand(self,c,phase,score=10,age=0,pedestrian=False):
        for j in JUNCTION_IDS:
            c.observations[j]['movements'][phase].update(score=score,vehicles=0 if pedestrian else 4,serviceable=0 if pedestrian else 1,oldest=age,pedestrians=1 if pedestrian else 0)
    def actions(self,c,proposal=1):return c.decide({j:proposal for j in JUNCTION_IDS})
    def test_starved_movement_overrides_repeated_dqn_green(self):
        env,c=self.make_controller(45)
        self.demand(c,NS_THROUGH,100)
        self.demand(c,EW_THROUGH,10,95)
        self.assertEqual(set(self.actions(c).values()),{3})
    def test_maximum_green_with_competing_demand(self):
        env,c=self.make_controller(96)
        self.demand(c,NS_THROUGH,100)
        self.demand(c,EW_THROUGH,5)
        self.assertEqual(set(self.actions(c).values()),{3})
    def test_blocked_exit_cannot_win_by_dqn_preference(self):
        env,c=self.make_controller()
        self.demand(c,EW_THROUGH,10)
        self.assertEqual(set(self.actions(c).values()),{3})
    def test_large_competing_queue_gets_service_before_starvation(self):
        env,c=self.make_controller()
        self.demand(c,NS_THROUGH,2)
        self.demand(c,EW_THROUGH,40)
        self.assertEqual(set(self.actions(c).values()),{3})
    def test_minimum_green_cannot_be_overridden_by_pressure(self):
        env,c=self.make_controller(5)
        self.demand(c,EW_THROUGH,100,120)
        self.assertEqual(set(self.actions(c,3).values()),{0})
    def test_small_pressure_difference_does_not_chop_green(self):
        env,c=self.make_controller(12)
        self.demand(c,NS_THROUGH,10)
        self.demand(c,EW_THROUGH,11)
        self.assertEqual(set(self.actions(c,3).values()),{0})
    def test_waiting_people_receive_service_without_cars(self):
        env,c=self.make_controller()
        self.demand(c,EW_THROUGH,10,100,True)
        self.assertEqual(set(self.actions(c).values()),{3})
    def test_sensor_saturation_and_invalid_values_stay_finite(self):
        state=np.zeros(46,dtype=np.float32)
        state[:5]=[500,-1,np.nan,np.inf,0.25]
        bounded=CorridorController.policy_state(state)
        np.testing.assert_array_equal(bounded[:5],[1,0,0,1,0.25])
        self.assertEqual(bounded.shape,(46,))
    def test_yellow_lasts_three_complete_physics_steps(self):
        env=CorridorEnv()
        observed=[]
        with patch('corridor_env.traci') as api:
            api.simulation.getArrivedNumber.return_value=0
            env._initiate_switch('J0',EW_THROUGH)
            env.before_step=lambda:observed.append(env._jstate['J0'].phase)
            for _ in range(4):env.advance_one_second()
        self.assertEqual(observed,[NS_YELLOW,NS_YELLOW,NS_YELLOW,EW_THROUGH])

if __name__=='__main__': unittest.main(verbosity=2)
