extends Node
## Autoload singleton that manages the lifecycle of Python SUMO servers.
##
## Spawns visualizer_server.py or corridor_visualizer_server.py as a
## background process, redirecting stdout/stderr to a log file. Monitors
## the process via timer-based polling. Kills the process on shutdown.
##
## Registered in project.godot [autoload] as "ServerManager".

# ── Signals ─────────────────────────────────────────────────────────────────
signal server_started(server_type_name: String)
signal server_stopped()
signal server_log_updated(new_text: String)
signal server_error(message: String)

# ── Server types ────────────────────────────────────────────────────────────
enum ServerType { NONE, SINGLE_JUNCTION, CORRIDOR }

# ── Configuration ───────────────────────────────────────────────────────────
## Python interpreter candidates, first hit wins. Osborn's pyenv build leads
## (it has torch + eclipse-sumo installed); the rest make the launcher work on
## any other machine with the requirements installed (see requirements.txt).
const PYTHON_CANDIDATES: Array = [
	"/Users/osborn/.pyenv/versions/3.11.7/bin/python3",
	"/opt/homebrew/bin/python3",
	"/usr/local/bin/python3",
	"/usr/bin/python3",
]
var PYTHON_PATH: String = ""   # resolved in _ready from PYTHON_CANDIDATES
const LOG_FILE := "/tmp/trafiq_server.log"
# Override for isolated integration tests; normal sessions retain the familiar log.
var log_file_path: String = LOG_FILE
const DASHBOARD_LOG := "/tmp/trafiq_dashboard.log"
const POLL_INTERVAL := 1.0        # Seconds between health checks / log reads
const PORT := 8765
const DASHBOARD_PORT := 5050
const DASHBOARD_SCRIPT := "dashboard/app.py"

## Default playback pace. Geometry is metric; playback speed is independent
## of road dimensions and never changes the policy's simulation-time cadence.
const DEFAULT_SIM_SPEED: float = 1.5

const SERVER_SCRIPTS: Dictionary = {
	ServerType.SINGLE_JUNCTION: "scripts/visualizer_server.py",
	ServerType.CORRIDOR: "scripts/corridor_visualizer_server.py",
}

const SERVER_NAMES: Dictionary = {
	ServerType.NONE: "None",
	ServerType.SINGLE_JUNCTION: "Single Junction",
	ServerType.CORRIDOR: "N6 Corridor",
}

# ── State ───────────────────────────────────────────────────────────────────
var current_server: ServerType = ServerType.NONE
var server_pid: int = -1
var _dashboard_pid: int = -1
var _log_file_pos: int = 0
var _is_starting: bool = false
var active_port: int = PORT
var last_error: String = ""
var _poll_timer: Timer

# ── Computed paths ──────────────────────────────────────────────────────────
var _project_root: String = ""     # Parent directory of the visualizer project


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_resolve_project_root()

	# Create the poll timer (starts when a server is launched)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.timeout.connect(_poll_server)
	add_child(_poll_timer)

	# Clean shutdown hooks
	get_tree().auto_accept_quit = false  # Let us intercept quit
	tree_exiting.connect(_on_tree_exiting)

	# Resolve the Python interpreter. The project's own virtualenv wins
	# (uv venv --python 3.11 .venv), then the first existing candidate.
	var venv_python: String = _project_root.path_join(".venv/bin/python3")
	if FileAccess.file_exists(venv_python):
		PYTHON_PATH = venv_python
	else:
		for cand in PYTHON_CANDIDATES:
			if FileAccess.file_exists(cand):
				PYTHON_PATH = cand
				break
	if PYTHON_PATH.is_empty():
		PYTHON_PATH = "python3"   # last resort: rely on PATH inside the bash cmd
		push_warning("[ServerManager] No known Python found — falling back to "
			+ "'python3' on PATH. Install deps with: pip install -r requirements.txt")

	print("[ServerManager] Ready — project root: %s | python: %s" % [
		_project_root, PYTHON_PATH])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop_server()
		get_tree().quit()


func _on_tree_exiting() -> void:
	stop_server()


