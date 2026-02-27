extends Node
class_name WebSocketClient
## WebSocket client for the ATCS-GH visualizer server.
##
## Connects to the Python WebSocket server, receives JSON state packets,
## and emits signals that other nodes (Intersection, VehicleManager, UI)
## listen to for live updates.
##
## Handles:
##   - Automatic reconnection on dropped connections
##   - Graceful handling of server not yet running (startup order independence)
##   - JSON parsing with error recovery
##   - Sending manual override commands back to the server
##
## Godot 4.2+ WebSocket API:
##   Uses WebSocketPeer (not the old WebSocketClient class).
##   Must call poll() manually in _process(), detect state transitions,
##   and read packets with get_packet().

# ── Signals ──────────────────────────────────────────────────────────────────
## Emitted when a state_update packet arrives from the server
signal state_updated(data: Dictionary)
## Emitted for per-second vehicle position updates (smooth animation)
signal vehicle_updated(data: Dictionary)
## Emitted when the simulation run finishes (sim_complete)
signal sim_completed(data: Dictionary)
## Emitted when the server restarts a simulation run
signal sim_restarted(data: Dictionary)
## Emitted when connection status changes (true = connected, false = lost)
signal connection_changed(is_connected: bool)

# ── Configuration ────────────────────────────────────────────────────────────
## WebSocket server URL (Python visualizer_server.py)
@export var server_url: String = "ws://localhost:8765"
## Seconds to wait before retrying after a failed connection
@export var reconnect_delay: float = 3.0
## Maximum reconnect attempts before giving up (-1 = infinite)
@export var max_reconnect_attempts: int = -1

# ── Internal state ───────────────────────────────────────────────────────────
var _socket: WebSocketPeer = WebSocketPeer.new()
var _is_connected: bool = false
var _was_ever_connected: bool = false
var _reconnect_timer: float = 0.0
var _reconnect_attempts: int = 0
var _last_state: WebSocketPeer.State = WebSocketPeer.STATE_CLOSED
var _last_packet_time: float = 0.0  # Time of last received packet

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	print("[WS] WebSocket client initialising...")
	print("[WS] Target server: %s" % server_url)
	_attempt_connection()


func _process(delta: float) -> void:
	# Poll the socket to process incoming data
	_socket.poll()
	var state: WebSocketPeer.State = _socket.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			_handle_open_state()

		WebSocketPeer.STATE_CONNECTING:
			pass  # Wait for handshake to complete

		WebSocketPeer.STATE_CLOSING:
			pass  # Wait for close to complete

		WebSocketPeer.STATE_CLOSED:
			_handle_closed_state(delta)

	_last_state = state


func _handle_open_state() -> void:
	## Process packets while connection is open.
	# Detect fresh connection
	if not _is_connected:
		_is_connected = true
		_was_ever_connected = true
		_reconnect_attempts = 0
		print("[WS] Connected to server!")
		connection_changed.emit(true)

	# Read all available packets (there may be multiple queued)
	while _socket.get_available_packet_count() > 0:
		var raw_data: PackedByteArray = _socket.get_packet()
		var text: String = raw_data.get_string_from_utf8()
		_last_packet_time = Time.get_ticks_msec() / 1000.0
		_parse_and_dispatch(text)


func _handle_closed_state(delta: float) -> void:
	## Handle disconnection and auto-reconnect.
	if _is_connected:
		# We just lost the connection
		_is_connected = false
		var code: int = _socket.get_close_code()
		var reason: String = _socket.get_close_reason()
		print("[WS] Disconnected (code=%d, reason='%s')" % [code, reason])
		connection_changed.emit(false)

	# Auto-reconnect with delay
	_reconnect_timer -= delta
	if _reconnect_timer <= 0.0:
		if max_reconnect_attempts >= 0 and _reconnect_attempts >= max_reconnect_attempts:
			# Give up after max attempts
			if _reconnect_attempts == max_reconnect_attempts:
				print("[WS] Max reconnect attempts reached. Stopping.")
				_reconnect_attempts += 1  # Prevent repeated prints
			return

		_attempt_connection()


# ── Connection management ────────────────────────────────────────────────────

func _attempt_connection() -> void:
	## Try to connect to the WebSocket server.
	_reconnect_attempts += 1
	_reconnect_timer = reconnect_delay

	if _reconnect_attempts > 1:
		print("[WS] Reconnecting (attempt %d)..." % _reconnect_attempts)
	else:
		print("[WS] Connecting to %s..." % server_url)

	# Create a fresh socket for each connection attempt
	# (WebSocketPeer cannot be reused after close in Godot 4)
	_socket = WebSocketPeer.new()
	var err: int = _socket.connect_to_url(server_url)
	if err != OK:
		push_warning("[WS] connect_to_url() failed with error %d" % err)


# ── Packet parsing ───────────────────────────────────────────────────────────

func _parse_and_dispatch(text: String) -> void:
	## Parse a JSON packet and emit the appropriate signal.
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_warning("[WS] JSON parse error (line %d): %s" % [
			json.get_error_line(), json.get_error_message()])
		return

	var data: Dictionary = json.data
	if not data is Dictionary:
		push_warning("[WS] Received non-dict JSON, ignoring")
		return

	var packet_type: String = data.get("type", "")

	match packet_type:
		"state_update":
			state_updated.emit(data)
		"vehicle_update":
			vehicle_updated.emit(data)
		"sim_complete":
			sim_completed.emit(data)
		"sim_restart":
			sim_restarted.emit(data)
		_:
			push_warning("[WS] Unknown packet type: '%s'" % packet_type)


# ── Public API ───────────────────────────────────────────────────────────────

func send_override(approach: String) -> void:
	## Send a manual override command to the Python server.
	## approach: One of "north", "south", "east", "west"
	if not _is_connected:
		push_warning("[WS] Cannot send override — not connected")
		return

	var msg: String = JSON.stringify({
		"action": "force_green",
		"approach": approach,
	})
	_socket.send_text(msg)
	print("[WS] Sent override: force green for %s" % approach)


func is_connected_to_server() -> bool:
	## Returns true if currently connected to the Python server.
	return _is_connected


func get_seconds_since_last_packet() -> float:
	## Returns seconds since the last packet was received. Useful for stale data detection.
	if _last_packet_time <= 0.0:
		return -1.0  # Never received a packet
	return (Time.get_ticks_msec() / 1000.0) - _last_packet_time
