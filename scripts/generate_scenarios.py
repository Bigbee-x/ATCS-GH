#!/usr/bin/env python3
"""
ATCS-GH | Generate Demand Scenario Route Files
================================================
Programmatically generates SUMO route XML files for multiple traffic
demand scenarios at the Achimota/Neoplan Junction.

All scenarios share:
  - Vehicle types (car, trotro, emergency)
  - Route definitions (12 origin-destination pairs)
  - Simulation duration (7200s = 2 hours)
  - SUMO departure parameters

Only the flow volumes and ambulance placements change.

Usage:
    python scripts/generate_scenarios.py           # Generate all scenarios
    python scripts/generate_scenarios.py --list     # List scenario names
"""

from __future__ import annotations
import argparse
from pathlib import Path
from textwrap import dedent

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCENARIO_DIR = PROJECT_ROOT / "simulation" / "scenarios"

# ── Shared XML fragments ──────────────────────────────────────────────────────

VEHICLE_TYPES = dedent("""\
  <!-- Standard passenger car (Toyota Corolla / Kia Rio) -->
  <vType id="car"
         accel="2.6" decel="4.5" emergencyDecel="9.0" sigma="0.5"
         length="4.5" minGap="2.5" maxSpeed="13.89"
         guiShape="passenger" color="0.6,0.6,0.9"
         jmCrossingGap="3.0"/>

  <!-- Trotro (shared minibus) — slower, longer -->
  <vType id="trotro"
         accel="1.8" decel="3.5" emergencyDecel="7.0" sigma="0.7"
         length="7.0" minGap="3.0" maxSpeed="11.11"
         guiShape="bus/city" color="1.0,0.8,0.0"
         jmCrossingGap="3.0"/>

  <!-- Pedestrian — faster walking speed (Ghanaian crossing behavior) -->
  <vType id="ped_fast" vClass="pedestrian"
         speed="3.80"
         length="0.25" minGap="0.5" width="0.65"/>

  <!-- Emergency vehicle (ambulance) — vClass gives blue-light privileges -->
  <vType id="emergency" vClass="emergency"
         accel="3.5" decel="6.0" emergencyDecel="9.0" sigma="0.0"
         tau="0.5" length="5.5" minGap="1.5" maxSpeed="16.67"
         guiShape="emergency" color="1.0,0.0,0.0" speedFactor="1.2"
         lcStrategic="100" lcPushy="1.0" lcAssertive="1.0"
         jmDriveAfterRedTime="3" jmDriveAfterYellowTime="3"/>""")

ROUTE_DEFS = dedent("""\
  <!-- From North (Achimota Forest Rd — Nsawam direction) -->
  <route id="route_NS" edges="ACH_N2J ACH_J2S"/>
  <route id="route_NE" edges="ACH_N2J AGG_J2E"/>
  <route id="route_NW" edges="ACH_N2J GUG_J2W"/>

  <!-- From South (Achimota Forest Rd — CBD direction) -->
  <route id="route_SN" edges="ACH_S2J ACH_J2N"/>
  <route id="route_SE" edges="ACH_S2J AGG_J2E"/>
  <route id="route_SW" edges="ACH_S2J GUG_J2W"/>

  <!-- From East (Aggrey Street) -->
  <route id="route_EW" edges="AGG_E2J GUG_J2W"/>
  <route id="route_EN" edges="AGG_E2J ACH_J2N"/>
  <route id="route_ES" edges="AGG_E2J ACH_J2S"/>

  <!-- From West (Guggisberg Street) -->
  <route id="route_WE" edges="GUG_W2J AGG_J2E"/>
  <route id="route_WN" edges="GUG_W2J ACH_J2N"/>
  <route id="route_WS" edges="GUG_W2J ACH_J2S"/>""")


# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