func _resolve_project_root() -> void:
	## Compute the TrafIQ project root from Godot's res:// path.
	## res:// resolves to the visualizer directory; go up one level.
	var godot_dir: String = ProjectSettings.globalize_path("res://")
	# Remove trailing slash if present
	if godot_dir.ends_with("/"):
		godot_dir = godot_dir.substr(0, godot_dir.length() - 1)
	_project_root = godot_dir.get_base_dir()


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func start_server(type: ServerType, args: Dictionary = {}) -> bool:
	## Start a Python SUMO server. Stops any existing server first.
	## args: { "demo": bool, "speed": float, "port": int }
	if _is_starting:
		return false
	if type == ServerType.NONE:
		return false

	_is_starting = true

	# Stop existing server if running
	if is_running():
		stop_server()
		# Brief wait for port release
		await get_tree().create_timer(0.8).timeout

	# Never evict another application from a shared local port.
	active_port = _available_port(int(args.get("port", PORT)))
	last_error = ""
	if active_port < 0:
		_is_starting = false
		last_error = "No free local port available for traffic."
		server_error.emit(last_error)
		return false

	current_server = type
	_log_file_pos = 0

	# Clear old log file
	var f := FileAccess.open(log_file_path, FileAccess.WRITE)
	if f:
		f.store_string("[ServerManager] Starting %s server...\n" % get_server_type_name())
		f.close()

	# Build the script path
	var script_rel: String = SERVER_SCRIPTS.get(type, "")
	if script_rel.is_empty():
		_is_starting = false
		last_error = "Unknown server type"
		current_server = ServerType.NONE
		server_error.emit(last_error)
		return false
	var script_path: String = _project_root.path_join(script_rel)

	# Verify the script exists
	if not FileAccess.file_exists(script_path):
		_is_starting = false
		last_error = "Server script not found: %s" % script_path
		current_server = ServerType.NONE
		server_error.emit(last_error)
		return false

	# Build CLI arguments
	var speed: float = args.get("speed", DEFAULT_SIM_SPEED)
	var port: int = active_port
	var demo: bool = args.get("demo", false)

	var py_args: String = ""
	if demo:
		py_args += " --demo"
	if speed != 1.0:
		py_args += " --speed %s" % str(speed)
	if port != 8765:
		py_args += " --port %d" % port

	# Build bash command with exec (replaces bash with Python so PID is correct)
	# Shell-quote paths, including spaces and apostrophes.
	var bash_cmd: String = 'cd %s && exec %s -u %s%s > %s 2>&1' % [
		_shell_quote(_project_root), _shell_quote(PYTHON_PATH), _shell_quote(script_path), py_args, _shell_quote(log_file_path)
	]

	print("[ServerManager] Running: %s" % bash_cmd)

	# Spawn the process
	server_pid = OS.create_process("/bin/bash", ["-c", bash_cmd])

	if server_pid <= 0:
		_is_starting = false
		current_server = ServerType.NONE
		last_error = "Failed to start server (OS.create_process returned %d)" % server_pid
		server_error.emit(last_error)
		return false

	print("[ServerManager] Started %s server — PID %d" % [get_server_type_name(), server_pid])

	# A live process is not sufficient: wait until SUMO sends a state packet.
	var ready: bool = await _wait_for_traffic(float(args.get("startup_timeout", 45.0)))
	_is_starting = false
	if not ready:
		last_error = "Traffic server failed to produce simulation data. See the server log."
		stop_server()
		server_error.emit(last_error)
		return false
	_poll_timer.start()
	server_started.emit(get_server_type_name())
	if bool(args.get("dashboard", true)):
		_start_dashboard()
	return true


func stop_server() -> void:
	## Kill the running server process and reset state.
	_stop_dashboard()
	if server_pid > 0:
		if OS.is_process_running(server_pid):
			print("[ServerManager] Killing %s server — PID %d" % [
				get_server_type_name(), server_pid])
			OS.kill(server_pid)
		server_pid = -1
	current_server = ServerType.NONE
	_poll_timer.stop()
	server_stopped.emit()


