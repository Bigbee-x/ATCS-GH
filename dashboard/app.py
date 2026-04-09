#!/usr/bin/env python3
from __future__ import annotations
"""
ATCS-GH Dashboard — Live Training & Performance Analytics
══════════════════════════════════════════════════════════
Flask web app serving real-time training progress, scenario
comparisons, and AI vs baseline performance metrics.
"""

import csv
import os
from pathlib import Path
from flask import Flask, jsonify, render_template

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR     = PROJECT_ROOT / "data"
LOG_FILE     = DATA_DIR / "training_log.csv"
SCENARIO_EVAL = DATA_DIR / "scenario_eval_results.csv"

app = Flask(__name__)


# ── Helpers ──────────────────────────────────────────────────────────────────

def _read_csv(path: Path) -> list[dict]:
    """Read a CSV file into a list of dicts. Returns [] if file missing."""
    if not path.exists():
        return []
    with open(path, "r") as f:
        return list(csv.DictReader(f))


def _safe_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


# ── API Endpoints ────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("dashboard.html")


@app.route("/api/training-log")
def api_training_log():
    """Return full training log as JSON (live-updating)."""
    rows = _read_csv(LOG_FILE)
    data = []
    for r in rows:
        data.append({
            "episode":    int(r.get("episode", 0)),
            "scenario":   r.get("scenario", "unknown"),
            "reward":     _safe_float(r.get("total_reward")),
            "avg_wait":   _safe_float(r.get("avg_wait_s")),
            "peak_queue": int(_safe_float(r.get("peak_queue"))),
            "epsilon":    _safe_float(r.get("epsilon")),
            "delta_pct":  _safe_float(r.get("delta_vs_baseline_pct")),
            "time_s":     _safe_float(r.get("episode_time_s")),
            "emerg_wait": _safe_float(r.get("max_emerg_wait_s")),
        })
    return jsonify(data)


@app.route("/api/training-summary")
def api_training_summary():
    """Return summary stats for the current training run."""
    rows = _read_csv(LOG_FILE)
    if not rows:
        return jsonify({"status": "no_data"})

    total_eps = len(rows)
    latest = rows[-1]
    first_5 = rows[:min(5, total_eps)]
    last_5  = rows[-min(5, total_eps):]

    first_avg = sum(_safe_float(r["avg_wait_s"]) for r in first_5) / len(first_5)
    last_avg  = sum(_safe_float(r["avg_wait_s"]) for r in last_5)  / len(last_5)
    improvement = ((first_avg - last_avg) / first_avg * 100) if first_avg > 0 else 0

    best_wait = min(_safe_float(r["avg_wait_s"]) for r in rows)
    best_ep   = next(r for r in rows if _safe_float(r["avg_wait_s"]) == best_wait)

    # Per-scenario breakdown
    scenarios = {}
    for r in rows:
        s = r.get("scenario", "unknown")
        if s not in scenarios:
            scenarios[s] = []
        scenarios[s].append(_safe_float(r["avg_wait_s"]))

    scenario_stats = {}
    for s, waits in scenarios.items():
        last_n = waits[-min(5, len(waits)):]
        scenario_stats[s] = {
            "episodes":  len(waits),
            "best_wait": round(min(waits), 1),
            "last_avg":  round(sum(last_n) / len(last_n), 1),
        }

    return jsonify({
        "status":          "training",
        "total_episodes":  total_eps,
        "target_episodes": 250,
        "epsilon":         _safe_float(latest.get("epsilon")),
        "first_5_avg":     round(first_avg, 1),
        "last_5_avg":      round(last_avg, 1),
        "improvement_pct": round(improvement, 1),
        "best_wait":       round(best_wait, 1),
        "best_episode":    int(best_ep.get("episode", 0)),
        "scenarios":       scenario_stats,
    })


@app.route("/api/scenario-eval")
def api_scenario_eval():
    """Return scenario evaluation results (AI vs baseline)."""
    rows = _read_csv(SCENARIO_EVAL)
    data = []
    for r in rows:
        data.append({
            "scenario":      r.get("scenario", ""),
            "baseline_mean": _safe_float(r.get("baseline_mean")),
            "baseline_std":  _safe_float(r.get("baseline_std")),
            "ai_mean":       _safe_float(r.get("ai_mean")),
            "ai_std":        _safe_float(r.get("ai_std")),
            "change_pct":    _safe_float(r.get("change_pct")),
        })
    return jsonify(data)


@app.route("/api/scenario-detail/<scenario>/<mode>")
def api_scenario_detail(scenario, mode):
    """Return per-second simulation data for a specific scenario run.
    mode: 'ai' or 'bl' (baseline)
    """
    # Try seed 42 first, then any available seed
    for seed in [42, 271, 503]:
        filename = f"{mode}_{scenario}_seed{seed}.csv"
        path = DATA_DIR / filename
        if path.exists():
            rows = _read_csv(path)
            # Downsample for performance (every 30 seconds)
            sampled = []
            for i, r in enumerate(rows):
                if i % 30 == 0:
                    sampled.append({
                        "time":       int(_safe_float(r.get("time_s"))),
                        "avg_wait":   _safe_float(r.get("avg_wait_time_s")),
                        "queue":      int(_safe_float(r.get("total_queue_vehicles"))),
                        "throughput": _safe_float(r.get("throughput_veh_per_min")),
                        "completed":  int(_safe_float(r.get("completed_vehicles"))),
                        "phase":      r.get("tl_phase", ""),
                    })
            return jsonify({"seed": seed, "data": sampled})

    return jsonify({"error": f"No data for {mode}_{scenario}"}), 404


@app.route("/api/sim-status")
def api_sim_status():
    """Check if the simulation WebSocket server is reachable."""
    import socket
    try:
        s = socket.create_connection(("localhost", 8765), timeout=1)
        s.close()
        return jsonify({"running": True, "ws_url": "ws://localhost:8765"})
    except (ConnectionRefusedError, OSError):
        return jsonify({"running": False, "ws_url": "ws://localhost:8765"})


# ── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("\n  ATCS-GH Dashboard")
    print(f"  http://localhost:5050\n")
    app.run(host="0.0.0.0", port=5050, debug=True)
