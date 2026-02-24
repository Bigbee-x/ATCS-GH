#!/usr/bin/env python3
"""
ATCS-GH Phase 2 | DQN Training Script
═══════════════════════════════════════
Trains the DQN agent for N_EPISODES using the SUMO simulation.

Each episode:
  1. Resets the SUMO environment (fresh simulation, varied seed)
  2. Runs 7200 simulation-seconds with the agent making decisions every 5s
  3. Stores transitions in the replay buffer and performs gradient updates
  4. Decays epsilon (exploration rate)
  5. Prints a one-line progress summary

Usage:
    python scripts/train_agent.py                    # train from scratch
    python scripts/train_agent.py --episodes 100     # more training
    python scripts/train_agent.py --resume ai/checkpoints/dqn_ep010.pth

Outputs:
    ai/best_model.pth         — best checkpoint by avg wait time
    ai/trained_model.pth      — final model after all episodes
    ai/checkpoints/dqn_eXXX.pth  — periodic checkpoints
    data/training_log.csv     — per-episode metrics
"""

import sys
import csv
import time
import argparse
from pathlib import Path
from datetime import datetime

# ── Path setup ────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from traffic_env import TrafficEnv, STATE_SIZE, ACTION_SIZE
from dqn_agent   import DQNAgent

# ── Training configuration ────────────────────────────────────────────────────
DEFAULT_EPISODES  = 75
CHECKPOINT_FREQ   = 10          # save checkpoint every N episodes
LOG_FILE          = PROJECT_ROOT / "data"  / "training_log.csv"
CHECKPOINT_DIR    = PROJECT_ROOT / "ai"    / "checkpoints"
BEST_MODEL_PATH   = PROJECT_ROOT / "ai"    / "best_model.pth"
FINAL_MODEL_PATH  = PROJECT_ROOT / "ai"    / "trained_model.pth"

# Phase 1 baseline — loaded dynamically from baseline CSV (falls back to hardcoded)
BASELINE_CSV = PROJECT_ROOT / "data" / "baseline_results.csv"


def _load_baseline_avg_wait() -> float:
    """Load average wait time from Phase 1 baseline CSV."""
    if not BASELINE_CSV.exists():
        print(f"[WARN] Baseline CSV not found, using fallback value 399.12s.")
        return 399.12
    try:
        import csv
        with open(BASELINE_CSV, "r") as f:
            reader = csv.DictReader(f)
            waits = [float(r["avg_wait_time_s"]) for r in reader]
        return round(sum(waits) / len(waits), 2) if waits else 399.12
    except Exception as e:
        print(f"[WARN] Could not parse baseline CSV: {e}. Using fallback 399.12s.")
        return 399.12


BASELINE_AVG_WAIT = _load_baseline_avg_wait()


# ── Training loop ─────────────────────────────────────────────────────────────