func is_running() -> bool:
	## Returns true if the server process is alive.
	return server_pid > 0 and OS.is_process_running(server_pid)


func get_server_type() -> ServerType:
	return current_server


func get_server_type_name() -> String:
	return SERVER_NAMES.get(current_server, "Unknown")


func get_log_contents() -> String:
	## Read the entire log file (for when the log panel is first opened).
	if not FileAccess.file_exists(log_file_path):
		return ""
	var f := FileAccess.open(log_file_path, FileAccess.READ)
	if not f:
		return ""
	var contents: String = f.get_as_text()
	f.close()
	# Update read position to end so incremental reads start from here
	_log_file_pos = contents.length()
	return contents


# ═════════════════════════════════════════════════════════════════════════════
# POLLING
# ═════════════════════════════════════════════════════════════════════════════

func _poll_server() -> void:
	## Timer callback: check server health and read new log lines.
	# Health check
	if server_pid > 0 and not OS.is_process_running(server_pid):
		print("[ServerManager] Server process (PID %d) is no longer running" % server_pid)
		var prev_type: String = get_server_type_name()
		server_pid = -1
		current_server = ServerType.NONE
		_poll_timer.stop()
		# Read any final log output
		var final_log: String = _read_new_log_lines()
		if not final_log.is_empty():
			server_log_updated.emit(final_log)
		server_error.emit("%s server stopped unexpectedly" % prev_type)
		server_stopped.emit()
		return

	# Incremental log read
	var new_text: String = _read_new_log_lines()
	if not new_text.is_empty():
		server_log_updated.emit(new_text)


func _read_new_log_lines() -> String:
	## Read new content from the log file since last read.
	if not FileAccess.file_exists(log_file_path):
		return ""
	var f := FileAccess.open(log_file_path, FileAccess.READ)
	if not f:
		return ""
	var length: int = f.get_length()
	if length <= _log_file_pos:
		f.close()
		return ""
	f.seek(_log_file_pos)
	var new_text: String = f.get_buffer(length - _log_file_pos).get_string_from_utf8()
	_log_file_pos = length
	f.close()
	return new_text


# ═════════════════════════════════════════════════════════════════════════════
# DASHBOARD
# ═════════════════════════════════════════════════════════════════════════════

func open_dashboard() -> void:
	## The launcher may open the dashboard when resuming an existing corridor.
	if is_running() and current_server == ServerType.CORRIDOR:
		_start_dashboard()


func _start_dashboard() -> void:
	## Launch the Flask dashboard and open the Live Simulation tab in the browser.
	if _dashboard_pid > 0 and OS.is_process_running(_dashboard_pid):
		# Dashboard already running — just open the browser
		_open_dashboard_browser()
		return

	if not _port_is_available(DASHBOARD_PORT):
		push_warning("[ServerManager] Dashboard port is in use; traffic continues without opening a dashboard.")
		return
	var dash_script: String = _project_root.path_join(DASHBOARD_SCRIPT)
	if not FileAccess.file_exists(dash_script):
		push_warning("[ServerManager] Dashboard script not found: %s" % dash_script)
		return

	var dash_cmd: String = 'cd %s && exec env TRAFIQ_WS_PORT=%d %s -u %s > %s 2>&1' % [
		_shell_quote(_project_root), active_port, _shell_quote(PYTHON_PATH), _shell_quote(dash_script), _shell_quote(DASHBOARD_LOG)
	]

	_dashboard_pid = OS.create_process("/bin/bash", ["-c", dash_cmd])

	if _dashboard_pid <= 0:
		push_warning("[ServerManager] Failed to start dashboard")
		return

	print("[ServerManager] Dashboard started — PID %d (http://127.0.0.1:%d)" % [
		_dashboard_pid, DASHBOARD_PORT])

	# Brief delay for Flask to bind the port, then open browser
	await get_tree().create_timer(1.5).timeout
	_open_dashboard_browser()