SCENARIOS = {
    # ── 1. Morning Rush (matches current routes.rou.xml) ──────────────────────
    "morning_rush": {
        "description": "Morning Rush 07:00-09:00 — heavy N-to-S commuter flow",
        "total_approx": 2640,
        "flows": [
            # N/S mainline
            {"id": "flow_NS",   "type": "car",    "route": "route_NS", "vph": 820},
            {"id": "flow_NS_t", "type": "trotro", "route": "route_NS", "vph": 80},
            {"id": "flow_SN",   "type": "car",    "route": "route_SN", "vph": 250},
            {"id": "flow_SN_t", "type": "trotro", "route": "route_SN", "vph": 50},
            # N/S turns
            {"id": "flow_NE",   "type": "car", "route": "route_NE", "vph": 130},
            {"id": "flow_NW",   "type": "car", "route": "route_NW", "vph": 90},
            {"id": "flow_SE",   "type": "car", "route": "route_SE", "vph": 120},
            {"id": "flow_SW",   "type": "car", "route": "route_SW", "vph": 200},
            # E/W
            {"id": "flow_EW",   "type": "car",    "route": "route_EW", "vph": 280},
            {"id": "flow_EW_t", "type": "trotro", "route": "route_EW", "vph": 40},
            {"id": "flow_EN",   "type": "car",    "route": "route_EN", "vph": 180},
            {"id": "flow_ES",   "type": "car",    "route": "route_ES", "vph": 100},
            {"id": "flow_WE",   "type": "car",    "route": "route_WE", "vph": 100},
            {"id": "flow_WN",   "type": "car",    "route": "route_WN", "vph": 150},
            {"id": "flow_WS",   "type": "car",    "route": "route_WS", "vph": 50},
        ],
        # Ambulances are deployed manually from the Godot UI — no auto-spawn
        "ambulances": [],
    },

    # ── 2. Evening Rush (reversed dominant direction) ─────────────────────────
    "evening_rush": {
        "description": "Evening Rush 17:00-19:00 — heavy S-to-N return flow",
        "total_approx": 2640,
        "flows": [
            # S→N now dominant (commuters returning to Nsawam)
            {"id": "flow_NS",   "type": "car",    "route": "route_NS", "vph": 250},
            {"id": "flow_NS_t", "type": "trotro", "route": "route_NS", "vph": 50},
            {"id": "flow_SN",   "type": "car",    "route": "route_SN", "vph": 820},
            {"id": "flow_SN_t", "type": "trotro", "route": "route_SN", "vph": 80},
            # Turns mirrored
            {"id": "flow_NE",   "type": "car", "route": "route_NE", "vph": 120},
            {"id": "flow_NW",   "type": "car", "route": "route_NW", "vph": 200},
            {"id": "flow_SE",   "type": "car", "route": "route_SE", "vph": 90},
            {"id": "flow_SW",   "type": "car", "route": "route_SW", "vph": 130},
            # E/W unchanged
            {"id": "flow_EW",   "type": "car",    "route": "route_EW", "vph": 280},
            {"id": "flow_EW_t", "type": "trotro", "route": "route_EW", "vph": 40},
            {"id": "flow_EN",   "type": "car",    "route": "route_EN", "vph": 100},
            {"id": "flow_ES",   "type": "car",    "route": "route_ES", "vph": 180},
            {"id": "flow_WE",   "type": "car",    "route": "route_WE", "vph": 100},
            {"id": "flow_WN",   "type": "car",    "route": "route_WN", "vph": 50},
            {"id": "flow_WS",   "type": "car",    "route": "route_WS", "vph": 150},
        ],
        "ambulances": [],
    },

    # ── 3. Off-Peak / Midday ──────────────────────────────────────────────────
    "off_peak": {
        "description": "Off-Peak midday 12:00-14:00 — low volume, balanced",
        "total_approx": 1150,
        "flows": [
            {"id": "flow_NS",   "type": "car",    "route": "route_NS", "vph": 300},
            {"id": "flow_NS_t", "type": "trotro", "route": "route_NS", "vph": 30},
            {"id": "flow_SN",   "type": "car",    "route": "route_SN", "vph": 250},
            {"id": "flow_SN_t", "type": "trotro", "route": "route_SN", "vph": 25},
            {"id": "flow_NE",   "type": "car", "route": "route_NE", "vph": 50},
            {"id": "flow_NW",   "type": "car", "route": "route_NW", "vph": 40},
            {"id": "flow_SE",   "type": "car", "route": "route_SE", "vph": 50},
            {"id": "flow_SW",   "type": "car", "route": "route_SW", "vph": 60},
            {"id": "flow_EW",   "type": "car",    "route": "route_EW", "vph": 120},
            {"id": "flow_EW_t", "type": "trotro", "route": "route_EW", "vph": 15},
            {"id": "flow_EN",   "type": "car",    "route": "route_EN", "vph": 60},
            {"id": "flow_ES",   "type": "car",    "route": "route_ES", "vph": 40},
            {"id": "flow_WE",   "type": "car",    "route": "route_WE", "vph": 50},
            {"id": "flow_WN",   "type": "car",    "route": "route_WN", "vph": 40},
            {"id": "flow_WS",   "type": "car",    "route": "route_WS", "vph": 20},
        ],
        "ambulances": [],
    },

    # ── 4. Weekend / Market Day ───────────────────────────────────────────────
    "weekend_market": {
        "description": "Weekend Market Day — heavy E/W (Aggrey St market traffic)",
        "total_approx": 1755,
        "flows": [
            # N/S reduced
            {"id": "flow_NS",   "type": "car",    "route": "route_NS", "vph": 250},
            {"id": "flow_NS_t", "type": "trotro", "route": "route_NS", "vph": 30},
            {"id": "flow_SN",   "type": "car",    "route": "route_SN", "vph": 200},
            {"id": "flow_SN_t", "type": "trotro", "route": "route_SN", "vph": 25},
            {"id": "flow_NE",   "type": "car", "route": "route_NE", "vph": 60},
            {"id": "flow_NW",   "type": "car", "route": "route_NW", "vph": 40},
            {"id": "flow_SE",   "type": "car", "route": "route_SE", "vph": 50},
            {"id": "flow_SW",   "type": "car", "route": "route_SW", "vph": 70},
            # E/W heavy (market traffic)
            {"id": "flow_EW",   "type": "car",    "route": "route_EW", "vph": 400},
            {"id": "flow_EW_t", "type": "trotro", "route": "route_EW", "vph": 80},
            {"id": "flow_EN",   "type": "car",    "route": "route_EN", "vph": 120},
            {"id": "flow_ES",   "type": "car",    "route": "route_ES", "vph": 80},
            # Guggisberg capped for 1-lane capacity
            {"id": "flow_WE",   "type": "car",    "route": "route_WE", "vph": 200},
            {"id": "flow_WN",   "type": "car",    "route": "route_WN", "vph": 100},
            {"id": "flow_WS",   "type": "car",    "route": "route_WS", "vph": 50},
        ],
        "ambulances": [],
    },

    # ── 5. Heavy Emergency ────────────────────────────────────────────────────
    "heavy_emergency": {
        "description": "Heavy Emergency — morning rush (ambulances deployed via UI)",
        "total_approx": 2640,
        "flows": [
            # Same flows as morning rush
            {"id": "flow_NS",   "type": "car",    "route": "route_NS", "vph": 820},
            {"id": "flow_NS_t", "type": "trotro", "route": "route_NS", "vph": 80},
            {"id": "flow_SN",   "type": "car",    "route": "route_SN", "vph": 250},
            {"id": "flow_SN_t", "type": "trotro", "route": "route_SN", "vph": 50},
            {"id": "flow_NE",   "type": "car", "route": "route_NE", "vph": 130},
            {"id": "flow_NW",   "type": "car", "route": "route_NW", "vph": 90},
            {"id": "flow_SE",   "type": "car", "route": "route_SE", "vph": 120},
            {"id": "flow_SW",   "type": "car", "route": "route_SW", "vph": 200},
            {"id": "flow_EW",   "type": "car",    "route": "route_EW", "vph": 280},
            {"id": "flow_EW_t", "type": "trotro", "route": "route_EW", "vph": 40},
            {"id": "flow_EN",   "type": "car",    "route": "route_EN", "vph": 180},
            {"id": "flow_ES",   "type": "car",    "route": "route_ES", "vph": 100},
            {"id": "flow_WE",   "type": "car",    "route": "route_WE", "vph": 100},
            {"id": "flow_WN",   "type": "car",    "route": "route_WN", "vph": 150},
            {"id": "flow_WS",   "type": "car",    "route": "route_WS", "vph": 50},
        ],
        "ambulances": [],
    },
}


