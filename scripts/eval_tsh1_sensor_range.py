#!/usr/bin/env python3
"""Does the shipped single-junction agent still work on what a TSH-1 head sees?

Runs ai/best_model.pth greedy over full 2-hour scenarios, feeding it states
rebuilt from emulated TSH-1 arm frames (ai/tsh1_interface.py):

  true           agent acts on SUMO's state; also checks the interface round
                 trip (ideal-range frames -> state must equal env._build_state)
                 and records what 200 m / 160 m heads would have reported
  r200, r160     agent acts on range-limited frames, speed measured in view
  r200_simspeed  diagnostic: 200 m frames but SUMO's whole-lane speed
  r200_blend,    range-limited frames with the head's whole-lane speed
  r160_blend     estimate (LaneSpeedBlend, Little's law)

    .venv/bin/python scripts/eval_tsh1_sensor_range.py r200_blend --seed 42

Results: logs/tsh1-sensor-range/results_<mode>[_s<seed>].json (gitignored).
The numbers recorded on 13 Nov 2026 are in docs/tsh1-sensor-interface.md.
"""
import argparse
import csv
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
import numpy as np
import traffic_env
from traffic_env import TrafficEnv, STATE_SIZE, ACTION_SIZE, MAX_QUEUE_LANE
from dqn_agent import DQNAgent
import traci
from tsh1_interface import emulate_arm_frames, state_from_frames, LaneSpeedBlend

MODES = {"true": None, "r200": 200.0, "r160": 160.0, "r200_simspeed": 200.0,
         "r200_blend": 200.0, "r160_blend": 160.0}
ALL_SCENARIOS = ["continuous_day", "morning_rush", "evening_rush", "weekend_market", "off_peak"]
OFFICIAL_SEED = 20260610   # scripts/_eval_best.py

p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument("mode", choices=sorted(MODES))
p.add_argument("--seed", type=int, default=OFFICIAL_SEED)
p.add_argument("--scenarios", nargs="*", default=ALL_SCENARIOS)
p.add_argument("--out", default=str(ROOT / "logs" / "tsh1-sensor-range"))
args = p.parse_args()
mode, RANGE, SEED = args.mode, MODES[args.mode], args.seed

traffic_env.SIM_DURATION = 7200
BASE = {r["scenario"]: float(r["baseline_avg_wait_s"])
        for r in csv.DictReader(open(ROOT / "data" / "scenario_baselines.csv"))}
agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
agent.load(str(ROOT / "ai" / "best_model.pth"))
agent.set_eval_mode()


def sensor_state(env, range_m):
    # Explicitly opt into the raw-window ablation; the deployed input gate must
    # never silently replace whole-lane speed with this different quantity.
    return state_from_frames(emulate_arm_frames(traci, range_m), env._phase, env._phase_timer,
                             speed_field='window_speed_ms', allow_truncated=True)


