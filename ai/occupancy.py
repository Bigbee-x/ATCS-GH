"""Road occupancy readings shared by the corridor env and its live supervisor.

SUMO's ``lane.getLastStepOccupancy`` and ``edge.getLastStepOccupancy`` already
return a fraction from 0 to 1 (checked on SUMO 1.27.1: the lane value equals
the summed vehicle lengths divided by the lane length, gaps excluded). Earlier
corridor code divided them by 100 a second time, so every occupancy test saw
values about 100x too small and never fired.

Two more traps make raw occupancy a poor "how full is this road" measure:

* An edge's value averages ALL of its lanes, including lane 0, which on these
  networks is a pedestrian-only sidewalk. A jammed two-lane link reads ~0.43.
* Without gaps, a bumper-to-bumper queue of cars covers only
  length / (length + minGap) = 4.5 / 7.0 ~= 0.64 of the lane, so thresholds
  such as 0.8 or 0.85 can never be reached.

``fullness`` therefore reads vehicle lanes only and divides by the jam
occupancy, so 1.0 means bumper to bumper and thresholds keep their intended
meaning ("85 % full"). Trotro queues sit slightly above the car jam level and
are capped at 1.0.
"""
from __future__ import annotations

# vType "car" in simulation/corridor_routes*.rou.xml (trotro: 7.0 m + 3.0 m)
CAR_LENGTH_M = 4.5
CAR_MIN_GAP_M = 2.5
JAM_OCCUPANCY = CAR_LENGTH_M / (CAR_LENGTH_M + CAR_MIN_GAP_M)   # ~= 0.643

_VEHICLE_CLASSES = ("passenger", "bus")


def fullness_from_occupancy(occupancy: float) -> float:
    """SUMO occupancy (0..1, gaps excluded) -> fullness (0..1, 1 = jammed)."""
    return min(max(float(occupancy), 0.0) / JAM_OCCUPANCY, 1.0)


def lane_fullness(api, lane_id: str) -> float:
    """How full one lane is: 0 empty, 1 bumper to bumper."""
    return fullness_from_occupancy(api.lane.getLastStepOccupancy(lane_id))


class LinkOccupancy:
    """Fullness of whole edges, averaged over their vehicle lanes only.

    Lane permissions are fixed by the network, so each edge's vehicle lanes are
    looked up once and cached. The TraCI handle is passed on every call so a
    patched module (as in the tests) is always the one used.
    """

    def __init__(self):
        self._lanes: dict[str, list[str]] = {}

    def vehicle_lanes(self, api, edge_id: str) -> list[str]:
        lanes = self._lanes.get(edge_id)
        if lanes is None:
            lanes = []
            for index in range(api.edge.getLaneNumber(edge_id)):
                lane = f"{edge_id}_{index}"
                allowed = api.lane.getAllowed(lane)
                # An empty permission list means every class may use the lane.
                if not allowed or any(c in allowed for c in _VEHICLE_CLASSES):
                    lanes.append(lane)
            self._lanes[edge_id] = lanes
        return lanes

    def fullness(self, api, edge_id: str) -> float:
        lanes = self.vehicle_lanes(api, edge_id)
        if not lanes:
            return 0.0
        return sum(lane_fullness(api, lane) for lane in lanes) / len(lanes)


def legacy_link_feature(api, edge_id: str) -> float:
    """Exactly what corridor state slot 45 held when the shipped checkpoints
    were trained: edge occupancy (sidewalk included) divided by 100 again."""
    return api.edge.getLastStepOccupancy(edge_id) / 100.0