# ═══════════════════════════════════════════════════════════════════════════════
# XML GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

def generate_route_xml(name: str) -> str:
    """Generate complete SUMO route XML for a named scenario."""
    scenario = SCENARIOS[name]
    desc = scenario["description"]
    total = scenario["total_approx"]

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!--",
        f"  ATCS-GH | Achimota/Neoplan Junction - {desc}",
        f"  Generated by generate_scenarios.py | ~{total} veh/hr total",
        "-->",
        "<routes>",
        "",
        VEHICLE_TYPES,
        "",
        ROUTE_DEFS,
        "",
        f"  <!-- Flows: {desc} -->",
    ]

    for f in scenario["flows"]:
        lines.append(
            f'  <flow id="{f["id"]}" type="{f["type"]}" route="{f["route"]}"'
            f'\n        begin="0" end="7200" vehsPerHour="{f["vph"]}"'
            f'\n        departLane="best" departSpeed="max"/>'
        )

    if scenario["ambulances"]:
        lines.append("")
        lines.append(f'  <!-- Emergency vehicles ({len(scenario["ambulances"])} ambulances) -->')
        for a in scenario["ambulances"]:
            lines.append(
                f'  <vehicle id="{a["id"]}" type="emergency" route="{a["route"]}"'
                f'\n           depart="{a["depart"]}" departLane="1" departSpeed="max"'
                f'\n           color="1,0,0"/>'
            )

    # Pedestrian crossing flows (scaled to scenario intensity)
    lines.append("")
    lines.append("  <!-- Pedestrian crossing flows -->")
    total_vph = sum(f["vph"] for f in scenario["flows"])
    # Scale pedestrian volume proportionally to vehicle volume
    # Morning rush baseline: ~2640 veh/hr → ~242 ped/hr total (reduced for flow)
    ped_scale = total_vph / 2640.0
    ped_flows = [
        ("ped_cross_N_e2w", "ACH_N2J", "ACH_J2N", int(60 * ped_scale)),
        ("ped_cross_N_w2e", "ACH_J2N", "ACH_N2J", int(60 * ped_scale)),
        ("ped_cross_S_e2w", "ACH_S2J", "ACH_J2S", int(60 * ped_scale)),
        ("ped_cross_S_w2e", "ACH_J2S", "ACH_S2J", int(60 * ped_scale)),
        ("ped_cross_E_n2s", "AGG_E2J", "AGG_J2E", int(36 * ped_scale)),
        ("ped_cross_E_s2n", "AGG_J2E", "AGG_E2J", int(36 * ped_scale)),
        ("ped_cross_W_n2s", "GUG_W2J", "GUG_J2W", int(25 * ped_scale)),
        ("ped_cross_W_s2n", "GUG_J2W", "GUG_W2J", int(25 * ped_scale)),
    ]
    for pid, from_edge, to_edge, per_hour in ped_flows:
        if per_hour > 0:
            lines.append(
                f'  <personFlow id="{pid}" type="ped_fast" begin="0" end="7200" perHour="{per_hour}">'
                f'\n    <walk from="{from_edge}" to="{to_edge}"/>'
                f'\n  </personFlow>'
            )

    lines.append("")
    lines.append("</routes>")
    return "\n".join(lines) + "\n"


def generate_all() -> None:
    """Generate route files for all scenarios."""
    SCENARIO_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 65)
    print("  ATCS-GH -- Demand Scenario Generator")
    print("=" * 65)
    print()

    for name in SCENARIOS:
        scenario = SCENARIOS[name]
        xml = generate_route_xml(name)
        out_path = SCENARIO_DIR / f"{name}.rou.xml"
        out_path.write_text(xml, encoding="utf-8")

        total_vph = sum(f["vph"] for f in scenario["flows"])
        n_amb = len(scenario["ambulances"])
        print(f"  {name:<20s}  {total_vph:>5d} veh/hr  {n_amb} ambulance(s)  -> {out_path.name}")

    print()
    print(f"  Generated {len(SCENARIOS)} scenario files in:")
    print(f"    {SCENARIO_DIR}")
    print("=" * 65)


# ═══════════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate ATCS-GH demand scenario route files")
    parser.add_argument("--list", action="store_true", help="List available scenarios and exit")
    args = parser.parse_args()

    if args.list:
        for name, s in SCENARIOS.items():
            total = sum(f["vph"] for f in s["flows"])
            print(f"  {name:<20s}  {total:>5d} veh/hr  {s['description']}")
    else:
        generate_all()
