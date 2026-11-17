#!/usr/bin/env python3
"""Observation, model-bundle and sensor-boundary regressions (no SUMO socket)."""
from pathlib import Path
import copy
import json
import sys
import tempfile
import unittest
from types import SimpleNamespace
import numpy as np
import torch
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'ai'),str(ROOT/'scripts')]
import tsh1_schema
import traffic_env
from tsh1_interface import ARMS,SCHEMA,state_from_frames,LaneSpeedBlend,TSH1Receiver,FrameValidationError
from corridor_bundle import settings,write_manifest
from corridor_env import CorridorEnv
from train_corridor_deployment import calibration_factor
from crossing_safety import CrossingSafety
from corridor_env import JUNCTIONS


def frames(time=100,limited=True):
    return [{'schema':SCHEMA,'junction':'J0','arm':arm,'edge':cfg['edge'],
             'sample_time':time,'range_m':200.0 if limited else None,
             'corner':{'area':cfg['corner'],'persons':1},
             'lanes':[{'lane':lane,'lane_length_m':1500.0,'speed_limit_ms':13.89,'vehicles':2,
                       'halting':1,'wait_sum_s':10.0,'window_speed_ms':5.0,'queue_at_range_edge':False,
                       'tracks':[{'track':lane+':a','distance_m':190.0,'speed_ms':10.0},
                                 {'track':lane+':b','distance_m':10.0,'speed_ms':0.0}]} for lane in cfg['lanes']]}
            for arm,cfg in ARMS.items()]

