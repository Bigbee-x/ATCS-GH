#!/usr/bin/env python3
"""
ATCS-GH | Multi-Agent Corridor Training
═════════════════════════════════════════
Train 3 independent DQN agents to control the N6 Nsawam Road corridor.

Each junction (J0, J1, J2) has its own DQN agent with a 50-dim state
vector that includes neighbor awareness. Agents learn independently
but share the same simulation, enabling emergent green-wave coordination.

Usage:
    python scripts/train_corridor.py                    # Train 200 episodes
    python scripts/train_corridor.py --episodes 100     # Custom episode count
    python scripts/train_corridor.py --resume            # Resume from checkpoint
"""

import os
import sys
import csv
import time
import argparse
from pathlib import Path

# Add project roots
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))

import numpy as np
from dqn_agent import DQNAgent
from corridor_env import (
    CorridorEnv, JUNCTION_IDS, STATE_SIZE, ACTION_SIZE,
    PHASE_NAMES, ACTION_NAMES,
)


# ── Paths ─────────────────────────────────────────────────────────────────────
CHECKPOINT_DIR = PROJECT_ROOT / "ai" / "checkpoints" / "corridor"
LOG_DIR        = PROJECT_ROOT / "logs"
LOG_FILE       = LOG_DIR / "corridor_training_log.csv"


