#!/usr/bin/env python3
"""Verify dashboard measurement semantics and endpoint discovery.

--live additionally compares both production packet streams against SUMO after
each simulation second, including completed counters between decision packets.
"""
from __future__ import annotations

import argparse
import asyncio
import importlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
import live_dashboard


class TelemetryTests(unittest.TestCase):
    def test_wait_is_weighted_by_vehicles_not_edges(self):
        edges = {"north": "n", "south": "s", "east": "e", "west": "w"}
        counts = {"n": 10, "s": 1, "e": 0, "w": 0}
        waits = {"n": 100, "s": 100, "e": 0, "w": 0}
        stops = {"n": 3, "s": 1, "e": 0, "w": 0}
        api = SimpleNamespace(edge=SimpleNamespace(
            getLastStepVehicleNumber=counts.__getitem__,
            getWaitingTime=waits.__getitem__,
            getLastStepHaltingNumber=stops.__getitem__))
        metrics = live_dashboard.incoming_metrics(api, edges)
        self.assertAlmostEqual(metrics["current_mean_wait_seconds"], 200 / 11)
        self.assertEqual(metrics["current_stopped_vehicles"], 4)
        self.assertEqual(metrics["incoming_vehicles"], 11)
        self.assertEqual(metrics["approaches"]["east"]["mean_wait_seconds"], 0)
        self.assertEqual(metrics["approaches"]["south"]["mean_wait_seconds"], 100)

    def test_endpoint_replacement_does_not_delete_new_session(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(live_dashboard, "REGISTRY_DIR", Path(directory)):
            first = live_dashboard.register_endpoint(18981, "single")
            second = live_dashboard.register_endpoint(18982, "corridor")
            self.assertNotEqual(first["session_id"], second["session_id"])
            live_dashboard.unregister_endpoint(first)
            self.assertEqual(live_dashboard.current_endpoint(), second)
            live_dashboard.unregister_endpoint(second)
            self.assertIsNone(live_dashboard.current_endpoint())

    def test_discovery_rejects_stale_or_malformed_record(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(live_dashboard, "REGISTRY_DIR", Path(directory)):
            valid = live_dashboard.register_endpoint(18981, "corridor")
            live_dashboard.unregister_endpoint(valid)
            for index, malformed in enumerate([
                {**valid, "pid": 99999999}, {**valid, "project": "/another/project"},
                {**valid, "port": 70000}, {**valid, "started_at": "invalid"},
                {**valid, "mode": "unknown"}, {},
            ]):
                (Path(directory) / f"traffic-{index}.json").write_text(json.dumps(malformed))
            self.assertIsNone(live_dashboard.current_endpoint())

    def test_flask_config_follows_registry_not_launch_environment(self):
        from dashboard.app import app
        with tempfile.TemporaryDirectory() as directory, patch.object(live_dashboard, "REGISTRY_DIR", Path(directory)):
            client = app.test_client()
            self.assertFalse(client.get("/api/live-config").get_json()["available"])
            record = live_dashboard.register_endpoint(18983, "corridor")
            response = client.get("/api/live-config")
            data = response.get_json()
            self.assertTrue(data["available"])
            self.assertEqual(data["ws_url"], "ws://127.0.0.1:18983")
            self.assertEqual(data["session_id"], record["session_id"])
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(client.get("/").status_code, 200)
            self.assertEqual(client.get("/analytics").status_code, 200)


async def validate_live(corridor: bool):
    module = importlib.import_module("corridor_visualizer_server" if corridor else "visualizer_server")
    api = module.traci
    seen_time = 0
    arrived = 0
    checked = 0
    max_stopped = 0
    last_state = None
    fixture = None
    module._stream_metadata.update(session_id="validation", telemetry_schema=2,
                                   source="SUMO / TraCI", simulation_speed=1000)
    sentinel = object()
    module.connected_clients.add(sentinel)

    def capture(_clients, raw):
        nonlocal seen_time, arrived, checked, max_stopped, last_state, fixture
        data = json.loads(raw)
        if data["type"] == "sim_restart":
            # Env.reset performs one warm-up SUMO step before live stepping.
            seen_time = api.simulation.getTime()
            return
        if data["type"] not in ("vehicle_update", "state_update"):
            return
        now = data["sim_time"]
        if now > seen_time:
            assert now == seen_time + 1, (seen_time, now)
            arrived += api.simulation.getArrivedNumber()
            seen_time = now
        metrics = data["traffic_metrics"]
        if corridor:
            configs = {jid: dict(zip(("north", "east", "south", "west"), cfg.incoming_edges))
                       for jid, cfg in module.JUNCTIONS.items()}
        else:
            configs = {"J0": {"north": "ACH_N2J", "east": "AGG_E2J", "south": "ACH_S2J", "west": "GUG_W2J"}}
        expected_vehicles = 0
        expected_wait = 0
        expected_stopped = 0
        for jid, edges in configs.items():
            expected = live_dashboard.incoming_metrics(api, edges)
            junction = data["junctions"][jid] if corridor else data
            assert junction["queues"] == {arm: values["stopped"] for arm, values in expected["approaches"].items()}
            assert junction["wait_times"] == {arm: values["mean_wait_seconds"] for arm, values in expected["approaches"].items()}
            assert junction["incoming_vehicles"] == expected["incoming_vehicles"]
            expected_vehicles += expected["incoming_vehicles"]
            expected_wait += expected["waiting_sum_seconds"]
            expected_stopped += expected["current_stopped_vehicles"]
        assert abs(metrics["current_mean_wait_seconds"] - expected_wait / max(expected_vehicles, 1)) < 1e-9
        assert metrics["incoming_vehicles"] == expected_vehicles
        assert metrics["current_stopped_vehicles"] == expected_stopped
        assert metrics["active_vehicles"] == len(api.vehicle.getIDList())
        assert metrics["vehicles_completed"] == data["vehicles_completed"] == arrived
        assert metrics["sample_time"] == now
        assert data["source"] == "SUMO / TraCI" and data["run_id"] == "validation:1"
        assert data["session_id"] == "validation" and data["seed"] == 42
        max_stopped = max(max_stopped, expected_stopped)
        checked += 1
        if data["type"] == "state_update":
            last_state = data
        if now >= 360 and arrived > 0 and last_state:
            fixture = {"vehicle_update": data, "state_update": last_state}
            raise asyncio.CancelledError

    try:
        with patch.object(module.websockets, "broadcast", capture):
            if corridor:
                await module.simulation_loop("ai", ROOT / "ai/checkpoints/corridor", 1000)
            else:
                await module.simulation_loop("ai", ROOT / "ai/best_model.pth", 1000)
    finally:
        module.connected_clients.discard(sentinel)
    assert checked > 400 and arrived > 0 and max_stopped > 0, (checked, arrived, max_stopped)
    name = "corridor" if corridor else "single"
    output = Path(tempfile.gettempdir()) / f"dashboard-{name}-telemetry.json"
    output.write_text(json.dumps(fixture))
    print(f"LIVE TELEMETRY {name}: {checked} packets exactly match SUMO; t={seen_time}, arrived={arrived}, max_stopped={max_stopped}; {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(TelemetryTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.live:
        asyncio.run(validate_live(False))
        asyncio.run(validate_live(True))
