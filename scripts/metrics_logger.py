#!/usr/bin/env python3
"""
ATCS-GH | Metrics Logger
═════════════════════════
Reusable class for collecting per-step simulation metrics via TraCI.

Designed so that BOTH the Phase 1 baseline runner and the Phase 2 AI
controller can import and use it identically — ensuring the two systems
are always compared on the same metrics.

Usage:
    from metrics_logger import MetricsLogger

    logger = MetricsLogger(output_path="data/baseline_results.csv")

    # Inside the simulation loop (after traci.simulationStep()):
    logger.step(current_time=traci.simulation.getTime(),
                tl_phase_name="NS_GREEN")

    # After the loop:
    logger.save()
    stats = logger.summary_stats()
"""

import csv
from pathlib import Path
import traci


# Edges whose incoming lanes we measure (vehicles approaching the junction)
INCOMING_EDGES  = ["N2J", "S2J", "E2J", "W2J"]

# Vehicle type ID that identifies emergency vehicles (must match routes.rou.xml)
EMERGENCY_TYPE  = "emergency"

# Rolling window length for throughput calculation (seconds)
THROUGHPUT_WINDOW_S = 60


class MetricsLogger:
    """
    Records per-step simulation performance data.

    Attributes collected each step:
      • avg_wait_time_s          — mean waiting time across all incoming lanes
      • total_queue_vehicles     — total halted vehicles across all incoming lanes
      • throughput_veh_per_min   — vehicles that completed journeys in last 60s
      • completed_vehicles       — cumulative total of arrived vehicles
      • emergency_vehicles_waiting — emergency vehicles currently stopped
      • per-lane wait and queue  — one column pair per incoming lane

    Emergency vehicle tracking:
      • emergency_log dict maps vehicle_id → {max_wait, total_wait, ...}
    """

    def __init__(self, output_path: str | Path,
                 incoming_edges: list[str] = INCOMING_EDGES):
        self.output_path    = Path(output_path)
        self.incoming_edges = incoming_edges

        # Collected rows — each element is one simulation step
        self.records: list[dict] = []

        # Emergency vehicle state: vid → {max_wait, total_wait, first_seen, route}
        self.emergency_log: dict[str, dict] = {}

        # Rolling arrivals buffer for throughput: list of (timestamp, count)
        self._recent_arrivals: list[tuple[float, int]] = []

        # Cumulative arrived vehicles
        self.total_arrived: int = 0

        # Per-edge running stats (for efficient summary without re-scanning records)
        self.edge_stats: dict[str, dict] = {
            edge: {"total_wait": 0.0, "max_queue": 0, "samples": 0}
            for edge in incoming_edges
        }

    # ── Public API ────────────────────────────────────────────────────────────

    def step(self, current_time: float, tl_phase_name: str) -> dict:
        """
        Call once per simulation step immediately after traci.simulationStep().

        Args:
            current_time:   traci.simulation.getTime()
            tl_phase_name:  human-readable phase label, e.g. "NS_GREEN"

        Returns:
            The dict record appended this step (useful for real-time display).
        """
        # Track vehicles that finished their journey this step
        n_arrived = traci.simulation.getArrivedNumber()
        self.total_arrived += n_arrived
        if n_arrived > 0:
            self._recent_arrivals.append((current_time, n_arrived))

        # Prune arrivals outside the rolling window
        cutoff = current_time - THROUGHPUT_WINDOW_S
        self._recent_arrivals = [
            (t, n) for t, n in self._recent_arrivals if t >= cutoff
        ]
        throughput = sum(n for _, n in self._recent_arrivals)

        # Collect per-lane metrics from TraCI
        lane_metrics = self._collect_lane_metrics()
        all_waits  = [m["wait_time"]    for m in lane_metrics.values()]
        all_queues = [m["queue_length"] for m in lane_metrics.values()]

        avg_wait    = round(sum(all_waits)  / len(all_waits),  3) if all_waits  else 0.0
        total_queue = sum(all_queues)

        # Update edge-level aggregates (used in summary_stats)
        self._update_edge_stats(lane_metrics)

        # Track emergency vehicles
        self._track_emergency_vehicles(current_time)
        n_emerg_waiting = sum(
            1 for vid in traci.vehicle.getIDList()
            if traci.vehicle.getTypeID(vid) == EMERGENCY_TYPE
            and traci.vehicle.getSpeed(vid) < 0.1   # effectively stopped
        )

        # Build the record for this step
        record: dict = {
            "time_s":                    int(current_time),
            "tl_phase":                  tl_phase_name,
            "avg_wait_time_s":           avg_wait,
            "total_queue_vehicles":      total_queue,
            "throughput_veh_per_min":    throughput,
            "completed_vehicles":        self.total_arrived,
            "emergency_vehicles_waiting": n_emerg_waiting,
        }

        # Append one column pair per lane (sorted for consistent CSV column order)
        for lane_id, m in sorted(lane_metrics.items()):
            record[f"{lane_id}_wait_s"] = m["wait_time"]
            record[f"{lane_id}_queue"]  = m["queue_length"]

        self.records.append(record)
        return record

    def save(self) -> None:
        """Write all collected records to CSV. Creates parent dirs if needed."""
        if not self.records:
            print("[MetricsLogger] No data to save.")
            return

        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        fieldnames = list(self.records[0].keys())

        with open(self.output_path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(self.records)

        print(f"[MetricsLogger] {len(self.records):,} rows saved → {self.output_path}")

    def summary_stats(self) -> dict:
        """
        Return aggregated statistics over the full simulation run.
        Call after the simulation loop (and optionally before save()).

        Returns a dict with keys:
            overall_avg_wait, peak_queue, avg_throughput, peak_throughput,
            total_completed, edge_stats, emergency_log
        """
        if not self.records:
            return {}

        waits       = [r["avg_wait_time_s"]        for r in self.records]
        queues      = [r["total_queue_vehicles"]    for r in self.records]
        throughputs = [r["throughput_veh_per_min"]  for r in self.records]

        return {
            "overall_avg_wait":  round(sum(waits) / len(waits), 2),
            "peak_queue":        max(queues),
            "avg_throughput":    round(sum(throughputs) / len(throughputs), 2),
            "peak_throughput":   max(throughputs),
            "total_completed":   self.total_arrived,
            "edge_stats":        self.edge_stats,
            "emergency_log":     self.emergency_log,
        }

    # ── Private helpers ───────────────────────────────────────────────────────

    def _collect_lane_metrics(self) -> dict[str, dict]:
        """Fetch wait time, queue length, and vehicle count for all incoming lanes."""
        metrics: dict[str, dict] = {}

        for edge_id in self.incoming_edges:
            try:
                n_lanes = traci.edge.getLaneNumber(edge_id)
            except traci.exceptions.TraCIException:
                continue  # Edge not yet loaded

            for idx in range(n_lanes):
                lane_id = f"{edge_id}_{idx}"
                try:
                    metrics[lane_id] = {
                        "wait_time":    round(traci.lane.getWaitingTime(lane_id), 2),
                        "queue_length": traci.lane.getLastStepHaltingNumber(lane_id),
                        "veh_count":    traci.lane.getLastStepVehicleNumber(lane_id),
                    }
                except traci.exceptions.TraCIException:
                    pass  # Lane may not exist yet at t=0

        return metrics

    def _update_edge_stats(self, lane_metrics: dict[str, dict]) -> None:
        """Update running per-edge totals for use in summary_stats()."""
        for edge in self.incoming_edges:
            edge_lanes = {
                k: v for k, v in lane_metrics.items()
                if k.startswith(edge + "_")
            }
            if not edge_lanes:
                continue

            total_edge_wait = sum(m["wait_time"]    for m in edge_lanes.values())
            max_edge_queue  = max(m["queue_length"] for m in edge_lanes.values())

            stats = self.edge_stats[edge]
            stats["total_wait"] += total_edge_wait
            stats["max_queue"]   = max(stats["max_queue"], max_edge_queue)
            stats["samples"]    += 1

    def _track_emergency_vehicles(self, current_time: float) -> None:
        """
        Record accumulated waiting time for every emergency vehicle in the sim.
        SUMO's accumulatedWaitingTime counts total seconds spent at speed < 0.1 m/s.
        """
        for vid in traci.vehicle.getIDList():
            if traci.vehicle.getTypeID(vid) != EMERGENCY_TYPE:
                continue

            wait = traci.vehicle.getAccumulatedWaitingTime(vid)

            if vid not in self.emergency_log:
                self.emergency_log[vid] = {
                    "max_wait":   0.0,
                    "total_wait": 0.0,
                    "first_seen": current_time,
                    "route":      traci.vehicle.getRouteID(vid),
                }

            entry = self.emergency_log[vid]
            entry["total_wait"] = wait
            if wait > entry["max_wait"]:
                entry["max_wait"] = wait
