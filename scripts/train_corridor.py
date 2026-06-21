#!/usr/bin/env python3
"""
ATCS-GH | Multi-Agent Corridor Training (v4 methodology)
═════════════════════════════════════════════════════════
Train 3 independent Double-DQN agents to control the N6 Nsawam Road corridor
(J0, J1, J2), each with a 46-dim neighbour-aware state. Agents learn
independently but share one simulation, enabling emergent green-wave coordination.

Ported up to the single-junction v4 methodology (2026-06-21, corridor Phase 3 —
mirrors scripts/train_agent.py):
  • Expert warm-start — during ε-exploration, EXPERT_FRAC of actions follow the
    per-junction sustained-green expert (env.expert_action(jid)) instead of a
    uniform-random action, so heavy episodes keep flowing and agents learn to
    HOLD greens rather than thrash.
  • Maximin best-model selection — save best_{jid}.pth when the WORST junction's
    rolling wait-relative-to-its-baseline improves (mean tie-break), with the
    normalising baseline floored at MIN_SELECT_BASELINE_S and selection gated to
    ε ≤ MAX_SELECT_EPSILON so the saved models reflect near-greedy (deployed)
    behaviour, not the expert-propped early window. Per-junction baselines come
    from data/corridor_baselines.csv (run scripts/run_corridor_baseline.py).
  • Scenario rotation — SCENARIOS rotates one route file per episode (only the
    recalibrated morning exists today; evening/off-peak slot in here later).

Usage:
    python scripts/train_corridor.py                 # 200 episodes, morning scenario
    python scripts/train_corridor.py --episodes 120
    python scripts/train_corridor.py --resume        # resume from best_{jid}.pth
"""

import sys
import csv
import time
import random
import argparse
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "ai"))

import numpy as np
from dqn_agent import DQNAgent
from corridor_env import (
    CorridorEnv, JUNCTION_IDS, STATE_SIZE, ACTION_SIZE,
)


# ── Paths ─────────────────────────────────────────────────────────────────────
CHECKPOINT_DIR = PROJECT_ROOT / "ai" / "checkpoints" / "corridor"
LOG_DIR        = PROJECT_ROOT / "logs"
LOG_FILE       = LOG_DIR / "corridor_training_log.csv"
SIM_DIR        = PROJECT_ROOT / "simulation"
BASELINES_CSV  = PROJECT_ROOT / "data" / "corridor_baselines.csv"

# ── Scenarios (rotated one per episode) ──────────────────────────────────────
# (label, route_file). Only the recalibrated morning rush exists today; add
# evening (N→S-heavy) / off_peak entries here for richer rotation. Each label
# must match a row in data/corridor_baselines.csv so every junction is graded
# against its own fixed-timer baseline.
SCENARIOS: list[tuple[str, Path]] = [
    ("corridor_morning", SIM_DIR / "corridor_routes.rou.xml"),
]

# ── Selection / warm-start knobs (mirror scripts/train_agent.py) ─────────────
CHECKPOINT_FREQ       = 10
EXPERT_FRAC           = 0.70   # fraction of exploration that follows the expert
MIN_SELECT_BASELINE_S = 60.0   # floor on the normalising baseline (selection only)
MAX_SELECT_EPSILON    = 0.10   # only judge "best" once exploration is near-off


def _load_baselines() -> dict[str, dict[str, float]]:
    """{scenario_label: {jid: fixed-timer baseline wait}} from corridor_baselines.csv."""
    out: dict[str, dict[str, float]] = {}
    if BASELINES_CSV.exists():
        try:
            with open(BASELINES_CSV) as f:
                for r in csv.DictReader(f):
                    label = r.get("label")
                    if not label:
                        continue
                    try:
                        out[label] = {jid: float(r[f"{jid}_wait_s"]) for jid in JUNCTION_IDS}
                    except (KeyError, ValueError):
                        pass
        except Exception as e:                                    # noqa: BLE001
            print(f"[WARN] Could not parse {BASELINES_CSV.name}: {e}")
    return out


