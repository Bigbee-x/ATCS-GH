#!/usr/bin/env python3
"""
Multi-seed robustness evaluation — the "is it cherry-picked?" answer.

The official evals (`_eval_best.py`, `eval_corridor.py --compare`) run one seed.
This harness re-runs the deployable models greedy (ε=0), full 7200 s, across
N seeds per scenario, for BOTH systems:

  • single junction — ai/best_model.pth on all 5 scenarios
  • corridor        — ai/checkpoints/corridor/best_J{0,1,2}.pth on all 3

and reports mean ± std vs the recorded fixed-timer baselines
(data/scenario_baselines.csv, data/corridor_baselines.csv). Raw rows land in
data/multi_seed_eval.csv so the numbers are auditable.

    python scripts/multi_seed_eval.py                # 5 seeds (default)
    python scripts/multi_seed_eval.py --seeds 3      # quicker pass
"""
from __future__ import annotations

import sys
import csv
import time
import argparse
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ai"))
sys.path.insert(0, str(ROOT / "scripts"))

SEED_LIST = [11, 42, 137, 1024, 20260610]
OUT_CSV = ROOT / "data" / "multi_seed_eval.csv"

SJ_SCENARIOS = ["continuous_day", "morning_rush", "evening_rush",
                "weekend_market", "off_peak"]
CR_SCENARIOS = {
    "corridor_morning": ROOT / "simulation" / "corridor_routes.rou.xml",
    "corridor_evening": ROOT / "simulation" / "corridor_routes_evening.rou.xml",
    "corridor_offpeak": ROOT / "simulation" / "corridor_routes_offpeak.rou.xml",
}


def eval_single_junction(seeds: list[int], rows: list[dict]) -> None:
    import traffic_env
    from traffic_env import TrafficEnv, STATE_SIZE, ACTION_SIZE
    from dqn_agent import DQNAgent

    traffic_env.SIM_DURATION = 7200
    baselines = {r["scenario"]: float(r["baseline_avg_wait_s"])
                 for r in csv.DictReader(open(ROOT / "data" / "scenario_baselines.csv"))}

    agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
    agent.load(str(ROOT / "ai" / "best_model.pth"))
    agent.set_eval_mode()

    print("\n" + "=" * 78)
    print("  SINGLE JUNCTION — best_model.pth, greedy, 7200s, %d seeds" % len(seeds))
    print("=" * 78)
    print(f"  {'scenario':>16} {'mean':>8} {'±std':>7} {'worst':>8} "
          f"{'baseline':>9} {'improvement':>12}")
    print("  " + "-" * 68)
    for sc in SJ_SCENARIOS:
        waits: list[float] = []
        for seed in seeds:
            env = TrafficEnv(gui=False, verbose=False,
                             route_file=str(ROOT / "simulation" / "scenarios" / f"{sc}.rou.xml"))
            state, done = env.reset(seed=seed), False
            while not done:
                state, _, done, _ = env.step(agent.greedy_action(state))
            env.close()
            waits.append(env.episode_avg_wait)
            rows.append({"system": "single", "scenario": sc, "kind": "model",
                         "seed": seed, "avg_wait_s": f"{env.episode_avg_wait:.2f}"})
        m = statistics.mean(waits)
        sd = statistics.stdev(waits) if len(waits) > 1 else 0.0
        worst = max(waits)
        b = baselines.get(sc, 0.0)
        imp = (m - b) / b * 100 if b else 0.0
        print(f"  {sc:>16} {m:>7.1f}s {sd:>6.1f}s {worst:>7.1f}s "
              f"{b:>8.1f}s {imp:>+11.1f}%", flush=True)


def eval_corridor(seeds: list[int], rows: list[dict]) -> None:
    from eval_corridor import evaluate_model

    baselines = {r["label"]: float(r["corridor_avg_wait_s"])
                 for r in csv.DictReader(open(ROOT / "data" / "corridor_baselines.csv"))}
    model_dir = ROOT / "ai" / "checkpoints" / "corridor"

    print("\n" + "=" * 78)
    print("  CORRIDOR — best_J{0,1,2}.pth, greedy, 7200s, %d seeds" % len(seeds))
    print("=" * 78)
    print(f"  {'scenario':>16} {'mean':>8} {'±std':>7} {'worst':>8} "
          f"{'baseline':>9} {'improvement':>12}")
    print("  " + "-" * 68)
    for label, route in CR_SCENARIOS.items():
        waits = []
        for seed in seeds:
            r = evaluate_model(model_dir, seed=seed, verbose=False, route=str(route))
            waits.append(r["corridor_avg_wait"])
            rows.append({"system": "corridor", "scenario": label, "kind": "model",
                         "seed": seed, "avg_wait_s": f"{r['corridor_avg_wait']:.2f}"})
        m = statistics.mean(waits)
        sd = statistics.stdev(waits) if len(waits) > 1 else 0.0
        worst = max(waits)
        b = baselines.get(label, 0.0)
        imp = (m - b) / b * 100 if b else 0.0
        print(f"  {label:>16} {m:>7.1f}s {sd:>6.1f}s {worst:>7.1f}s "
              f"{b:>8.1f}s {imp:>+11.1f}%", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description="Multi-seed robustness eval")
    ap.add_argument("--seeds", type=int, default=5,
                    help="Number of seeds from the fixed list (default 5, max %d)"
                         % len(SEED_LIST))
    args = ap.parse_args()
    seeds = SEED_LIST[: max(1, min(args.seeds, len(SEED_LIST)))]

    t0 = time.time()
    rows: list[dict] = []
    eval_single_junction(seeds, rows)
    eval_corridor(seeds, rows)

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["system", "scenario", "kind", "seed",
                                          "avg_wait_s"])
        w.writeheader()
        w.writerows(rows)

    print("\n  Raw rows → %s" % OUT_CSV.relative_to(ROOT))
    print("  Wall time: %.1f min" % ((time.time() - t0) / 60.0))


if __name__ == "__main__":
    main()
