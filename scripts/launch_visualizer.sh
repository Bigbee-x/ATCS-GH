#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# ATCS-GH 3D Visualizer Launcher
# ═══════════════════════════════════════════════════════════════
# Starts the Python WebSocket server (SUMO + DQN agent), then
# instructs the user to open the Godot 4 project.
#
# Usage:
#   ./scripts/launch_visualizer.sh              # AI mode
#   ./scripts/launch_visualizer.sh --demo       # Random actions (no model)
#   ./scripts/launch_visualizer.sh --manual     # Manual override from Godot UI
#   ./scripts/launch_visualizer.sh --speed 5    # 5x simulation speed
#
# All arguments are forwarded to visualizer_server.py.
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ATCS-GH 3D Visualizer Launcher"
echo "═══════════════════════════════════════════════════════════"

# ── Pre-flight checks ────────────────────────────────────────

# Check Python
if ! command -v python3 &> /dev/null; then
    echo "[ERROR] python3 not found. Please install Python 3.10+."
    exit 1
fi

# Check websockets module
if ! python3 -c "import websockets" &> /dev/null; then
    echo "[WARN] 'websockets' module not found. Installing..."
    pip3 install websockets
fi

# Check SUMO network exists
if [ ! -f "$PROJECT_ROOT/simulation/intersection.net.xml" ]; then
    echo "[ERROR] SUMO network not built."
    echo "  Run:  python3 scripts/build_network.py"
    exit 1
fi

# ── Start the Python WebSocket server ────────────────────────

echo ""
echo "[1/2] Starting WebSocket server..."
python3 "$SCRIPT_DIR/visualizer_server.py" "$@" &
SERVER_PID=$!
echo "      Server PID: $SERVER_PID"
echo "      WebSocket : ws://localhost:8765"

# Give the server a moment to start
sleep 2

# Check if server is still running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "[ERROR] Server failed to start. Check output above."
    exit 1
fi

# ── Instruct user to open Godot ──────────────────────────────

echo ""
echo "[2/2] Open the Godot 4 project:"
echo ""
echo "      1. Open Godot 4.2+"
echo "      2. Import project: $PROJECT_ROOT/visualizer/project.godot"
echo "      3. Press F5 (Play) to start the visualizer"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Server is running. Press Ctrl+C to stop everything."
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Wait for server (Ctrl+C to stop) ─────────────────────────

cleanup() {
    echo ""
    echo "[STOP] Shutting down server (PID $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    echo "[STOP] Done."
}

trap cleanup EXIT INT TERM

wait $SERVER_PID
