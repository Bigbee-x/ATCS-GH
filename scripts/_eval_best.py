#!/usr/bin/env python3
"""Official deployable eval: best_model.pth, pure greedy (eps=0), full 7200s,
every scenario, vs the real per-scenario naive-timer baselines."""
import sys, time, csv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai"))
import traffic_env
from traffic_env import TrafficEnv, STATE_SIZE, ACTION_SIZE
from dqn_agent import DQNAgent

traffic_env.SIM_DURATION = 7200
SC = ROOT / "simulation" / "scenarios"
BASE = {r["scenario"]: float(r["baseline_avg_wait_s"])
        for r in csv.DictReader(open(ROOT / "data" / "scenario_baselines.csv"))}
ORDER = ["morning_rush", "evening_rush", "heavy_emergency", "weekend_market", "off_peak"]

agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
agent.load(str(ROOT / "ai" / "best_model.pth"))
agent.set_eval_mode()      # epsilon = 0

print("=" * 76)
print("  OFFICIAL EVAL — ai/best_model.pth, greedy, full 7200s")
print("=" * 76)
print(f"  {'scenario':>16} {'AI':>9} {'naive timer':>12} {'improvement':>12} {'peak_q':>7}")
print("  " + "-" * 64)
wins = 0
for s in ORDER:
    env = TrafficEnv(gui=False, verbose=False, route_file=str(SC / f"{s}.rou.xml"))
    state, done = env.reset(seed=20260610), False
    while not done:
        state, _, done, _ = env.step(agent.greedy_action(state))
    env.close()
    ai, pk = env.episode_avg_wait, env.episode_peak_queue
    b = BASE.get(s, 0)
    d = (ai - b) / b * 100
    wins += ai < b
    print(f"  {s:>16} {ai:>8.1f}s {b:>11.1f}s {d:>+11.1f}%  {pk:>7}", flush=True)
print("=" * 76)
print(f"  best_model.pth beats the naive fixed timer on {wins}/{len(ORDER)} scenarios")
print("=" * 76)
