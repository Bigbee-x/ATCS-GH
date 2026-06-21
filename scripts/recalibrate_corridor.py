#!/usr/bin/env python3
"""
Recalibrate the corridor morning-rush demand to a solvable cliff (Phase 2).

Why: at full demand (~3330 veh/hr) the protected-left fixed-timer baseline
gridlocks J0 (998s wait, queue ~195) — it grades ANY controller against an
over-capacity target. Mirroring scripts/recalibrate_scenarios.py for the single
junction, we scale every vehsPerHour flow by a factor to the point where the
fixed timer is still visibly pressured (a real, honest win to beat) yet the
corridor is physically solvable by an adaptive controller. Pedestrian
personFlows (perHour) are left unchanged — they are not the over-capacity driver.

The pristine original is backed up ONCE; scaling always reads from that backup,
so the script is idempotent (re-runnable at any factor without compounding).

Usage:
    python scripts/recalibrate_corridor.py --factor 0.6   # scale to 60% of full
    python scripts/recalibrate_corridor.py --restore      # restore pristine original
"""
import re
import shutil
import argparse
from pathlib import Path

ROOT   = Path(__file__).resolve().parent.parent
SIM    = ROOT / "simulation"
SRC    = SIM / "corridor_routes.rou.xml"
BACKUP = SIM / "_pre_recal_corridor" / "corridor_routes.rou.xml"


def total_demand(txt: str) -> float:
    """Sum of all vehsPerHour flows (pedestrian perHour is excluded)."""
    return sum(float(v) for v in re.findall(r'vehsPerHour="([\d.]+)"', txt))


def main():
    ap = argparse.ArgumentParser(description="Recalibrate corridor morning demand")
    ap.add_argument("--factor", type=float, default=None,
                    help="Scale every vehsPerHour flow by this factor")
    ap.add_argument("--restore", action="store_true",
                    help="Restore the pristine pre-recal original and exit")
    args = ap.parse_args()

    BACKUP.parent.mkdir(exist_ok=True)
    if not BACKUP.exists():                    # back up pristine original once
        shutil.copy2(SRC, BACKUP)
        print(f"  Backed up pristine original -> {BACKUP.relative_to(ROOT)}")

    if args.restore:
        shutil.copy2(BACKUP, SRC)
        print(f"  Restored pristine original ({total_demand(BACKUP.read_text()):.0f} veh/hr)")
        return

    if args.factor is None:
        ap.error("give --factor F or --restore")

    original = BACKUP.read_text()              # always scale FROM the pristine backup
    before = total_demand(original)
    scaled = re.sub(r'vehsPerHour="([\d.]+)"',
                    lambda m, f=args.factor: f'vehsPerHour="{float(m.group(1)) * f:.1f}"',
                    original)
    after = total_demand(scaled)
    SRC.write_text(scaled)
    print(f"  corridor demand: {before:.0f} -> {after:.0f} veh/hr  (x{args.factor})")


if __name__ == "__main__":
    main()