def train(n_episodes: int = 200, resume: bool = False) -> None:
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    baselines = _load_baselines()
    n_scenarios = len(SCENARIOS)

    # ── Agents (one independent Double-DQN per junction) ──────────────────────
    agents: dict[str, DQNAgent] = {}
    for jid in JUNCTION_IDS:
        agent = DQNAgent(state_size=STATE_SIZE, action_size=ACTION_SIZE)
        if resume:
            ckpt = CHECKPOINT_DIR / f"best_{jid}.pth"
            if ckpt.exists():
                agent.load(str(ckpt))
                print(f"[TRAIN] {jid}: resumed from {ckpt.name} (ε={agent.epsilon:.3f})")
            else:
                print(f"[TRAIN] {jid}: no checkpoint, starting fresh")
        agents[jid] = agent

    # ── CSV logger ────────────────────────────────────────────────────────────
    csv_fields = [
        "episode", "scenario", "seed", "sim_steps", "total_arrived",
        "corridor_avg_wait", "corridor_total_reward",
        "J0_avg_wait", "J1_avg_wait", "J2_avg_wait",
        "worst_rel", "epsilon", "duration_s", "note",
    ]
    write_header = not LOG_FILE.exists() or not resume
    csv_file = open(LOG_FILE, "a" if resume else "w", newline="")
    csv_writer = csv.DictWriter(csv_file, fieldnames=csv_fields)
    if write_header:
        csv_writer.writeheader()

    # ── Best-model selection (maximin over JUNCTIONS, baseline-floored, ε-gated) ─
    # The corridor analog of train_agent's maximin-over-scenarios: J0 is far
    # harder than J1/J2, so "best" = the model set whose WORST junction's rolling
    # wait-relative-to-baseline is lowest (mean tie-break). Gated to ε ≤ 0.10 and
    # a full rolling window so the save reflects near-greedy behaviour, not the
    # expert-propped early episodes. (ε reaches 0.10 around episode ~91.)
    BEST_WINDOW = max(5, 2 * n_scenarios)
    recent_rel: list[dict[str, float]] = []      # per-episode {jid: wait / baseline}
    best_score: tuple[float, float] = (float("inf"), float("inf"))   # (worst, mean)
    best_episode = -1
    training_start = time.time()

    print("=" * 72)
    print("  ATCS-GH Corridor Training — v4 methodology (multi-agent Double-DQN)")
    print("=" * 72)
    print(f"  Junctions    : {JUNCTION_IDS}   state {STATE_SIZE} · actions {ACTION_SIZE}")
    print(f"  Episodes     : {n_episodes}")
    print(f"  Scenarios    : {n_scenarios} (rotating) — " + ", ".join(l for l, _ in SCENARIOS))
    for label, _ in SCENARIOS:
        b = baselines.get(label)
        if b:
            print(f"                 • {label}: baselines " +
                  " ".join(f"{jid}={b[jid]:.0f}s" for jid in JUNCTION_IDS))
        else:
            print(f"                 • {label}: [WARN] no baseline row — grading falls "
                  f"back to the {MIN_SELECT_BASELINE_S:.0f}s floor")
    print(f"  Warm-start   : per-junction sustained-green expert at {EXPERT_FRAC:.0%} of exploration")
    print(f"  Best select  : maximin over junctions — save when the WORST junction's "
          f"rolling rel wait over {BEST_WINDOW} eps improves "
          f"(baselines floored {MIN_SELECT_BASELINE_S:.0f}s, gated ε ≤ {MAX_SELECT_EPSILON})")
    print(f"  Checkpoints  : every {CHECKPOINT_FREQ} eps → {CHECKPOINT_DIR.relative_to(PROJECT_ROOT)}/")
    print("=" * 72)

    for ep in range(1, n_episodes + 1):
        ep_start = time.time()
        label, route_file = SCENARIOS[(ep - 1) % n_scenarios]
        base = baselines.get(label, {})

        env = CorridorEnv(verbose=False, route_file=str(route_file))
        seed = ep * 137 + 7
        states = env.reset(seed=seed)
        done = False

        while not done:
            # Guided ε-exploration per junction: mostly follow the sustained-green
            # expert during exploration so heavy episodes keep flowing; otherwise
            # exploit the network's greedy action.
            actions: dict[str, int] = {}
            for jid in JUNCTION_IDS:
                ag = agents[jid]
                if random.random() < ag.epsilon:
                    actions[jid] = (env.expert_action(jid)
                                    if random.random() < EXPERT_FRAC
                                    else random.randrange(ACTION_SIZE))
                else:
                    actions[jid] = ag.greedy_action(states[jid])

            next_states, rewards, done, _ = env.step(actions)

            for jid in JUNCTION_IDS:
                agents[jid].remember(states[jid], actions[jid], rewards[jid],
                                     next_states[jid], done)
                agents[jid].learn()
            states = next_states

        # ── Episode metrics (collect while env is still open) ────────────────
        c_wait        = env.corridor_avg_wait()
        c_reward      = env.corridor_total_reward()
        j_waits       = {jid: (float(np.mean(env.episode_waits[jid]))
                               if env.episode_waits[jid] else 0.0) for jid in JUNCTION_IDS}
        sim_steps     = env._sim_step
        total_arrived = env.total_arrived
        env.close()

        for jid in JUNCTION_IDS:
            agents[jid].decay_epsilon()
        eps      = max(agents[jid].epsilon for jid in JUNCTION_IDS)
        duration = time.time() - ep_start

        # ── Maximin best-model selection ─────────────────────────────────────
        note = ""
        rel = {jid: j_waits[jid] / max(base.get(jid, MIN_SELECT_BASELINE_S),
                                       MIN_SELECT_BASELINE_S)
               for jid in JUNCTION_IDS}
        recent_rel.append(rel)
        if len(recent_rel) > BEST_WINDOW:
            recent_rel.pop(0)
        worst_rel = max(rel.values())

        if len(recent_rel) >= BEST_WINDOW and eps <= MAX_SELECT_EPSILON:
            mean_rel = {jid: sum(r[jid] for r in recent_rel) / len(recent_rel)
                        for jid in JUNCTION_IDS}
            score = (max(mean_rel.values()), sum(mean_rel.values()) / len(mean_rel))
            if score < best_score:                # worst junction first, mean breaks ties
                best_score = score
                best_episode = ep
                for jid in JUNCTION_IDS:
                    agents[jid].save(str(CHECKPOINT_DIR / f"best_{jid}.pth"))
                note = "★ best"

        # ── Periodic checkpoint ──────────────────────────────────────────────
        if ep % CHECKPOINT_FREQ == 0:
            for jid in JUNCTION_IDS:
                agents[jid].save(str(CHECKPOINT_DIR / f"corridor_{jid}_ep{ep:03d}.pth"))
            if not note:
                note = "ckpt"

        # ── Log + console ────────────────────────────────────────────────────
        csv_writer.writerow({
            "episode": ep, "scenario": label, "seed": seed,
            "sim_steps": sim_steps, "total_arrived": total_arrived,
            "corridor_avg_wait": f"{c_wait:.2f}", "corridor_total_reward": f"{c_reward:.1f}",
            "J0_avg_wait": f"{j_waits['J0']:.2f}", "J1_avg_wait": f"{j_waits['J1']:.2f}",
            "J2_avg_wait": f"{j_waits['J2']:.2f}", "worst_rel": f"{worst_rel:.3f}",
            "epsilon": f"{eps:.4f}", "duration_s": f"{duration:.1f}", "note": note,
        })
        csv_file.flush()

        print(f"  Ep {ep:3d} | {label:16s} | wait={c_wait:6.1f}s arr={total_arrived:4d} "
              f"R={c_reward:+8.0f} | J0={j_waits['J0']:5.1f} J1={j_waits['J1']:5.1f} "
              f"J2={j_waits['J2']:5.1f} | worst={worst_rel:.2f}x ε={eps:.3f} "
              f"| {duration:.0f}s{('  ' + note) if note else ''}")

    csv_file.close()

    total_wall = time.time() - training_start
    print("\n" + "=" * 72)
    print("  Corridor training complete")
    if best_episode > 0:
        print(f"  Best models  : episode {best_episode} — worst junction "
              f"{best_score[0]:.2f}x baseline (mean {best_score[1]:.2f}x) → best_J*.pth")
    else:
        print(f"  Best models  : none saved (run < warm-up window, or ε never reached "
              f"{MAX_SELECT_EPSILON} — needs ~91+ episodes)")
    print(f"  Wall time    : {total_wall/60:.1f} min ({total_wall/max(n_episodes,1):.0f}s/ep)")
    print(f"  Checkpoints  : {CHECKPOINT_DIR}")
    print(f"  Log          : {LOG_FILE}")
    print(f"  Evaluate     : python scripts/eval_corridor.py --compare")
    print("=" * 72)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train corridor multi-agent DQN (v4 methodology)")
    parser.add_argument("--episodes", type=int, default=200, help="Episodes (default: 200)")
    parser.add_argument("--resume", action="store_true", help="Resume from best_{jid}.pth")
    args = parser.parse_args()
    train(n_episodes=args.episodes, resume=args.resume)