def train(n_episodes: int = 200, start_episode: int = 0,
          resume: bool = False) -> None:
    """Train multi-agent DQN for the corridor."""

    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    # ── Create agents ────────────────────────────────────────────────────────
    agents: dict[str, DQNAgent] = {}
    for jid in JUNCTION_IDS:
        agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
        if resume:
            ckpt = CHECKPOINT_DIR / f"best_{jid}.pth"
            if ckpt.exists():
                agent.load(str(ckpt))
                print(f"[TRAIN] {jid}: Resumed from {ckpt.name} "
                      f"(epsilon={agent.epsilon:.3f})")
            else:
                print(f"[TRAIN] {jid}: No checkpoint found, starting fresh")
        agents[jid] = agent

    # ── Create environment ───────────────────────────────────────────────────
    env = CorridorEnv(verbose=False)

    # ── CSV logger ───────────────────────────────────────────────────────────
    csv_fields = [
        "episode", "seed", "sim_steps", "total_arrived",
        "corridor_avg_wait", "corridor_total_reward",
        "J0_avg_wait", "J0_reward", "J0_epsilon",
        "J1_avg_wait", "J1_reward", "J1_epsilon",
        "J2_avg_wait", "J2_reward", "J2_epsilon",
        "duration_s",
    ]
    write_header = not LOG_FILE.exists() or not resume
    csv_file = open(LOG_FILE, "a" if resume else "w", newline="")
    csv_writer = csv.DictWriter(csv_file, fieldnames=csv_fields)
    if write_header:
        csv_writer.writeheader()

    # ── Training tracking ────────────────────────────────────────────────────
    best_corridor_wait = float("inf")
    best_episode = -1

    print("=" * 70)
    print(f"  ATCS-GH Corridor Training — {n_episodes} episodes")
    print(f"  Junctions: {JUNCTION_IDS}")
    print(f"  State size: {STATE_SIZE} | Action size: {ACTION_SIZE}")
    print(f"  Checkpoints: {CHECKPOINT_DIR}")
    print("=" * 70)

    for ep in range(start_episode, start_episode + n_episodes):
        ep_start = time.time()
        seed = ep * 137 + 7  # Deterministic, varied per episode

        states = env.reset(seed=seed)
        done = False
        step_count = 0

        while not done:
            # All agents select actions
            actions = {}
            for jid in JUNCTION_IDS:
                actions[jid] = agents[jid].select_action(states[jid])

            # Environment step
            next_states, rewards, done, infos = env.step(actions)

            # All agents learn
            for jid in JUNCTION_IDS:
                agents[jid].remember(
                    states[jid], actions[jid], rewards[jid],
                    next_states[jid], done
                )
                agents[jid].learn()

            states = next_states
            step_count += 1

        # Decay epsilon for all agents
        for jid in JUNCTION_IDS:
            agents[jid].decay_epsilon()

        # ── Episode metrics ──────────────────────────────────────────────────
        duration = time.time() - ep_start
        c_wait = env.corridor_avg_wait()
        c_reward = env.corridor_total_reward()

        # Per-junction metrics
        j_waits = {}
        j_rewards = {}
        for jid in JUNCTION_IDS:
            j_waits[jid] = (float(np.mean(env.episode_waits[jid]))
                            if env.episode_waits[jid] else 0.0)
            j_rewards[jid] = sum(env.episode_rewards[jid])

        # Log to CSV
        row = {
            "episode": ep,
            "seed": seed,
            "sim_steps": env._sim_step,
            "total_arrived": env.total_arrived,
            "corridor_avg_wait": f"{c_wait:.2f}",
            "corridor_total_reward": f"{c_reward:.1f}",
            "J0_avg_wait": f"{j_waits['J0']:.2f}",
            "J0_reward": f"{j_rewards['J0']:.1f}",
            "J0_epsilon": f"{agents['J0'].epsilon:.4f}",
            "J1_avg_wait": f"{j_waits['J1']:.2f}",
            "J1_reward": f"{j_rewards['J1']:.1f}",
            "J1_epsilon": f"{agents['J1'].epsilon:.4f}",
            "J2_avg_wait": f"{j_waits['J2']:.2f}",
            "J2_reward": f"{j_rewards['J2']:.1f}",
            "J2_epsilon": f"{agents['J2'].epsilon:.4f}",
            "duration_s": f"{duration:.1f}",
        }
        csv_writer.writerow(row)
        csv_file.flush()

        # ── Checkpointing ────────────────────────────────────────────────────
        # Save best model (by corridor avg wait)
        if c_wait < best_corridor_wait:
            best_corridor_wait = c_wait
            best_episode = ep
            for jid in JUNCTION_IDS:
                agents[jid].save(str(CHECKPOINT_DIR / f"best_{jid}.pth"))

        # Periodic checkpoint every 10 episodes
        if (ep + 1) % 10 == 0:
            for jid in JUNCTION_IDS:
                agents[jid].save(
                    str(CHECKPOINT_DIR / f"corridor_{jid}_ep{ep+1:03d}.pth")
                )

        # ── Console output ───────────────────────────────────────────────────
        print(f"Ep {ep:3d} | wait={c_wait:6.1f}s | arrived={env.total_arrived:4d} "
              f"| R={c_reward:+8.0f} | "
              f"J0={j_waits['J0']:5.1f}s J1={j_waits['J1']:5.1f}s "
              f"J2={j_waits['J2']:5.1f}s | "
              f"ε={agents['J0'].epsilon:.3f} | "
              f"{duration:.0f}s"
              f"{'  ★ BEST' if ep == best_episode else ''}")

    # ── Cleanup ──────────────────────────────────────────────────────────────
    csv_file.close()
    env.close()

    print("\n" + "=" * 70)
    print(f"  Training complete!")
    print(f"  Best corridor avg wait: {best_corridor_wait:.1f}s (episode {best_episode})")
    print(f"  Models saved: {CHECKPOINT_DIR}")
    print(f"  Log: {LOG_FILE}")
    print("=" * 70)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train corridor multi-agent DQN")
    parser.add_argument("--episodes", type=int, default=200,
                        help="Number of episodes (default: 200)")
    parser.add_argument("--resume", action="store_true",
                        help="Resume from latest checkpoint")
    parser.add_argument("--start-episode", type=int, default=0,
                        help="Starting episode number (for resume)")
    args = parser.parse_args()

    train(
        n_episodes=args.episodes,
        start_episode=args.start_episode,
        resume=args.resume,
    )