def train(n_episodes:   int  = DEFAULT_EPISODES,
          resume_from:  str  | None = None,
          gui:          bool = False) -> None:
    """
    Main training loop.

    Args:
        n_episodes:  Number of episodes to train.
        resume_from: Optional checkpoint path to resume from.
        gui:         If True, launch SUMO-GUI (very slow — debugging only).
    """
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    # ── Initialise agent ─────────────────────────────────────────────────────
    agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)

    start_episode = 1
    if resume_from:
        agent.load(resume_from)
        # Estimate which episode we're resuming from (rough)
        print(f"[TRAIN] Resuming from {resume_from}  (ε={agent.epsilon:.3f})")

    # ── Initialise environment ────────────────────────────────────────────────
    env = TrafficEnv(gui=gui, verbose=False)

    log_rows:       list[dict] = []
    best_avg_wait:  float      = float("inf")
    training_start: float      = time.time()
    _csv_header_written: bool  = False      # track incremental CSV state

    print("\n" + "═" * 72)
    print("  ATCS-GH Phase 2 — DQN Training")
    print("═" * 72)
    print(f"  Device       : {agent.device}")
    print(f"  Episodes     : {n_episodes}")
    print(f"  State size   : {STATE_SIZE}  |  Action size: {ACTION_SIZE}")
    print(f"  Batch size   : {DQNAgent.BATCH_SIZE}  |  Buffer: {DQNAgent.BUFFER_SIZE:,}")
    print(f"  ε start/min  : {DQNAgent.EPSILON_START} → {DQNAgent.EPSILON_MIN}")
    print(f"  Baseline     : avg wait = {BASELINE_AVG_WAIT}s  (Phase 1 fixed timer)")
    print(f"  Checkpoints  : every {CHECKPOINT_FREQ} episodes → {CHECKPOINT_DIR.name}/")
    print("═" * 72)
    print(f"\n  {'Ep':>5}  {'Reward':>10}  {'Avg Wait':>9}  {'Peak Q':>7}  "
          f"{'ε':>6}  {'Δ Baseline':>11}  {'Time':>6}  Note")
    print("  " + "─" * 68)

    for episode in range(start_episode, start_episode + n_episodes):
        ep_start = time.time()

        # Vary the SUMO seed each episode to prevent overfitting
        seed  = episode * 137     # deterministic but varied per episode
        state = env.reset(seed=seed)
        done  = False

        # ── Episode rollout ───────────────────────────────────────────────────
        while not done:
            action                         = agent.select_action(state)
            next_state, reward, done, info = env.step(action)
            agent.remember(state, action, reward, next_state, done)
            agent.learn()
            state = next_state

        env.close()
        agent.decay_epsilon()

        # ── Collect episode stats ─────────────────────────────────────────────
        avg_wait     = env.episode_avg_wait
        total_reward = env.episode_total_reward
        peak_queue   = env.episode_peak_queue
        ep_time      = time.time() - ep_start
        delta_pct    = (avg_wait - BASELINE_AVG_WAIT) / BASELINE_AVG_WAIT * 100

        emerg_max    = max(env.emergency_log.values(), default=0.0)

        # ── Save best model ───────────────────────────────────────────────────
        note = ""
        if avg_wait < best_avg_wait:
            best_avg_wait = avg_wait
            agent.save(BEST_MODEL_PATH)
            note = "★ best"

        # ── Periodic checkpoint ───────────────────────────────────────────────
        if episode % CHECKPOINT_FREQ == 0:
            ckpt_path = CHECKPOINT_DIR / f"dqn_ep{episode:03d}.pth"
            agent.save(ckpt_path)
            if not note:
                note = "ckpt"

        # ── Logging ───────────────────────────────────────────────────────────
        row = {
            "episode":               episode,
            "total_reward":          round(total_reward, 1),
            "avg_wait_s":            round(avg_wait, 2),
            "peak_queue":            peak_queue,
            "epsilon":               round(agent.epsilon, 4),
            "max_emerg_wait_s":      round(emerg_max, 1),
            "delta_vs_baseline_pct": round(delta_pct, 1),
            "episode_time_s":        round(ep_time, 1),
        }
        log_rows.append(row)

        # Write CSV incrementally so data survives crashes
        if not _csv_header_written:
            with open(LOG_FILE, "w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=list(row.keys()))
                writer.writeheader()
                writer.writerow(row)
            _csv_header_written = True
        else:
            with open(LOG_FILE, "a", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=list(row.keys()))
                writer.writerow(row)

        # ── Progress line ─────────────────────────────────────────────────────
        direction = "▲" if delta_pct > 0 else "▼"
        print(f"  {episode:>5}  "
              f"{total_reward:>10,.0f}  "
              f"{avg_wait:>8.1f}s  "
              f"{peak_queue:>7}  "
              f"{agent.epsilon:>6.3f}  "
              f"  {direction}{abs(delta_pct):>7.1f}%  "
              f"{ep_time:>5.0f}s  "
              f"{note}")

    # ── Save final model and log ──────────────────────────────────────────────
    agent.save(FINAL_MODEL_PATH)
    _save_log(log_rows)

    total_wall = time.time() - training_start
    _print_summary(log_rows, best_avg_wait, total_wall)

    env.close()


# ── Helpers ───────────────────────────────────────────────────────────────────

def _save_log(rows: list[dict]) -> None:
    """Write per-episode training log to CSV."""
    with open(LOG_FILE, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"\n[TRAIN] Training log saved → {LOG_FILE}")


def _print_summary(rows: list[dict],
                   best_avg_wait: float,
                   wall_seconds: float) -> None:
    """Print a formatted summary after all episodes complete."""
    n = len(rows)
    if n == 0:
        return

    n_first = min(5, n)
    n_last  = min(5, n)
    first_avg = sum(r["avg_wait_s"] for r in rows[:n_first]) / n_first
    last_avg  = sum(r["avg_wait_s"] for r in rows[-n_last:])  / n_last
    improvement = (first_avg - last_avg) / first_avg * 100 if first_avg > 0 else 0.0
    vs_baseline = (best_avg_wait - BASELINE_AVG_WAIT) / BASELINE_AVG_WAIT * 100

    print("\n" + "═" * 62)
    print("  ATCS-GH — TRAINING COMPLETE")
    print("═" * 62)
    print(f"  Finished at   : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Episodes      : {n}")
    print(f"  Wall time     : {wall_seconds/60:.1f} minutes  "
          f"({wall_seconds/n:.0f}s per episode)")
    print()
    print(f"  Avg wait — first {n_first} eps : {first_avg:.1f}s  "
          f"(exploration / random policy)")
    print(f"  Avg wait — last  {n_last} eps : {last_avg:.1f}s  "
          f"(learned policy)")
    print(f"  Improvement over training   : {improvement:.1f}%")
    print()
    print(f"  Best avg wait     : {best_avg_wait:.1f}s")
    print(f"  Baseline avg wait : {BASELINE_AVG_WAIT:.1f}s")
    print(f"  vs Baseline       : {vs_baseline:+.1f}%  "
          f"({'BETTER ✓' if vs_baseline < 0 else 'needs more training'})")
    print()
    print(f"  Saved models:")
    print(f"    Best  → {BEST_MODEL_PATH.relative_to(PROJECT_ROOT)}")
    print(f"    Final → {FINAL_MODEL_PATH.relative_to(PROJECT_ROOT)}")
    print()
    print(f"  Run the trained AI:")
    print(f"    python scripts/run_ai.py")
    print(f"    python scripts/run_ai.py --model ai/best_model.pth")
    print("═" * 62 + "\n")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="ATCS-GH Phase 2: Train the DQN traffic signal controller"
    )
    parser.add_argument(
        "--episodes", type=int, default=DEFAULT_EPISODES,
        help=f"Number of training episodes (default: {DEFAULT_EPISODES})"
    )
    parser.add_argument(
        "--resume", type=str, default=None,
        metavar="CHECKPOINT",
        help="Path to a .pth checkpoint to resume training from"
    )
    parser.add_argument(
        "--gui", action="store_true",
        help="Run SUMO with GUI during training (very slow — for debugging only)"
    )
    args = parser.parse_args()
    train(n_episodes=args.episodes, resume_from=args.resume, gui=args.gui)
