"""Transit service shared by live playback and matched corridor evaluations.

Existing trotro demand receives real TraCI stops and three actual SUMO riders.
No vehicle teleporting or forced speed override is used. The renderer receives
stop/boarding state separately from the traffic signal controller.
"""
from __future__ import annotations
import json
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[1] / "visualizer/assets/transit/stations.json"


class TrotroService:
    def __init__(self, traci, corridor=False, enabled=True):
        self.api = traci
        self.enabled = enabled
        self.stations = json.loads(CONFIG.read_text())["corridor" if corridor else "single"] if enabled else []
        self.assignments = {}
        self.completed = set()
        self.boarded_total = 0
        self._seen_riders = set()

    def tick(self):
        api = self.api
        active = set(api.vehicle.getIDList())
        self.completed.intersection_update(active)
        for vid in list(self.assignments):
            if vid not in active:
                self._release(vid)
        for vid in sorted(active):
            if vid in self.assignments or vid in self.completed or api.vehicle.getTypeID(vid) != "trotro":
                continue
            route = api.vehicle.getRoute(vid)
            index = api.vehicle.getRouteIndex(vid)
            road = api.vehicle.getRoadID(vid)
            # On junction internals SUMO still reports the preceding route index.
            # Wait until the next regular edge before looking for a forward stop.
            if index < 0 or road.startswith(":"):
                continue
            for station in self.stations:
                if station["edge"] not in route[index:]:
                    continue
                # Never add an unreachable stop behind a bus or just beyond its braking distance.
                if road == station["edge"] and api.vehicle.getLanePosition(vid) > station["pos"] - 65:
                    continue
                if any(a["station"]["id"] == station["id"] for a in self.assignments.values()):
                    continue
                try:
                    api.vehicle.setStop(vid, station["edge"], station["pos"], laneIndex=1,
                                        duration=22, startPos=station["pos"] - 12,
                                        flags=1 if station.get("parking", False) else 0)
                    riders = []
                    capacity = api.vehicletype.getPersonCapacity("trotro") - api.vehicle.getPersonNumber(vid)
                    for i in range(max(0, min(3, capacity))):
                        pid = f"station:{station['id']}:{vid}:{i}"
                        api.person.add(pid, station["edge"], station["pos"] - 3)
                        api.person.appendDrivingStage(pid, route[-1], vid)
                        riders.append(pid)
                    self.assignments[vid] = {"station": station, "riders": riders, "departed": False}
                except api.exceptions.TraCIException as error:
                    print(f"[Transit] Could not schedule {vid}: {error}")
                    self.completed.add(vid)
                break
        persons = set(api.person.getIDList())
        for vid, assignment in list(self.assignments.items()):
            for pid in assignment["riders"]:
                if pid in persons and api.person.getVehicle(pid) == vid and pid not in self._seen_riders:
                    self._seen_riders.add(pid)
                    self.boarded_total += 1
            station = assignment["station"]
            if api.vehicle.getRoadID(vid) == station["edge"]:
                if api.vehicle.getLanePosition(vid) > station["pos"] + 35:
                    self.completed.add(vid)
                    self._release(vid)

    def _release(self, vid):
        assignment = self.assignments.pop(vid)
        persons = set(self.api.person.getIDList())
        for pid in assignment["riders"]:
            if pid in persons and not self.api.person.getVehicle(pid):
                self.api.person.remove(pid)
            self._seen_riders.discard(pid)

    def vehicle_state(self, vid):
        if vid not in self.assignments:
            return {}
        assignment = self.assignments[vid]
        station = assignment["station"]
        api = self.api
        on_edge = api.vehicle.getRoadID(vid) == station["edge"]
        distance = station["pos"] - api.vehicle.getLanePosition(vid) if on_edge else 10000.0
        stop_state = api.vehicle.getStopState(vid)
        # SUMO retains the parking flag for the reinsertion step, when the bus
        # already has a travel lane again. Only the lane-free interval is off-road.
        offroad = bool(stop_state & 2) and not api.vehicle.getLaneID(vid)
        stopped = on_edge and abs(distance) < 2 and bool(stop_state & 1)
        if station.get("parking", False):
            stopped = stopped and offroad
        return {"station_id": station["id"], "destination": station["destination"],
                "stop_distance": round(distance, 2), "boarding": stopped,
                "passengers": api.vehicle.getPersonNumber(vid),
                "offroad": offroad,
                **({"bay_x": station["bay_x"]} if "bay_x" in station else {})}

    def snapshot(self):
        api = self.api
        persons = set(api.person.getIDList())
        states = []
        for station in self.stations:
            entry = {"id": station["id"], "vehicle_id": "", "boarding": False, "waiting": [], "onboard": []}
            for vid, assignment in self.assignments.items():
                if assignment["station"]["id"] != station["id"]:
                    continue
                entry["vehicle_id"] = vid
                entry["boarding"] = self.vehicle_state(vid)["boarding"]
                for pid in assignment["riders"]:
                    if pid in persons:
                        entry["onboard" if api.person.getVehicle(pid) == vid else "waiting"].append(pid)
                break
            states.append(entry)
        return {"enabled": self.enabled, "boarded_total": self.boarded_total, "stations": states}