## Chromium/Firefox browsers to try, in order, for the dashboard. Safari is
## deliberately excluded: the dashboard is a local HTTP server, and Safari's
## "HTTPS-Only" mode hard-refuses http:// URLs (WebKitErrorDomain:305). Opening
## in Chrome keeps the user's default browser untouched for everything else.
const DASHBOARD_BROWSERS: Array = [
	"Google Chrome", "Brave Browser", "Microsoft Edge", "Chromium", "Firefox",
]


func _open_dashboard_browser() -> void:
	## Open the dashboard Live Simulation tab in a browser that can load a local
	## HTTP page. 127.0.0.1 (not "localhost") pins IPv4, matching the Flask bind.
	var url: String = "http://127.0.0.1:%d?tab=live" % DASHBOARD_PORT
	for app_name in DASHBOARD_BROWSERS:
		# `open -a <app> <url>` exits 0 only if the app is installed + launched.
		if OS.execute("/usr/bin/open", ["-a", app_name, url]) == 0:
			print("[ServerManager] Opened dashboard in %s: %s" % [app_name, url])
			return
	# None installed — fall back to the default browser (may be Safari; if
	# HTTPS-Only is on it will refuse the http:// dashboard).
	push_warning("[ServerManager] No Chromium/Firefox browser found — opening the "
		+ "default browser. If that's Safari with HTTPS-Only on, the HTTP dashboard "
		+ "won't load; open %s in Chrome, or disable Safari's HTTPS-Only." % url)
	OS.shell_open(url)
	print("[ServerManager] Opened dashboard in default browser: %s" % url)


func _stop_dashboard() -> void:
	## Kill the dashboard process if running.
	if _dashboard_pid > 0:
		if OS.is_process_running(_dashboard_pid):
			print("[ServerManager] Killing dashboard — PID %d" % _dashboard_pid)
			OS.kill(_dashboard_pid)
		_dashboard_pid = -1


func get_websocket_url() -> String:
	return "ws://127.0.0.1:%d" % active_port

func _port_is_available(port: int) -> bool:
	var probe := TCPServer.new()
	var available: bool = probe.listen(port, "127.0.0.1") == OK
	probe.stop()
	return available

func _available_port(preferred: int) -> int:
	for port in range(preferred, mini(preferred + 32, 65536)):
		if _port_is_available(port):
			return port
	return -1

func _wait_for_traffic(timeout: float) -> bool:
	var probe := WebSocketClient.create_traffic_socket()
	var deadline: int = Time.get_ticks_msec() + int(timeout * 1000)
	var retry_at: int = 0
	while Time.get_ticks_msec() < deadline and is_running():
		probe.poll()
		if probe.get_ready_state() == WebSocketPeer.STATE_CLOSED and Time.get_ticks_msec() >= retry_at:
			probe = WebSocketClient.create_traffic_socket()
			probe.connect_to_url(get_websocket_url())
			retry_at = Time.get_ticks_msec() + 500
		elif probe.get_ready_state() == WebSocketPeer.STATE_OPEN:
			while probe.get_available_packet_count() > 0:
				var packet = JSON.parse_string(probe.get_packet().get_string_from_utf8())
				if packet is Dictionary and packet.get("type") in ["state_update", "vehicle_update"]:
					probe.close()
					print("[ServerManager] Live traffic ready at ", get_websocket_url())
					return true
		await get_tree().create_timer(0.1).timeout
	probe.close()
	return false

func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\"'\"'") + "'"

func ensure_traffic(type: ServerType, client: Node, ui: Control) -> void:
	# Direct scene play (F6) needs the same startup as the launcher (F5).
	# Offline previews and explicitly configured external servers remain opt-in.
	if not client.auto_connect or not client.auto_start_server or client.server_url not in ["ws://localhost:8765", "ws://127.0.0.1:8765", get_websocket_url()]:
		return
	client.suspend_connection()
	ui.set_traffic_status("STARTING LIVE TRAFFIC…")
	var ready: bool = is_running() and current_server == type
	if not ready:
		ready = await start_server(type)
	if not is_instance_valid(client) or not is_instance_valid(ui):
		return
	if ready:
		client.connect_to_server(get_websocket_url())
	else:
		ui.show_simulation_error(last_error)
