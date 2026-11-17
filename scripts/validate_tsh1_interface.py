#!/usr/bin/env python3
"""TSH-1 interface check (single junction): 30 simulated minutes of the morning
rush with ai/best_model.pth. An ideal, unlimited-range head must rebuild the
agent's 41 inputs bit-for-bit at every decision, and the 200 m head's whole-lane
speed estimate is reported against SUMO's value. Exits non-zero on a mismatch.

    .venv/bin/python scripts/validate_tsh1_interface.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
import numpy as np
import traffic_env
from traffic_env import TrafficEnv, STATE_SIZE, ACTION_SIZE
from dqn_agent import DQNAgent
import traci
from tsh1_interface import emulate_arm_frames, state_from_frames, LaneSpeedBlend, SCHEMA

traffic_env.SIM_DURATION = 1800
agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
agent.load(str(ROOT / "ai" / "best_model.pth"))
agent.set_eval_mode()
env = TrafficEnv(route_file=str(ROOT / "simulation" / "scenarios" / "morning_rush.rou.xml"))
state = env.reset(seed=20260610)
blend = LaneSpeedBlend(200.0)
n = exact = 0
errs = []
done = False
frames = []
while not done:
    ideal = state_from_frames(emulate_arm_frames(traci, None), env._phase, env._phase_timer)
    exact += int(np.array_equal(ideal, state))
    frames = blend.blend(traci, emulate_arm_frames(traci, 200.0, detail=True))
    est = state_from_frames(frames, env._phase, env._phase_timer, allow_truncated=True)
    errs.append(float(np.mean(np.abs(est[8:16] - state[8:16]))) * traffic_env.MAX_SPEED)
    n += 1
    state, _, done, _ = env.step(agent.greedy_action(state))
env.close()
print(f"schema {frames[0]['schema'] == SCHEMA} | decisions {n} | exact round trip {exact}"
      f" | mean lane-speed error {np.mean(errs):.2f} m/s (200 m head, estimated)")
sys.exit(0 if exact == n and frames[0]["schema"] == SCHEMA else 1)
