#!/usr/bin/env python3
"""
ATCS-GH | Corridor Evaluation Script
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
    sanitize_action,
)
from dqn_agent import DQNAgent


def evaluate_model(model_dir: Path, seed: int = 42, gui: bool = False,
                   verbose: bool = True) -> dict:
    """Run one evaluation episode with trained corridor models.

    Args:
        model_dir: Directory containing best_J0.pth, best_J1.pth, best_J2.pth
        seed: Random seed
        gui: Use SUMO GUI
        verbose: Print per-step info

    Returns:
        Dict with evaluation metrics
    """
    # Load agents
    agents = {}
    for jid in JUNCTION_IDS:
        agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
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
    env = CorridorEnv(gui=gui, verbose=False)
    states = env.reset(seed=seed)
    done = False
    step_count = 0

    while not done:
        # Collapse permissive-left actions (NS_ALL/EW_ALL) to protected-through
        # so eval mirrors the baseline's protected-left phasing.
        actions = {
            jid: sanitize_action(agents[jid].select_action(states[jid]))
            for jid in JUNCTION_IDS
        }
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
        "corridor_avg_wait": env.corridor_avg_wait(),
        "corridor_total_reward": env.corridor_total_reward(),
        "sim_steps": env._sim_step,
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
    args = parser.parse_args()

    model_dir = Path(args.model_dir)

    print()
    print("=" * 70)
    print("  ATCS-GH | Corridor Multi-Agent DQN Evaluation")
    print("=" * 70)
    print(f"  Model dir : {model_dir}")
    print(f"  Seeds     : {args.seeds}")
    print()

    # ── Run AI evaluation ────────────────────────────────────────────────────
    ai_results = []
    for i in range(args.seeds):
        seed = args.seed + i * 137
        print(f"--- AI Evaluation (seed={seed}) ---")
        r = evaluate_model(model_dir, seed=seed, gui=args.gui, verbose=True)
        if r is None:
            print("  FAILED: Models not found")
            return
        ai_results.append(r)

        print(f"  Arrived: {r['total_arrived']}")
        print(f"  Corridor avg wait: {r['corridor_avg_wait']:.1f}s")
        for jid in JUNCTION_IDS:
            print(f"  {jid}: wait={r[f'{jid}_avg_wait']:.1f}s  "
                  f"reward={r[f'{jid}_total_reward']:.0f}")
        print()

    # ── Run baseline comparison ──────────────────────────────────────────────
    if args.compare:
        from run_corridor_baseline import run_baseline

        print("=" * 70)
        print("  Baseline Comparison (Fixed Timer)")
        print("=" * 70)

        base_results = []
        for i in range(args.seeds):
            seed = args.seed + i * 137
            print(f"\n--- Baseline (seed={seed}) ---")
            r = run_baseline(gui=False, offset=0.0, seed=seed)
            base_results.append(r)
            print(f"  Arrived: {r['total_arrived']}")
            print(f"  Corridor avg wait: {r['corridor_avg_wait']:.1f}s")

        base_avg = np.mean([r["corridor_avg_wait"] for r in base_results])
        print(f"\n  Baseline avg wait: {base_avg:.1f}s")

    # ── Summary ──────────────────────────────────────────────────────────────
    ai_avg = np.mean([r["corridor_avg_wait"] for r in ai_results])
    ai_std = np.std([r["corridor_avg_wait"] for r in ai_results]) if len(ai_results) > 1 else 0.0
    ai_arrived = np.mean([r["total_arrived"] for r in ai_results])

    print()
    print("=" * 70)
    print("  RESULTS SUMMARY")
    print("=" * 70)
    print(f"  AI corridor avg wait : {ai_avg:.1f}s" +
          (f" +/- {ai_std:.1f}s" if ai_std > 0 else ""))
    print(f"  AI vehicles arrived  : {ai_arrived:.0f}")

    if args.compare:
        improvement = (base_avg - ai_avg) / base_avg * 100
        print(f"  Baseline avg wait    : {base_avg:.1f}s")
        print(f"  Improvement          : {improvement:.1f}%")
        print()
        if improvement > 0:
            print(f"  >>> AI reduced corridor wait by {improvement:.1f}% <<<")
        else:
            print(f"  >>> Baseline was better by {-improvement:.1f}% <<<")

    print("=" * 70)
    print()


if __name__ == "__main__":
    main()
