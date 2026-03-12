#!/usr/bin/env python3
"""
ATCS-GH | Network Builder
══════════════════════════
Generates SUMO network files from hand-crafted node + edge definitions
using SUMO's `netconvert` tool.

Supports two modes:
  python scripts/build_network.py               # Single junction (intersection.net.xml)
  python scripts/build_network.py --corridor     # 3-junction corridor (corridor.net.xml)

What it does:
  1. Verifies SUMO is installed and SUMO_HOME is set
  2. Runs netconvert with the appropriate node + edge files
  3. Outputs the compiled .net.xml network SUMO needs
"""

import os
import sys
import subprocess
import shutil
import argparse
from pathlib import Path


# ── Paths ─────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SIM_DIR      = PROJECT_ROOT / "simulation"

# Single junction files
NODES_FILE       = SIM_DIR / "nodes.nod.xml"
EDGES_FILE       = SIM_DIR / "edges.edg.xml"
OUTPUT_NET       = SIM_DIR / "intersection.net.xml"

# Corridor files
CORR_NODES_FILE  = SIM_DIR / "corridor_nodes.nod.xml"
CORR_EDGES_FILE  = SIM_DIR / "corridor_edges.edg.xml"
CORR_OUTPUT_NET  = SIM_DIR / "corridor.net.xml"


# ── SUMO Detection ────────────────────────────────────────────────────────────

def find_sumo_home() -> str | None:
    """Return the SUMO installation directory, or None if not found."""
    # Respect existing environment variable
    if "SUMO_HOME" in os.environ and os.path.isdir(os.environ["SUMO_HOME"]):
        return os.environ["SUMO_HOME"]

    # Check pip-installed eclipse-sumo package first (most reliable on modern macOS)
    try:
        import sumo as _sumo_pkg
        path = _sumo_pkg.SUMO_HOME
        if os.path.isdir(path):
            os.environ["SUMO_HOME"] = path
            return path
    except ImportError:
        pass

    # Common macOS locations (Homebrew intel + Apple Silicon)
    candidates = [
        "/opt/homebrew/opt/sumo/share/sumo",  # macOS Homebrew (dlr-ts tap)
        "/opt/homebrew/share/sumo",           # macOS Apple Silicon alt
        "/usr/local/share/sumo",              # macOS Intel Homebrew
        "/usr/local/opt/sumo/share/sumo",     # macOS Intel alternate
        "/usr/share/sumo",                    # Linux system install
    ]
    for path in candidates:
        if os.path.isdir(path):
            os.environ["SUMO_HOME"] = path
            return path
    return None


def find_binary(name: str) -> str | None:
    """Locate a binary in PATH or known SUMO bin directories."""
    found = shutil.which(name)
    if found:
        return found

    sumo_home = os.environ.get("SUMO_HOME", "")
    for path in [
        os.path.join(sumo_home, "bin", name),
        f"/opt/homebrew/bin/{name}",
        f"/usr/local/bin/{name}",
    ]:
        if os.path.isfile(path):
            return path
    return None


# ── Installation Instructions ─────────────────────────────────────────────────

def print_install_instructions():
    print("""
╔══════════════════════════════════════════════════════════════╗
║           SUMO Installation Instructions (macOS)            ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Option 1 — Homebrew (recommended, easiest):                 ║
║    brew install sumo                                         ║
║                                                              ║
║    Then add to ~/.zshrc:                                     ║
║    export SUMO_HOME=/opt/homebrew/share/sumo                 ║
║    export PATH=$SUMO_HOME/bin:$PATH                          ║
║    source ~/.zshrc                                           ║
║                                                              ║
║  Option 2 — Official installer (.dmg):                       ║
║    https://sumo.dlr.de/docs/Downloads.php                   ║
║    → Choose: macOS package                                   ║
║    Then set SUMO_HOME to the install path.                   ║
║                                                              ║
║  Verify installation:                                        ║
║    sumo --version                                            ║
║    netconvert --version                                      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
""")


# ── Build Functions ──────────────────────────────────────────────────────────

def _run_netconvert(netconvert: str, nodes: Path, edges: Path, output: Path,
                    label: str) -> None:
    """Run netconvert with given input files and produce output network."""
    for f in [nodes, edges]:
        if not f.exists():
            print(f"\n[ERROR] Missing input file: {f}")
            sys.exit(1)
    print(f"[OK] Input files : {nodes.name}, {edges.name}")

    cmd = [
        netconvert,
        "--node-files",        str(nodes),
        "--edge-files",        str(edges),
        "--output-file",       str(output),
        "--tls.default-type",  "static",
        "--crossings.guess",                   # Auto-add pedestrian crossings at TL junctions
        "--crossings.guess.speed-threshold", "13.89",
        "--no-warnings",
    ]

    print(f"\n[RUN] netconvert ({label}) ...")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print("[ERROR] netconvert failed:")
        print(result.stderr)
        sys.exit(1)

    if not output.exists():
        print(f"[ERROR] Output not created: {output}")
        sys.exit(1)

    size_kb = output.stat().st_size / 1024
    print(f"[OK] Network built → {output}")
    print(f"     File size: {size_kb:.1f} KB")

    # Quick sanity check
    content = output.read_text()
    n_junctions = content.count("<junction ")
    n_edges     = content.count("<edge ")
    n_tls       = content.count("<tlLogic ")
    print(f"     Junctions: {n_junctions}  |  Edges: {n_edges}  |  Traffic lights: {n_tls}")


def build_network(corridor: bool = False):
    mode = "Corridor (3 Junctions)" if corridor else "Single Junction"
    print("=" * 60)
    print(f"  ATCS-GH Network Builder — {mode}")
    print("=" * 60)

    # 1. Verify SUMO
    sumo_home = find_sumo_home()
    if not sumo_home:
        print("\n[ERROR] SUMO not found on this machine.")
        print_install_instructions()
        sys.exit(1)
    print(f"[OK] SUMO home  : {sumo_home}")

    netconvert = find_binary("netconvert")
    if not netconvert:
        print("\n[ERROR] 'netconvert' binary not found in PATH or SUMO bin.")
        print("        Ensure $SUMO_HOME/bin is in your PATH.")
        print_install_instructions()
        sys.exit(1)
    print(f"[OK] netconvert : {netconvert}")

    if corridor:
        _run_netconvert(netconvert, CORR_NODES_FILE, CORR_EDGES_FILE,
                        CORR_OUTPUT_NET, "corridor")
        print("\n" + "=" * 60)
        print("  Corridor network ready. Next steps:")
        print("  1.  python scripts/train_corridor.py")
        print("  2.  python scripts/run_corridor_baseline.py --gui")
        print("=" * 60 + "\n")
    else:
        _run_netconvert(netconvert, NODES_FILE, EDGES_FILE,
                        OUTPUT_NET, "single junction")
        print("\n" + "=" * 60)
        print("  Network ready. Next steps:")
        print("  1.  python scripts/run_baseline.py")
        print("  2.  python scripts/run_baseline.py --gui   (visual mode)")
        print("=" * 60 + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="ATCS-GH Network Builder")
    parser.add_argument("--corridor", action="store_true",
                        help="Build 3-junction corridor network instead of single junction")
    parser.add_argument("--all", action="store_true",
                        help="Build both single junction and corridor networks")
    args = parser.parse_args()

    if args.all:
        build_network(corridor=False)
        print()
        build_network(corridor=True)
    elif args.corridor:
        build_network(corridor=True)
    else:
        build_network(corridor=False)
