"""Read-only dashboard telemetry and local traffic-server discovery.

The endpoint registry is project-scoped and contains only locally started
servers. It lets an already open dashboard follow a newly launched simulation
without treating an arbitrary listener on port 8765 as a traffic server.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import uuid

PROJECT_ROOT = Path(__file__).resolve().parents[1]
_PROJECT_KEY = hashlib.sha256(str(PROJECT_ROOT).encode()).hexdigest()[:16]
REGISTRY_DIR = Path(tempfile.gettempdir()) / f"trafiq-live-{_PROJECT_KEY}"
TELEMETRY_SCHEMA = 2


def register_endpoint(port: int, mode: str) -> dict:
    """Publish only after the WebSocket listener has successfully bound."""
    REGISTRY_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    record = {
        "pid": os.getpid(), "port": int(port), "mode": mode,
        "session_id": uuid.uuid4().hex, "started_at": time.time(),
        "project": str(PROJECT_ROOT), "telemetry_schema": TELEMETRY_SCHEMA,
    }
    path = REGISTRY_DIR / f"traffic-{record['pid']}.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record))
    temporary.chmod(0o600)
    temporary.replace(path)
    return record


def unregister_endpoint(record: dict) -> None:
    path = REGISTRY_DIR / f"traffic-{record['pid']}.json"
    try:
        if json.loads(path.read_text()).get("session_id") == record["session_id"]:
            path.unlink()
    except (OSError, ValueError):
        pass


def current_endpoint() -> dict | None:
    records = []
    for path in REGISTRY_DIR.glob("traffic-*.json"):
        try:
            record = json.loads(path.read_text())
            pid, port = int(record["pid"]), int(record["port"])
            started_at = float(record["started_at"])
            if pid <= 0 or not 1 <= port <= 65535 or record.get("project") != str(PROJECT_ROOT):
                continue
            if record.get("mode") not in ("single", "corridor") or not record.get("session_id"):
                continue
            if record.get("telemetry_schema") != TELEMETRY_SCHEMA or not 0 < started_at <= time.time() + 5:
                continue
            os.kill(pid, 0)
            record.update(pid=pid, port=port, started_at=started_at)
            records.append(record)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return max(records, key=lambda record: record["started_at"]) if records else None


def incoming_metrics(api, edges: dict[str, str]) -> dict:
    """Current approach measurements, never episode scores or lane wait sums.

    SUMO edge waiting time is a sum of the current vehicle waiting counters.
    Dividing by ALL vehicles on that edge gives a per-vehicle current mean.
    Halting counts use SUMO's <0.1 m/s threshold. Scheduled stops are governed
    by SUMO's waiting-time semantics; these aren't completed-trip delays.
    """
    approaches = {}
    for approach, edge in edges.items():
        vehicles = int(api.edge.getLastStepVehicleNumber(edge))
        waiting_sum = float(api.edge.getWaitingTime(edge))
        approaches[approach] = {
            "vehicles": vehicles,
            "stopped": int(api.edge.getLastStepHaltingNumber(edge)),
            "waiting_sum_seconds": waiting_sum,
            "mean_wait_seconds": waiting_sum / max(vehicles, 1),
        }
    vehicles = sum(item["vehicles"] for item in approaches.values())
    waiting_sum = sum(item["waiting_sum_seconds"] for item in approaches.values())
    return {
        "approaches": approaches,
        "incoming_vehicles": vehicles,
        "current_stopped_vehicles": sum(item["stopped"] for item in approaches.values()),
        "current_mean_wait_seconds": waiting_sum / max(vehicles, 1),
        "waiting_sum_seconds": waiting_sum,
        "scope": "incoming_edges",
    }
