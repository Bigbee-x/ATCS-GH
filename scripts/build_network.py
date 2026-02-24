#!/usr/bin/env python3
"""
ATCS-GH | Network Builder
══════════════════════════
Generates simulation/intersection.net.xml from the hand-crafted
nodes.nod.xml and edges.edg.xml files using SUMO's `netconvert` tool.

Run this ONCE after installing SUMO, before any simulation:
    python scripts/build_network.py

What it does:
  1. Verifies SUMO is installed and SUMO_HOME is set
  2. Runs netconvert with our node + edge files
  3. Outputs intersection.net.xml (the compiled network SUMO needs)

If SUMO is not installed, it prints clear installation instructions.
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path


# ── Paths ─────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SIM_DIR      = PROJECT_ROOT / "simulation"
NODES_FILE   = SIM_DIR / "nodes.nod.xml"
EDGES_FILE   = SIM_DIR / "edges.edg.xml"
OUTPUT_NET   = SIM_DIR / "intersection.net.xml"


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


# ── Main Build ────────────────────────────────────────────────────────────────

def build_network():
    print("=" * 55)
    print("  ATCS-GH Network Builder")
    print("=" * 55)

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

    # 2. Verify input files
    for f in [NODES_FILE, EDGES_FILE]:
        if not f.exists():
            print(f"\n[ERROR] Missing input file: {f}")
            sys.exit(1)
    print(f"[OK] Input files : {SIM_DIR}")

    # 3. Run netconvert
    # --tls.default-type static  → generate a fixed (non-actuated) traffic light
    # --no-warnings              → keep output clean
    cmd = [
        netconvert,
        "--node-files",        str(NODES_FILE),
        "--edge-files",        str(EDGES_FILE),
        "--output-file",       str(OUTPUT_NET),
        "--tls.default-type",  "static",
        "--no-warnings",
    ]

    print(f"\n[RUN] netconvert ...")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print("[ERROR] netconvert failed:")
        print(result.stderr)
        sys.exit(1)

    if not OUTPUT_NET.exists():
        print(f"[ERROR] Output not created: {OUTPUT_NET}")
        sys.exit(1)

    size_kb = OUTPUT_NET.stat().st_size / 1024
    print(f"[OK] Network built → {OUTPUT_NET}")
    print(f"     File size: {size_kb:.1f} KB")

    # 4. Quick sanity check: count junctions and edges in the output
    content = OUTPUT_NET.read_text()
    n_junctions = content.count("<junction ")
    n_edges     = content.count("<edge ")
    print(f"     Junctions: {n_junctions}  |  Edges: {n_edges}")

    print("\n" + "=" * 55)
    print("  Network ready. Next steps:")
    print("  1.  python scripts/run_baseline.py")
    print("  2.  python scripts/run_baseline.py --gui   (visual mode)")
    print("=" * 55 + "\n")


if __name__ == "__main__":
    build_network()
