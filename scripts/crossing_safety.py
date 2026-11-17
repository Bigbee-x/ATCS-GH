"""Visualizer crossing geometry and pedestrian priority, using the actual SUMO net.

Keeps the trained policy's requested phase; gates conflicting movements while
people finish crossing and makes turns yield to an enabled pedestrian crossing.
Training environments/checkpoints are not rewritten by this display service.
"""
from __future__ import annotations

import math
from pathlib import Path
from xml.etree import ElementTree as ET


class CrossingSafety:
    def __init__(self, traci, network: Path):
        self.traci = traci
        root = ET.parse(network).getroot()
        self.centres = {j.get("id"): (float(j.get("x")), float(j.get("y")))
                        for j in root.findall("junction") if j.get("type") == "traffic_light"}
        self.crossings = {}
        self.links = {jid: {} for jid in self.centres}
        self.states = {}
        self.signal_time = 0.0
        edges = {e.get("id"): e for e in root.findall("edge")}
        self.edge_junctions = {eid: {"approach_junction": edge.get("to"), "from_junction": edge.get("from", "")}
                               for eid, edge in edges.items() if not eid.startswith(":")}
        for edge_id, edge in edges.items():
            if edge.get("function") != "crossing" or not edge_id.startswith(":J"):
                continue
            lane = edge.find("lane")
            points = [tuple(map(float, point.split(","))) for point in lane.get("shape").split()]
            jid, number = edge_id[1:].split("_c")
            self.crossings[edge_id] = {
                "junction": jid, "index": int(number), "start": points[0], "end": points[-1],
                "width": float(lane.get("width")), "edges": set(edge.get("crossingEdges").split()),
            }
        for connection in root.findall("connection"):
            jid = connection.get("tl")
            incoming = connection.get("from", "")
            if jid not in self.links or incoming.startswith(":"):
                continue
            edge = edges[incoming]
            lane = next(l for l in edge.findall("lane") if l.get("index") == connection.get("fromLane"))
            x, y = map(float, lane.get("shape").split()[-1].split(","))
            cx, cy = self.centres[jid]
            arm = "north" if y > cy else "south"
            if abs(x - cx) > abs(y - cy):
                arm = "east" if x > cx else "west"
            self.links[jid][int(connection.get("linkIndex"))] = {
                "arm": arm, "dir": connection.get("dir"), "from": incoming, "to": connection.get("to")}

    def vehicle_geometry(self, packet: dict) -> dict:
        return self.edge_junctions.get(packet["edge"], {})

    def pedestrian_geometry(self, packet: dict) -> dict:
        crossing = self.crossings.get(packet["edge"])
        if crossing is None:
            return {}
        ax, ay = crossing["start"]
        bx, by = crossing["end"]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        px, py = packet["x"] - ax, packet["y"] - ay
        return {
            "crossing_index": crossing["index"],
            "crossing_progress": max(0.0, min(1.0, (px * dx + py * dy) / (length * length))),
            "crossing_lateral": (px * -dy + py * dx) / length / (crossing["width"] * 0.5),
        }

    def apply(self, requested: dict[str, str]) -> None:
        self.signal_time = self.traci.simulation.getTime()
        occupied = {edge: bool(self.traci.edge.getLastStepPersonIDs(edge)) for edge in self.crossings}
        for jid, requested_state in requested.items():
            state = list(requested_state)
            pedestrian_offset = len(state) - 4
            for index, link in self.links[jid].items():
                if state[index] not in "GgyY":
                    continue
                conflicts = [c for c in self.crossings.values() if c["junction"] == jid
                             and (link["from"] in c["edges"] or link["to"] in c["edges"])]
                # Existing walkers retain clearance even when their WALK ends.
                if any(occupied[f':{jid}_c{c["index"]}'] for c in conflicts):
                    state[index] = "r"
                elif link["dir"] in ("l", "r", "t") and any(
                        requested_state[pedestrian_offset + c["index"]] in "Gg" for c in conflicts):
                    state[index] = "g"  # permissive: yield to pedestrians
                # No right-on-red during a protected left-only phase. The
                # physical head has a left arrow, not a right-turn arrow.
                # Preserve right-turn yellow when through traffic is clearing;
                # cutting it directly to red forces last-moment emergency stops.
                if link["dir"] == "r" and not any(
                        other["arm"] == link["arm"] and other["dir"] == "s"
                        and requested_state[other_index] in "GgyY"
                        for other_index, other in self.links[jid].items()):
                    state[index] = "r"
            self.states[jid] = "".join(state)
            self.traci.trafficlight.setRedYellowGreenState(jid, self.states[jid])

    def snapshot(self, jid: str) -> dict:
        state = self.states.get(jid) or self.traci.trafficlight.getRedYellowGreenState(jid)
        signals = {}
        for arm in ("north", "east", "south", "west"):
            straight = [state[i] for i, link in self.links[jid].items() if link["arm"] == arm and link["dir"] == "s"]
            left = [state[i] for i, link in self.links[jid].items() if link["arm"] == arm and link["dir"] in ("l", "t")]
            signals[arm] = {"main": "green" if any(s in "Gg" for s in straight)
                            else ("yellow" if any(s in "yY" for s in straight) else "red"),
                            "arrow": any(s in "Gg" for s in left)}
        return {"signal_state": state, "signal_time": self.signal_time, "signals": signals,
                "crossing_green": {arm: state[-4 + i] in "Gg"
                                   for i, arm in enumerate(("north", "east", "south", "west"))}}
