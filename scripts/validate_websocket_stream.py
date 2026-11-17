#!/usr/bin/env python3
"""Exercise the real Godot client with dense corridor traffic and reconnects.

Uses a temporary loopback listener; no SUMO process or occupied port is touched.
The default-peer negative control reproduces the old 1009 size-limit failure.
Run: .venv/bin/python3 scripts/validate_websocket_stream.py
"""
from __future__ import annotations

import argparse
import asyncio
import json
import tempfile
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT = "/Applications/Godot 4.6.3.app/Contents/MacOS/Godot"


def packet(sequence: int, count: int, kind: str = "vehicle_update", **extra) -> str:
    """Use the live schema, including vehicle geometry and signal observations."""
    vehicles = [
        {
            "id": f"corridor_vehicle_{index}",
            "type": "trotro" if index % 7 == 0 else "car",
            "x": 1500.0 + index % 20,
            "y": 1000.0 + index * 0.25 + sequence,
            "angle": 180.0,
            "speed": 8.5,
            "lane": "ACH_J0toJ1_1",
            "lane_position": index * 0.25,
            "edge": "ACH_J0toJ1",
            "approach_junction": "J1",
            "from_junction": "J0",
        }
        for index in range(count)
    ]
    junctions = {
        jid: {
            "phase": sequence % 6,
            "signal_time": sequence,
            "signals": {arm: {"main": "green", "arrow": "red"}
                        for arm in ("north", "east", "south", "west")},
            "control": {"kind": "dqn_supervised", "sample_time": sequence,
                        "reason": "balance_queue_pressure"},
        }
        for jid in ("J0", "J1", "J2")
    }
    return json.dumps({"type": kind, "mode": "corridor", "sim_time": sequence,
                       "vehicles": vehicles, "pedestrians": [], "junctions": junctions,
                       "validation_sequence": sequence, "validation_count": count,
                       **extra}, separators=(",", ":"))


async def run_case(godot: str, negative_control: bool) -> None:
    done = asyncio.get_running_loop().create_future()
    connections = 0
    sizes = []
    expected = []

    async def acknowledged(ws, sequences):
        for sequence in sequences:
            message = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            assert message == {"validation_ack": sequence}, message

    async def send(ws, sequence, count, kind="vehicle_update", **extra):
        text = packet(sequence, count, kind, **extra)
        sizes.append(len(text.encode()))
        expected.append(sequence)
        await ws.send(text)

    async def handler(ws):
        nonlocal connections
        connections += 1
        try:
            if negative_control:
                assert connections == 1, "Default peer unexpectedly reconnected"
                await send(ws, 1, 400)
                await ws.wait_closed()
                assert ws.close_code == 1009, f"Expected size-limit close, got {ws.close_code}"
                done.set_result(None)
            elif connections == 1:
                await ws.send(json.dumps({"type": "mode_changed", "mode": "ai"}))
                mode_ack = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
                assert mode_ack == {"validation_mode_ack": True}, mode_ack
                await send(ws, 1, 400)
                await acknowledged(ws, [1])
                await send(ws, 2, 6000, "state_update")
                assert sizes[-1] > 1024 * 1024, "Large-message case must exceed 1 MiB"
                await acknowledged(ws, [2])
                # The client deliberately stops polling briefly while these frames arrive.
                await send(ws, 3, 400, validation_stall=True)
                await acknowledged(ws, [3])
                for sequence in range(4, 12):
                    await send(ws, sequence, 400)
                await acknowledged(ws, range(4, 12))
                await ws.close(code=1001, reason="Validation reconnect")
            elif connections == 2:
                await send(ws, 12, 6000)
                await acknowledged(ws, [12])
                await send(ws, 13, 400, "state_update")
                await acknowledged(ws, [13])
                await ws.send(json.dumps({"type": "sim_complete", "validation_expected": expected}))
                await ws.wait_closed()
                done.set_result(None)
            else:
                raise AssertionError(f"Unexpected disconnect/reconnect #{connections}")
        except Exception as error:
            if not done.done():
                done.set_exception(error)

    async with websockets.serve(handler, "127.0.0.1", 0, compression=None) as server:
        port = server.sockets[0].getsockname()[1]
        command = [godot, "--headless", "--path", str(ROOT / "visualizer"),
                   "--log-file", str(Path(tempfile.gettempdir()) / f"trafiq-websocket-{port}.log"),
                   "--script", "res://tools/validate_websocket_stream.gd", "--",
                   f"ws://127.0.0.1:{port}", "default-peer" if negative_control else "client"]
        process = await asyncio.create_subprocess_exec(
            *command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        output_task = asyncio.create_task(process.communicate())
        printed = False
        try:
            await asyncio.wait_for(asyncio.shield(done), timeout=35)
            output, _ = await asyncio.wait_for(output_task, timeout=10)
            decoded = output.decode(errors="replace")
            print(decoded, end="")
            printed = True
            assert process.returncode == 0, f"Godot exited {process.returncode}"
            assert "SCRIPT ERROR" not in decoded and "\nERROR:" not in decoded, decoded
            assert "STREAM PASS" in decoded, "Godot did not complete its assertions"
            print(f"STREAM {'NEGATIVE CONTROL' if negative_control else 'REGRESSION'} PASS: "
                  f"connections={connections}, packets={len(expected)}, max_bytes={max(sizes):,}")
        finally:
            if process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=5)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()
            if not printed:
                output, _ = await output_task
                print(output.decode(errors="replace"), end="")


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    args = parser.parse_args()
    await run_case(args.godot, negative_control=True)
    await run_case(args.godot, negative_control=False)


if __name__ == "__main__":
    asyncio.run(main())