results = []
for sc in args.scenarios:
    t0 = time.time()
    env = TrafficEnv(gui=False, verbose=False, route_file=str(ROOT / "simulation" / "scenarios" / f"{sc}.rou.xml"))
    true_state = env.reset(seed=SEED)
    blender = LaneSpeedBlend(RANGE) if mode.endswith("_blend") else None
    stats = {"decisions": 0, "rt_max_abs_diff": 0.0, "rt_exact": 0,
             "beyond": {"200": 0, "160": 0}, "agree": {"200": 0, "160": 0},
             "max_true_lane_queue": 0, "max_seen_lane_queue": {"200": 0, "160": 0},
             "missed_halts_sum": {"200": 0, "160": 0}, "true_halts_sum": 0}
    done = False
    while not done:
        if mode == "true":
            ideal = sensor_state(env, None)
            stats["rt_max_abs_diff"] = max(stats["rt_max_abs_diff"], float(np.max(np.abs(ideal - true_state))))
            stats["rt_exact"] += int(np.array_equal(ideal, true_state))
            a_true = agent.greedy_action(true_state)
            true_lq = np.rint(true_state[:8] * MAX_QUEUE_LANE).astype(int)
            stats["max_true_lane_queue"] = max(stats["max_true_lane_queue"], int(true_lq.max()))
            stats["true_halts_sum"] += int(true_lq.sum())
            for r in (200.0, 160.0):
                key = str(int(r))
                s = sensor_state(env, r)
                seen_lq = np.rint(s[:8] * MAX_QUEUE_LANE).astype(int)
                stats["max_seen_lane_queue"][key] = max(stats["max_seen_lane_queue"][key], int(seen_lq.max()))
                stats["beyond"][key] += int((true_lq > seen_lq).any())
                stats["missed_halts_sum"][key] += int((true_lq - seen_lq).sum())
                stats["agree"][key] += int(agent.greedy_action(s) == a_true)
            action = a_true
        elif mode == "r200_simspeed":
            s = sensor_state(env, RANGE)
            s[8:16] = true_state[8:16]          # diagnostic: SUMO's whole-lane speed
            action = agent.greedy_action(s)
        elif blender is not None:
            frames = blender.blend(traci, emulate_arm_frames(traci, RANGE))
            s = state_from_frames(frames, env._phase, env._phase_timer, speed_field="lane_speed_ms", allow_truncated=True)
            stats.setdefault("speed_err", []).append(float(np.mean(np.abs(s[8:16] - true_state[8:16]))) * traffic_env.MAX_SPEED)
            stats.setdefault("raw_speed_err", []).append(
                float(np.mean(np.abs(sensor_state(env, RANGE)[8:16] - true_state[8:16]))) * traffic_env.MAX_SPEED)
            action = agent.greedy_action(s)
        else:
            action = agent.greedy_action(sensor_state(env, RANGE))
        stats["decisions"] += 1
        true_state, _, done, _ = env.step(action)
    env.close()
    row = {"scenario": sc, "mode": mode, "seed": SEED, "avg_wait_s": round(env.episode_avg_wait, 2),
           "peak_queue": env.episode_peak_queue, "arrived": env.total_arrived,
           "baseline_s": BASE.get(sc), "decisions": stats["decisions"], "seconds": round(time.time() - t0, 1)}
    if "speed_err" in stats:
        row["mean_abs_speed_err_blend_ms"] = round(float(np.mean(stats["speed_err"])), 2)
        row["mean_abs_speed_err_raw_window_ms"] = round(float(np.mean(stats["raw_speed_err"])), 2)
    if mode == "true":
        n = stats["decisions"]
        row.update({
            "round_trip_exact_pct": round(100 * stats["rt_exact"] / n, 2),
            "round_trip_max_abs_diff": stats["rt_max_abs_diff"],
            "pct_decisions_queue_beyond_200m": round(100 * stats["beyond"]["200"] / n, 1),
            "pct_decisions_queue_beyond_160m": round(100 * stats["beyond"]["160"] / n, 1),
            "action_agreement_200m_pct": round(100 * stats["agree"]["200"] / n, 1),
            "action_agreement_160m_pct": round(100 * stats["agree"]["160"] / n, 1),
            "max_true_lane_queue": stats["max_true_lane_queue"],
            "max_seen_lane_queue_200m": stats["max_seen_lane_queue"]["200"],
            "max_seen_lane_queue_160m": stats["max_seen_lane_queue"]["160"],
            "share_of_halted_vehicles_missed_200m_pct": round(100 * stats["missed_halts_sum"]["200"] / max(stats["true_halts_sum"], 1), 1),
            "share_of_halted_vehicles_missed_160m_pct": round(100 * stats["missed_halts_sum"]["160"] / max(stats["true_halts_sum"], 1), 1),
        })
    results.append(row)
    print(json.dumps(row), flush=True)

out_dir = Path(args.out)
out_dir.mkdir(parents=True, exist_ok=True)
name = f"results_{mode}.json" if SEED == OFFICIAL_SEED else f"results_{mode}_s{SEED}.json"
(out_dir / name).write_text(json.dumps(results, indent=1))
print("wrote", out_dir / name)
