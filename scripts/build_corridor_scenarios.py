#!/usr/bin/env python3
"""
Build the corridor's evening + off-peak scenario route files from the morning
template (simulation/corridor_routes.rou.xml).

The corridor used to train on ONE scenario (morning rush, S→N-heavy). That risks
overfitting to a single demand pattern — the single junction only became robust
once it trained on a *rotation* (continuous_day + morning + evening + weekend).
This script generates the two additional corridor scenarios the rotation needs:

  • evening  — the directional FLIP: heavy N→S outbound commute (the morning's
               S→N / N→S corridor flows are swapped). Same local cross-traffic.
               Shifts the bottleneck from J0 (morning) to J2 (evening), so every
               agent gets exposure to a heavy load, not just J0.

  • off_peak — light, balanced midday demand (all flows scaled down, the corridor
               through-traffic levelled out N↔S). Teaches the agents graceful
               low-demand behaviour instead of over-serving empty approaches.

Idempotent: always regenerates both files from the morning template. Demand is
then recalibrated/verified against the protected-timer baseline (Phase B) before
training, exactly like the morning scenario was.

    python scripts/build_corridor_scenarios.py
"""
from __future__ import annotations

import re
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent.parent / "simulation"
TEMPLATE = SIM_DIR / "corridor_routes.rou.xml"
EVENING = SIM_DIR / "corridor_routes_evening.rou.xml"
OFFPEAK = SIM_DIR / "corridor_routes_offpeak.rou.xml"

# Off-peak: scale all vehicle demand to this fraction of morning, and pedestrians
# to half. Balanced (non-directional) corridor through-traffic is set explicitly.
OFFPEAK_VEH_FACTOR = 0.45
OFFPEAK_PED_FACTOR = 0.5
OFFPEAK_CORRIDOR = {            # balanced, light through-traffic both ways
    "f_S2N": 170.0, "f_S2N_t": 20.0,
    "f_N2S": 170.0, "f_N2S_t": 20.0,
}

EVENING_HEADER = """<!--
  ATCS-GH | N6 Nsawam Road Corridor — Evening Rush Hour Demand
  ═════════════════════════════════════════════════════════════
  3-junction corridor: J0 (Aggrey/Guggisberg), J1 (Asylum Down/Ring),
  J2 (Nima/Tesano) along Achimota Forest Road.

  Simulates 17:00-19:00 PM (7200 seconds) — peak evening OUTBOUND commute.
  The directional flip of the morning rush: heavy N→S, light S→N. Same local
  cross-traffic. Bottleneck shifts to J2 (the N→S entry junction).
  GENERATED from corridor_routes.rou.xml by scripts/build_corridor_scenarios.py
-->"""

OFFPEAK_HEADER = """<!--
  ATCS-GH | N6 Nsawam Road Corridor — Off-Peak (Midday) Demand
  ═════════════════════════════════════════════════════════════
  3-junction corridor: J0 (Aggrey/Guggisberg), J1 (Asylum Down/Ring),
  J2 (Nima/Tesano) along Achimota Forest Road.

  Simulates ~11:00-13:00 (7200 seconds) — light, balanced midday traffic.
  All vehicle flows scaled to %d%% of morning; corridor through-traffic levelled
  N↔S. Teaches graceful low-demand behaviour (no over-serving empty approaches).
  GENERATED from corridor_routes.rou.xml by scripts/build_corridor_scenarios.py
-->""" % int(OFFPEAK_VEH_FACTOR * 100)


def _replace_header(text: str, new_header: str) -> str:
    """Swap the leading <!-- ... --> comment block for new_header."""
    return re.sub(r"<!--.*?-->", new_header, text, count=1, flags=re.DOTALL)


def _set_flow_rate(text: str, flow_id: str, rate: float) -> str:
    """Set vehsPerHour for a specific <flow id="...">, whose attributes span 2 lines."""
    pattern = re.compile(
        r'(<flow id="%s"[^>]*?vehsPerHour=")([\d.]+)(")' % re.escape(flow_id),
        flags=re.DOTALL,
    )
    new_text, n = pattern.subn(lambda m: f"{m.group(1)}{rate:.1f}{m.group(3)}", text)
    if n != 1:
        raise SystemExit(f"  ! expected exactly 1 '{flow_id}' flow, found {n}")
    return new_text


def build_evening(template: str) -> str:
    text = _replace_header(template, EVENING_HEADER)
    # Read morning's corridor through-rates, then swap heavy↔light direction.
    rates = {fid: float(re.search(
        r'<flow id="%s"[^>]*?vehsPerHour="([\d.]+)"' % fid, text, re.DOTALL).group(1))
        for fid in ("f_S2N", "f_S2N_t", "f_N2S", "f_N2S_t")}
    text = _set_flow_rate(text, "f_S2N", rates["f_N2S"])
    text = _set_flow_rate(text, "f_S2N_t", rates["f_N2S_t"])
    text = _set_flow_rate(text, "f_N2S", rates["f_S2N"])
    text = _set_flow_rate(text, "f_N2S_t", rates["f_S2N_t"])
    return text


def build_offpeak(template: str) -> str:
    text = _replace_header(template, OFFPEAK_HEADER)
    # Scale all vehicle demand down…
    text = re.sub(r'vehsPerHour="([\d.]+)"',
                  lambda m: f'vehsPerHour="{float(m.group(1)) * OFFPEAK_VEH_FACTOR:.1f}"',
                  text)
    # …and pedestrians.
    text = re.sub(r'perHour="(\d+)"',
                  lambda m: f'perHour="{int(round(int(m.group(1)) * OFFPEAK_PED_FACTOR))}"',
                  text)
    # Override corridor through-traffic to balanced, light levels.
    for fid, rate in OFFPEAK_CORRIDOR.items():
        text = _set_flow_rate(text, fid, rate)
    return text


def _veh_total(text: str) -> float:
    return sum(float(v) for v in re.findall(r'vehsPerHour="([\d.]+)"', text))


def main() -> None:
    template = TEMPLATE.read_text()
    print(f"Template: {TEMPLATE.name}  (total {_veh_total(template):.0f} veh/hr)")
    for path, builder in ((EVENING, build_evening), (OFFPEAK, build_offpeak)):
        out = builder(template)
        path.write_text(out)
        print(f"  wrote {path.name:34} total {_veh_total(out):.0f} veh/hr")


if __name__ == "__main__":
    main()
