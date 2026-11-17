#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# TrafIQ 3D Visualizer Launcher
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
# All arguments are forwarded to corridor_visualizer_server.py.
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  TrafIQ 3D Visualizer Launcher"
echo "═══════════════════════════════════════════════════════════"

# ── Pre-flight checks ────────────────────────────────────────

# Prefer the same project environment as the Godot launcher.
TRAFIQ_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
if [ ! -x "$TRAFIQ_PYTHON" ]; then
    TRAFIQ_PYTHON="$(command -v python3 || true)"
fi
if [ -z "$TRAFIQ_PYTHON" ]; then
    echo "[ERROR] Python not found. Set up the project .venv first."
    exit 1
fi
if ! "$TRAFIQ_PYTHON" -c "import websockets, traci, torch" &> /dev/null; then
    echo "[ERROR] Missing dependencies. Install requirements.txt in the project .venv."
    exit 1
fi

# Check SUMO network exists
if [ ! -f "$PROJECT_ROOT/simulation/corridor.net.xml" ]; then
    echo "[ERROR] SUMO network not built."
    echo "  Restore the calibrated simulation/corridor.net.xml and route files."
    exit 1
fi

# ── Start the Python WebSocket server ────────────────────────

echo ""
echo "[1/2] Starting WebSocket server..."
"$TRAFIQ_PYTHON" "$SCRIPT_DIR/corridor_visualizer_server.py" "$@" &
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
echo "      1. Open Godot 4.6+"
echo "      2. Import project: $PROJECT_ROOT/visualizer/project.godot"
echo "      3. Open CorridorMain.tscn; set WebSocketClient.auto_start_server=false"
echo "      4. Match its server URL to this server, then press F6"
echo "      For automatic startup instead, stop this script and use F5 → Launch corridor."
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