class Contracts(unittest.TestCase):
    def test_crossing_guard_preserves_right_turn_yellow(self):
        occupied=set()
        api=SimpleNamespace(simulation=SimpleNamespace(getTime=lambda:0),
            edge=SimpleNamespace(getLastStepPersonIDs=lambda edge: ['ped'] if edge in occupied else []),
            trafficlight=SimpleNamespace(setRedYellowGreenState=lambda *args:None))
        for network, configs in [('intersection',{'J0':traffic_env.PHASE_SIGNALS}),
                                  ('corridor',{j:c.phase_signals for j,c in JUNCTIONS.items()})]:
            guard=CrossingSafety(api,ROOT/f'simulation/{network}.net.xml')
            for phase in (2,5):
                requested={j:signals[phase] for j,signals in configs.items()}
                guard.apply(requested)
                for j,links in guard.links.items():
                    for index,link in links.items():
                        if link['dir']=='r' and requested[j][index] in 'yY':
                            self.assertEqual(guard.states[j][index],requested[j][index])
            for phase in (1,4):
                guard.apply({j:signals[phase] for j,signals in configs.items()})
                for j,links in guard.links.items():
                    for index,link in links.items():
                        if link['dir']=='r': self.assertEqual(guard.states[j][index],'r')
    def test_sensor_constants_match_single_junction_abi(self):
        for name in ('TL_ID','INCOMING_EDGES','INCOMING_LANES','WALKING_AREAS','NUM_PHASES','STATE_SIZE',
                     'MAX_QUEUE_LANE','MAX_SPEED','MAX_WAIT','MAX_QUEUE','MAX_PHASE_T','MAX_PED_QUEUE'):
            self.assertEqual(getattr(tsh1_schema,name),getattr(traffic_env,name),name)
    def test_window_speed_cannot_silently_replace_whole_lane_speed(self):
        with self.assertRaisesRegex(FrameValidationError,'Whole-lane speed'): state_from_frames(frames(),0,10)
        self.assertEqual(state_from_frames(frames(),0,10,speed_field='window_speed_ms').shape,(41,))
    def test_estimator_needs_only_wire_frames(self):
        class ForbiddenOracle:
            def __getattr__(self,name): raise AssertionError('Simulator queried: '+name)
        observed=LaneSpeedBlend(200).blend(ForbiddenOracle(),frames())
        hidden=(1/120)*1300/10
        expected=(10+hidden*10)/(2+hidden)
        self.assertAlmostEqual(observed[0]['lanes'][0]['lane_speed_ms'],expected)
        self.assertEqual(observed[0]['lanes'][0]['speed_basis'],'estimated_whole_lane')
        self.assertEqual(state_from_frames(observed,0,10,now=100).shape,(41,))
    def test_missing_duplicate_wrong_lane_or_corner_rejected(self):
        malformed=[]
        f=frames(limited=False); f.pop(); malformed.append(f)
        f=frames(limited=False); f[1]=copy.deepcopy(f[0]); malformed.append(f)
        f=frames(limited=False); f[0]['lanes'][0]['lane']='WRONG'; malformed.append(f)
        f=frames(limited=False); del f[0]['corner']['persons']; malformed.append(f)
        for f in malformed:
            with self.assertRaises(FrameValidationError): state_from_frames(f,0,10)
    def test_invalid_counts_and_nonfinite_values_rejected(self):
        for key,value in [('halting',3),('vehicles',-1),('window_speed_ms',float('nan')),('wait_sum_s',float('inf'))]:
            f=frames(limited=False); f[0]['lanes'][0][key]=value
            with self.assertRaises(FrameValidationError): state_from_frames(f,0,10)
    def test_freshness_sync_and_replay_gate(self):
        receiver=TSH1Receiver(); f=frames(limited=False)
        receiver.state(f,0,10,now=100)
        with self.assertRaisesRegex(FrameValidationError,'Duplicate'): receiver.state(f,0,10,now=101)
        with self.assertRaisesRegex(FrameValidationError,'Stale'): receiver.state(frames(101,False),0,10,now=105)
        f=frames(limited=False); f[0]['sample_time']=99
        with self.assertRaisesRegex(FrameValidationError,'synchronized'): state_from_frames(f,0,10,now=100)
    def test_truncated_queue_requires_explicit_research_opt_in(self):
        f=LaneSpeedBlend(200).update(frames()); f[0]['lanes'][0]['queue_at_range_edge']=True
        with self.assertRaisesRegex(FrameValidationError,'boundary'): TSH1Receiver().state(f,0,10,now=100)
        self.assertEqual(state_from_frames(f,0,10,allow_truncated=True).shape,(41,))
    def test_estimator_does_not_double_count_replayed_frames(self):
        blend=LaneSpeedBlend(200); blend.update(frames())
        with self.assertRaisesRegex(FrameValidationError,'advancing'): blend.update(frames())
    def test_bad_batch_cannot_change_estimator_history(self):
        blend=LaneSpeedBlend(200)
        bad=frames(); bad[-1]['lanes'][-1]['tracks'][0]['distance_m']=201
        with self.assertRaises(FrameValidationError): blend.update(bad)
        self.assertFalse(blend.entries); self.assertFalse(blend.seen)
        blend.update(frames())
    def test_model_manifest_rejects_feature_and_checkpoint_mismatch(self):
        with tempfile.TemporaryDirectory() as d:
            directory=Path(d)
            for j in ('J0','J1','J2'): (directory/f'best_{j}.pth').write_bytes(j.encode())
            write_manifest(directory,'fullness')
            self.assertEqual(settings(directory)['occupancy_feature'],'fullness')
            (directory/'best_J1.pth').write_bytes(b'different training run')
            with self.assertRaisesRegex(ValueError,'J1 checkpoint'): settings(directory)
    def test_input_configuration_is_per_environment(self):
        legacy=CorridorEnv(occupancy_feature='legacy'); full=CorridorEnv(occupancy_feature='fullness')
        self.assertEqual(legacy.occupancy_feature,'legacy'); self.assertEqual(full.occupancy_feature,'fullness')
        with self.assertRaises(ValueError): CorridorEnv(occupancy_feature='percent')
    def test_calibration_preserves_first_layer_for_unsaturated_links(self):
        torch.manual_seed(1)
        layer=torch.nn.Linear(46,256)
        transferred=copy.deepcopy(layer)
        factor=calibration_factor()
        with torch.no_grad(): transferred.weight[:,45].mul_(factor)
        new=torch.rand(64,46); old=new.clone(); old[:,45]*=factor
        torch.testing.assert_close(layer(old),transferred(new),rtol=1e-6,atol=1e-7)

if __name__=='__main__':unittest.main(verbosity=2)
