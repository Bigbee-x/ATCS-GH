#!/usr/bin/env python3
from __future__ import annotations
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
    ai/best_model.pth         — best checkpoint by worst-scenario relative wait (maximin)
    ai/trained_model.pth      — final model after all episodes
    ai/checkpoints/dqn_eXXX.pth  — periodic checkpoints
    data/training_log.csv     — per-episode metrics
"""

import sys
import csv
import time
import random
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
DEFAULT_EPISODES  = 250
CHECKPOINT_FREQ   = 10          # save checkpoint every N episodes
LOG_FILE          = PROJECT_ROOT / "data"  / "training_log.csv"
CHECKPOINT_DIR    = PROJECT_ROOT / "ai"    / "checkpoints"
BEST_MODEL_PATH   = PROJECT_ROOT / "ai"    / "best_model.pth"
FINAL_MODEL_PATH  = PROJECT_ROOT / "ai"    / "trained_model.pth"

# ── Multi-scenario training ──────────────────────────────────────────────────
SCENARIO_DIR = PROJECT_ROOT / "simulation" / "scenarios"
# v2/v4 (2026-06-13): the continuous DAY is the centerpiece — quiet → morning
# rush (N-heavy) → midday lull → evening rush (S-heavy) → quiet, teaching the
# transitions and the directional flip the old constant-demand scenarios never
# showed. BUT the day only holds each peak ~20 min, so a pure-day model gridlocks
# a SUSTAINED 2-hr evening rush (v3 eval: evening 1084s). So we keep the constant
# morning/evening/weekend scenarios alongside the day to harden the sustained
# extremes. Best of both: realistic transitions + sustained-peak robustness.
# heavy_emergency dropped — ambulance feature torn out 2026-06-13.
SCENARIOS = [
    SCENARIO_DIR / "continuous_day.rou.xml",   # centerpiece — realism + transitions
    SCENARIO_DIR / "morning_rush.rou.xml",     # sustained N-heavy peak
    SCENARIO_DIR / "continuous_day.rou.xml",
    SCENARIO_DIR / "evening_rush.rou.xml",     # sustained S-heavy peak (the v3 gap)
    SCENARIO_DIR / "weekend_market.rou.xml",   # E-heavy market
]

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

# ── Per-scenario fair grading ─────────────────────────────────────────────────
# The single global baseline above was measured on ONE demand profile, so it
# made rush-hour episodes look like failures (graded against off-peak traffic).
# Instead, grade each episode against ITS OWN scenario's fixed-timer baseline —
# the naive 60/30 timer the AI is meant to beat. Produced by
# scripts/_per_scenario_baselines.py → data/scenario_baselines.csv.
SCENARIO_BASELINE_CSV = PROJECT_ROOT / "data" / "scenario_baselines.csv"


def _load_scenario_baselines() -> dict[str, float]:
    """{scenario_stem: fixed-timer avg wait}. Empty dict falls back to global."""
    out: dict[str, float] = {}
    if SCENARIO_BASELINE_CSV.exists():
        try:
            with open(SCENARIO_BASELINE_CSV) as f:
                for r in csv.DictReader(f):
                    try:
                        out[r["scenario"]] = float(r["baseline_avg_wait_s"])
                    except (ValueError, KeyError):
                        pass
        except Exception as e:                                   # noqa: BLE001
            print(f"[WARN] Could not parse scenario baselines: {e}")
    return out


SCENARIO_BASELINES = _load_scenario_baselines()

# Selection-only floor on the normalizing baseline. off_peak's real baseline is
# tiny (14.2s), so its relative score has a high noise floor — a 6s↔8s wobble
# (both excellent in absolute terms) swings its rel 0.43↔0.55 and can out-shout
# a 20s improvement on evening_rush in the maximin. Flooring the DENOMINATOR at
# one minute means "solved" light-traffic scenarios stop driving selection
# unless their absolute waits actually degrade toward 60s. Set to 0 to recover
# pure baseline normalization. Logging/Δ% always use the true baseline.
MIN_SELECT_BASELINE_S = 60.0

# Only judge "best" once exploration is mostly off. Early windows score well
# partly because the EXPERT is driving (at ε=0.4, ~40% of actions aren't the
# network's) — replaying run 4's log, the maximin's last save landed at ep 36
# where ε≈0.41, an expert-propped window. Gating on ε keeps selection honest:
# windows must reflect the network's own (near-greedy) behaviour, matching how
# best_model.pth is actually deployed (ε=0).
MAX_SELECT_EPSILON = 0.10

# Warm-start: during exploration, this fraction follows the sustained-green
# expert (env.expert_action) instead of a uniform-random action, so heavy
# episodes keep flowing and the agent learns to HOLD greens rather than thrash.
EXPERT_FRAC = 0.70


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

    # ── Multi-scenario rotation ─────────────────────────────────────────────
    n_scenarios = len(SCENARIOS)

    log_rows:       list[dict] = []
    # "Best model" selection — worst-case-aware (maximin), not single-episode.
    # FIX (2026-06-07): the old code saved best_model.pth whenever ANY single
    # episode beat the running best avg_wait. With a 5-scenario rotation that
    # meant the "best" model was just a snapshot taken right after a lucky
    # off-peak episode (3s wait) — not a model that's good across rush hour too.
    # FIX (2026-06-11): the rolling MEAN of raw waits still under-weighted the
    # hardest scenario — run 4 selected a checkpoint scoring 22.8s/11.3s/6.2s on
    # morning/weekend/off_peak but 475s on evening_rush (WORSE than its 427s
    # fixed-timer baseline), while other checkpoints held evening at ~296s with
    # minimal loss elsewhere. Now each episode's avg_wait is normalized by its
    # scenario's fixed-timer baseline (rel = avg_wait / baseline, floored at
    # MIN_SELECT_BASELINE_S — lower is better) and "best" means the WORST
    # per-scenario rolling relative score improved, tie-breaking on the mean —
    # no scenario can be sacrificed to flatter the average.
    BEST_WINDOW:    int        = 2 * n_scenarios     # 10 eps = 2 full rotations
    recent_rel:     list[tuple[str, float]] = []     # (scenario, wait / baseline)
    best_score:     tuple[float, float] = (float("inf"), float("inf"))  # (worst, mean)
    training_start: float      = time.time()
    _csv_header_written: bool  = False      # track incremental CSV state

    print("\n" + "═" * 72)
    print("  ATCS-GH Phase 2 — DQN Multi-Scenario Training")
    print("═" * 72)
    print(f"  Device       : {agent.device}")
    print(f"  Episodes     : {n_episodes}")
    print(f"  Scenarios    : {n_scenarios} (rotating each episode)")
    for s in SCENARIOS:
        print(f"                 • {s.stem}")
    print(f"  State size   : {STATE_SIZE}  |  Action size: {ACTION_SIZE}")
    print(f"  Batch size   : {DQNAgent.BATCH_SIZE}  |  Buffer: {DQNAgent.BUFFER_SIZE:,}")
    print(f"  ε start/min  : {DQNAgent.EPSILON_START} → {DQNAgent.EPSILON_MIN}")
    if SCENARIO_BASELINES:
        print(f"  Grading      : per-scenario fixed-timer baselines "
              f"({len(SCENARIO_BASELINES)} loaded — naive timer to beat)")
    else:
        print(f"  Baseline     : avg wait = {BASELINE_AVG_WAIT}s  (global fallback)")
    print(f"  Warm-start   : sustained-green expert at {EXPERT_FRAC:.0%} of exploration")
    print(f"  Best select  : maximin — save when the WORST per-scenario relative "
          f"wait over the last {BEST_WINDOW} eps improves "
          f"(baselines floored at {MIN_SELECT_BASELINE_S:.0f}s, "
          f"gated to ε ≤ {MAX_SELECT_EPSILON})")
    print(f"  Checkpoints  : every {CHECKPOINT_FREQ} episodes → {CHECKPOINT_DIR.name}/")
    print("═" * 72)
    print(f"\n  {'Ep':>5}  {'Scenario':>16}  {'Reward':>10}  {'Avg Wait':>9}  {'Peak Q':>7}  "
          f"{'ε':>6}  {'Δ Baseline':>11}  {'Time':>6}  Note")
    print("  " + "─" * 88)

    for episode in range(start_episode, start_episode + n_episodes):
        ep_start = time.time()

        # Rotate through scenarios so agent sees all demand patterns
        scenario_path = SCENARIOS[(episode - 1) % n_scenarios]
        # .stem of "morning_rush.rou.xml" is "morning_rush.rou" (only the last
        # suffix drops); strip ".rou" so it matches scenario_baselines.csv keys.
        scenario_name = scenario_path.stem.replace(".rou", "")

        # Create environment with this episode's scenario route file
        env = TrafficEnv(gui=gui, verbose=False, route_file=str(scenario_path))

        # Vary the SUMO seed each episode to prevent overfitting
        seed  = episode * 137     # deterministic but varied per episode
        state = env.reset(seed=seed)
        done  = False

        # ── Episode rollout ───────────────────────────────────────────────────
        while not done:
            # Guided ε-exploration: explore mostly via the sustained-green expert
            # (warm-start) so heavy episodes keep flowing and the agent learns to
            # HOLD greens; otherwise exploit the learned policy.
            if random.random() < agent.epsilon:
                action = (env.expert_action()
                          if random.random() < EXPERT_FRAC
                          else random.randrange(ACTION_SIZE))
            else:
                action = agent.greedy_action(state)
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
        scenario_baseline = SCENARIO_BASELINES.get(scenario_name, BASELINE_AVG_WAIT)
        delta_pct    = (avg_wait - scenario_baseline) / scenario_baseline * 100

        # ── Save best model (maximin over rolling per-scenario relative score) ─
        note = ""
        sel_base = max(scenario_baseline, MIN_SELECT_BASELINE_S)
        recent_rel.append((scenario_name, avg_wait / sel_base))
        if len(recent_rel) > BEST_WINDOW:
            recent_rel.pop(0)
        # Only judge "best" once we have a full window spanning every scenario
        # (so a single easy episode can't trigger a save) AND exploration is
        # near-greedy (so the window reflects the network, not the expert).
        if len(recent_rel) >= BEST_WINDOW and agent.epsilon <= MAX_SELECT_EPSILON:
            rel_by_scen: dict[str, list[float]] = {}
            for scen, rel in recent_rel:
                rel_by_scen.setdefault(scen, []).append(rel)
            scen_means = [sum(v) / len(v) for v in rel_by_scen.values()]
            score = (max(scen_means), sum(scen_means) / len(scen_means))
            if score < best_score:               # worst first, mean breaks ties
                best_score = score
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
            "scenario":              scenario_name,
            "total_reward":          round(total_reward, 1),
            "avg_wait_s":            round(avg_wait, 2),
            "peak_queue":            peak_queue,
            "epsilon":               round(agent.epsilon, 4),
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
              f"{scenario_name:>16}  "
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
    _print_summary(log_rows, best_score, total_wall)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _save_log(rows: list[dict]) -> None:
    """Write per-episode training log to CSV."""
    with open(LOG_FILE, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"\n[TRAIN] Training log saved → {LOG_FILE}")


def _print_summary(rows: list[dict],
                   best_score: tuple[float, float],
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
    if best_score[0] == float("inf"):
        print(f"  Best checkpoint   : none saved (run shorter than warm-up window)")
    else:
        print(f"  Best checkpoint   : worst scenario {best_score[0]:.2f}x baseline "
              f"(mean {best_score[1]:.2f}x; baselines floored at "
              f"{MIN_SELECT_BASELINE_S:.0f}s) — maximin over rolling window")
    print()
    print(f"  Per-scenario — mean of last 3 episodes vs each scenario's naive timer:")
    by_scen: dict[str, list[float]] = {}
    for r in rows:
        by_scen.setdefault(r["scenario"], []).append(r["avg_wait_s"])
    wins = 0
    for scen, waits in by_scen.items():
        last = waits[-3:] if len(waits) >= 3 else waits
        ai   = sum(last) / len(last)
        base = SCENARIO_BASELINES.get(scen, BASELINE_AVG_WAIT)
        d    = (ai - base) / base * 100
        beat = d < 0
        wins += int(beat)
        print(f"    {scen:>17}: AI {ai:>7.1f}s  vs timer {base:>7.1f}s  "
              f"{d:>+6.1f}%  {'✓ beats' if beat else '✗'}")
    print(f"\n  AI beats the naive fixed timer on {wins}/{len(by_scen)} scenarios")
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
