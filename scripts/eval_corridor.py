#!/usr/bin/env python3
"""
TrafIQ | Corridor Evaluation Script
═════════════════════════════════════
Evaluates trained multi-agent DQN corridor models against baseline.

Usage:
    python scripts/eval_corridor.py                         # Evaluate best models
    python scripts/eval_corridor.py --seeds 5               # Average over 5 seeds
    python scripts/eval_corridor.py --gui                   # Watch in SUMO GUI
    python scripts/eval_corridor.py --compare               # Also run baseline
"""

import os
import sys
import argparse
from pathlib import Path
import numpy as np

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from corridor_env import (
    CorridorEnv, JUNCTION_IDS, STATE_SIZE, ACTION_SIZE,
    ACTION_HOLD, ACTION_NAMES,
)
from dqn_agent import DQNAgent
from corridor_runtime import CorridorRuntime
from corridor_bundle import settings as policy_settings


def resolve_route(route):
    if route is None: return None
    path = Path(route)
    if not path.is_absolute() and not path.is_file():
        path = PROJECT_ROOT/'simulation'/path
    if not path.is_file(): raise FileNotFoundError(path)
    return str(path.resolve())


def evaluate_model(model_dir: Path, seed: int = 42, gui: bool = False,
                   verbose: bool = True, route: str | None = None,
                   supervised: bool = True, transit: bool = True) -> dict:
    """Run one evaluation episode with trained corridor models.

    Args:
        model_dir: Directory containing best_J0.pth, best_J1.pth, best_J2.pth
        seed: Random seed
        gui: Use SUMO GUI
        verbose: Print per-step info
        route: optional scenario route file (overrides corridor.sumocfg's default)

    Returns:
        Dict with evaluation metrics
    """
    # Load agents
    config = policy_settings(model_dir)
    agents = {}
    for jid in JUNCTION_IDS:
        agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE, device='cpu')
        model_path = model_dir / f"best_{jid}.pth"
        if model_path.exists():
            agent.load(str(model_path))
            agent.set_eval_mode()
            if verbose:
                print(f"  {jid}: Loaded {model_path.name}")
        else:
            print(f"  [WARN] {jid}: Model not found at {model_path}")
            return None
        agents[jid] = agent

    # Run evaluation episode
    env = CorridorEnv(gui=gui, verbose=False, route_file=resolve_route(route), occupancy_feature=config['occupancy_feature'])
    states = env.reset(seed=seed)
    runtime = CorridorRuntime(env, transit_enabled=transit, supervise=supervised,
                              graded_exit_capacity=config['graded_exit_capacity'])
    done = False
    step_count = 0

    while not done:
        # Protected-left action space — no sanitizing needed.
        actions = {
            jid: agents[jid].select_action(runtime.policy_state(states[jid]))
            for jid in JUNCTION_IDS
        }
        actions = runtime.select_actions(actions)
        states, rewards, done, infos = env.step(actions)
        step_count += 1

        if verbose and step_count % 100 == 0:
            j0_info = infos["J0"]
            print(f"  Step {step_count}: "
                  f"J0 wait={j0_info['avg_wait']:.1f}s  "
                  f"J1 wait={infos['J1']['avg_wait']:.1f}s  "
                  f"J2 wait={infos['J2']['avg_wait']:.1f}s")

    # Collect results
    results = {
        "total_arrived": env.total_arrived,
        "corridor_avg_wait": env.corridor_avg_wait(),  # legacy score, retained for existing CSV consumers
        "legacy_wait_score": env.corridor_avg_wait(),
        "corridor_total_reward": env.corridor_total_reward(),
        "sim_steps": env._sim_step,
        "controller": "dqn_supervised" if supervised else "raw_dqn",
        **runtime.traffic_metrics(),
    }

    for jid in JUNCTION_IDS:
        jwaits = env.episode_waits[jid]
        results[f"{jid}_avg_wait"] = float(np.mean(jwaits)) if jwaits else 0.0
        results[f"{jid}_total_reward"] = sum(env.episode_rewards[jid])

    env.close()
    return results


