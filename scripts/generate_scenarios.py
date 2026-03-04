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
         guiShape="passenger" color="0.6,0.6,0.9"/>

  <!-- Trotro (shared minibus) — slower, longer -->
  <vType id="trotro"
         accel="1.8" decel="3.5" emergencyDecel="7.0" sigma="0.7"
         length="7.0" minGap="3.0" maxSpeed="11.11"
         guiShape="bus/city" color="1.0,0.8,0.0"/>

  <!-- Emergency vehicle (ambulance) -->
  <vType id="emergency"
         accel="3.5" decel="6.0" emergencyDecel="9.0" sigma="0.1"
         length="5.5" minGap="2.0" maxSpeed="16.67"
         guiShape="emergency" color="1.0,0.0,0.0" speedFactor="1.2"/>""")

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
        "ambulances": [
            {"id": "ambulance_1", "route": "route_NS", "depart": 130},
            {"id": "ambulance_2", "route": "route_WN", "depart": 700},
            {"id": "ambulance_3", "route": "route_SN", "depart": 1800},
        ],
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
        "ambulances": [
            {"id": "ambulance_1", "route": "route_SN", "depart": 200},
            {"id": "ambulance_2", "route": "route_EN", "depart": 900},
            {"id": "ambulance_3", "route": "route_NS", "depart": 2000},
        ],
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
        "ambulances": [
            {"id": "ambulance_1", "route": "route_NS", "depart": 3600},
        ],
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
        "ambulances": [
            {"id": "ambulance_1", "route": "route_EW", "depart": 500},
            {"id": "ambulance_2", "route": "route_WN", "depart": 4000},
        ],
    },

    # ── 5. Heavy Emergency ────────────────────────────────────────────────────
    "heavy_emergency": {
        "description": "Heavy Emergency — morning rush + 8 ambulances from all approaches",
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
        "ambulances": [
            {"id": "ambulance_1", "route": "route_NS", "depart": 120},
            {"id": "ambulance_2", "route": "route_SN", "depart": 400},
            {"id": "ambulance_3", "route": "route_WN", "depart": 700},
            {"id": "ambulance_4", "route": "route_EN", "depart": 1200},
            {"id": "ambulance_5", "route": "route_NS", "depart": 1800},
            {"id": "ambulance_6", "route": "route_SN", "depart": 2400},
            {"id": "ambulance_7", "route": "route_EW", "depart": 3600},
            {"id": "ambulance_8", "route": "route_WN", "depart": 5400},
        ],
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
                f'\n           depart="{a["depart"]}" departLane="0" departSpeed="max"'
                f'\n           color="1,0,0"/>'
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