def main():
    parser = argparse.ArgumentParser(description="Evaluate corridor DQN models")
    parser.add_argument(
        "--model-dir", type=str,
        default=str(PROJECT_ROOT / "ai" / "checkpoints" / "corridor"),
        help="Directory with corridor models (default: ai/checkpoints/corridor/)"
    )
    parser.add_argument("--gui", action="store_true", help="Use SUMO GUI")
    parser.add_argument("--seed", type=int, default=42, help="Base random seed")
    parser.add_argument("--seeds", type=int, default=1,
                        help="Number of seeds to average over")
    parser.add_argument("--compare", action="store_true",
                        help="Also run baseline for comparison")
    parser.add_argument("--raw-dqn", action="store_true", help="Audit the unprotected checkpoint policy (pedestrian clearance remains active)")
    parser.add_argument("--no-transit", action="store_true", help="Ablate boarding services")
    parser.add_argument("--route", help="Scenario route file, used by both AI and matched fixed timer")
    args = parser.parse_args()
    args.route = resolve_route(args.route)

    model_dir = Path(args.model_dir)

    print()
    print("=" * 70)
    print("  TrafIQ | Corridor Multi-Agent DQN Evaluation")
    print("=" * 70)
    print(f"  Model dir : {model_dir}")
    print(f"  Seeds     : {args.seeds}")
    print()

    # ── Run AI evaluation ────────────────────────────────────────────────────
    ai_results = []
    for i in range(args.seeds):
        seed = args.seed + i * 137
        print(f"--- AI Evaluation (seed={seed}) ---")
        r = evaluate_model(model_dir, seed=seed, gui=args.gui, verbose=True, route=args.route,
                           supervised=not args.raw_dqn, transit=not args.no_transit)
        if r is None:
            print("  FAILED: Models not found")
            return
        ai_results.append(r)

        print(f"  Arrived: {r['total_arrived']}")
        print(f"  Mean stopped vehicles: {r['mean_stopped_vehicles']:.1f}")
        for jid in JUNCTION_IDS:
            print(f"  {jid}: legacy wait score={r[f'{jid}_avg_wait']:.1f}  "
                  f"reward={r[f'{jid}_total_reward']:.0f}")
        print()

    # ── Run baseline comparison ──────────────────────────────────────────────
    if args.compare:
        from diagnose_corridor import run as run_audit
        from argparse import Namespace

        print("=" * 70)
        print("  Baseline Comparison (Fixed Timer)")
        print("=" * 70)

        base_results = []
        for i in range(args.seeds):
            seed = args.seed + i * 137
            print(f"\n--- Baseline (seed={seed}) ---")
            audit = run_audit(Namespace(controller="fixed", route=args.route or "corridor_routes.rou.xml", duration=7200,
                seed=seed, clearance=True, transit=not args.no_transit, stations=None, output=None))
            r = {"total_arrived": audit["arrived"], "corridor_avg_wait": audit["legacy_wait_score"],
                 # evaluate_model measures the steps after reset's initial
                 # second, so use that same elapsed-step denominator here.
                 "mean_stopped_vehicles": audit["stopped_vehicle_seconds"]/max(audit["duration"]-1,1),
                 **{f"{jid}_avg_wait": audit["junction_wait_score"][jid] for jid in JUNCTION_IDS}}
            base_results.append(r)
            print(f"  Arrived: {r['total_arrived']}")
            print(f"  Mean stopped vehicles: {r['mean_stopped_vehicles']:.1f}")

        base_avg = np.mean([r["mean_stopped_vehicles"] for r in base_results])
        print(f"\n  Baseline mean stopped vehicles: {base_avg:.1f}")

    # ── Summary ──────────────────────────────────────────────────────────────
    ai_avg = np.mean([r["mean_stopped_vehicles"] for r in ai_results])
    ai_std = np.std([r["mean_stopped_vehicles"] for r in ai_results]) if len(ai_results) > 1 else 0.0
    ai_arrived = np.mean([r["total_arrived"] for r in ai_results])

    print()
    print("=" * 70)
    print("  RESULTS SUMMARY")
    print("=" * 70)
    print(f"  AI mean stopped vehicles : {ai_avg:.1f}" +
          (f" +/- {ai_std:.1f}" if ai_std > 0 else ""))
    print(f"  AI vehicles arrived  : {ai_arrived:.0f}")

    if args.compare:
        improvement = (base_avg - ai_avg) / max(base_avg, 1e-9) * 100
        print(f"  Baseline mean stopped    : {base_avg:.1f}")
        print(f"  Improvement          : {improvement:.1f}%")
        print()
        if improvement > 0:
            print(f"  >>> AI reduced stopped vehicle-seconds by {improvement:.1f}% <<<")
        else:
            print(f"  >>> Baseline was better by {-improvement:.1f}% <<<")

    print("=" * 70)
    print()


if __name__ == "__main__":
    main()
