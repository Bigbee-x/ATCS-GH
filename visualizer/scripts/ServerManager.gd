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
const PYTHON_PATH := "/Users/osborn/.pyenv/versions/3.11.7/bin/python3"
const LOG_FILE := "/tmp/atcs_gh_server.log"
const DASHBOARD_LOG := "/tmp/atcs_gh_dashboard.log"
const POLL_INTERVAL := 1.0        # Seconds between health checks / log reads
const PORT := 8765
const DASHBOARD_PORT := 5050
const DASHBOARD_SCRIPT := "dashboard/app.py"

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
var _poll_timer: Timer

# ── Computed paths ──────────────────────────────────────────────────────────
var _project_root: String = ""     # e.g. /Users/osborn/BIG PROJECT/ATCS-GH


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

	# Verify Python is accessible
	if not FileAccess.file_exists(PYTHON_PATH):
		push_warning("[ServerManager] Python not found at %s" % PYTHON_PATH)

	print("[ServerManager] Ready — project root: %s" % _project_root)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop_server()
		get_tree().quit()


func _on_tree_exiting() -> void:
	stop_server()


func _resolve_project_root() -> void:
	## Compute the ATCS-GH project root from Godot's res:// path.
	## res:// resolves to .../ATCS-GH/visualizer/  → go up one level.
	var godot_dir: String = ProjectSettings.globalize_path("res://")
	# Remove trailing slash if present
	if godot_dir.ends_with("/"):
		godot_dir = godot_dir.substr(0, godot_dir.length() - 1)
	_project_root = godot_dir.get_base_dir()


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func start_server(type: ServerType, args: Dictionary = {}) -> void:
	## Start a Python SUMO server. Stops any existing server first.
	## args: { "demo": bool, "speed": float, "port": int }
	if _is_starting:
		return
	if type == ServerType.NONE:
		return

	_is_starting = true

	# Stop existing server if running
	if is_running():
		stop_server()
		# Brief wait for port release
		await get_tree().create_timer(0.8).timeout

	# Kill any ORPHAN processes on our ports (e.g. leftovers from a prior
	# Godot session that exited without cleanup). Without this, the new
	# server crashes immediately with EADDRINUSE and the UI loops on reconnect.
	var orphaned: bool = _kill_orphans_on_ports([PORT, DASHBOARD_PORT])
	if orphaned:
		# Give the OS a moment to release the sockets
		await get_tree().create_timer(0.5).timeout

	current_server = type
	_log_file_pos = 0

	# Clear old log file
	var f := FileAccess.open(LOG_FILE, FileAccess.WRITE)
	if f:
		f.store_string("[ServerManager] Starting %s server...\n" % get_server_type_name())
		f.close()

	# Build the script path
	var script_rel: String = SERVER_SCRIPTS.get(type, "")
	if script_rel.is_empty():
		_is_starting = false
		server_error.emit("Unknown server type")
		return
	var script_path: String = _project_root.path_join(script_rel)

	# Verify the script exists
	if not FileAccess.file_exists(script_path):
		_is_starting = false
		server_error.emit("Server script not found: %s" % script_path)
		return

	# Build CLI arguments
	var speed: float = args.get("speed", 1.0)
	var port: int = args.get("port", PORT)
	var demo: bool = args.get("demo", false)

	var py_args: String = ""
	if demo:
		py_args += " --demo"
	if speed != 1.0:
		py_args += " --speed %s" % str(speed)
	if port != 8765:
		py_args += " --port %d" % port

	# Build bash command with exec (replaces bash with Python so PID is correct)
	# Paths are double-quoted to handle spaces in "BIG PROJECT"
	var bash_cmd: String = 'cd "%s" && exec "%s" "%s"%s > "%s" 2>&1' % [
		_project_root, PYTHON_PATH, script_path, py_args, LOG_FILE
	]

	print("[ServerManager] Running: %s" % bash_cmd)

	# Spawn the process
	server_pid = OS.create_process("/bin/bash", ["-c", bash_cmd])

	if server_pid <= 0:
		_is_starting = false
		current_server = ServerType.NONE
		server_error.emit("Failed to start server (OS.create_process returned %d)" % server_pid)
		return

	print("[ServerManager] Started %s server — PID %d" % [get_server_type_name(), server_pid])

	# Launch the dashboard and open browser
	_start_dashboard()

	# Start the poll timer
	_poll_timer.start()

	_is_starting = false
	server_started.emit(get_server_type_name())


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
	if not FileAccess.file_exists(LOG_FILE):
		return ""
	var f := FileAccess.open(LOG_FILE, FileAccess.READ)
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
	if not FileAccess.file_exists(LOG_FILE):
		return ""
	var f := FileAccess.open(LOG_FILE, FileAccess.READ)
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

func _start_dashboard() -> void:
	## Launch the Flask dashboard and open the Live Simulation tab in the browser.
	if _dashboard_pid > 0 and OS.is_process_running(_dashboard_pid):
		# Dashboard already running — just open the browser
		_open_dashboard_browser()
		return

	var dash_script: String = _project_root.path_join(DASHBOARD_SCRIPT)
	if not FileAccess.file_exists(dash_script):
		push_warning("[ServerManager] Dashboard script not found: %s" % dash_script)
		return

	var dash_cmd: String = 'cd "%s" && exec "%s" "%s" > "%s" 2>&1' % [
		_project_root, PYTHON_PATH, dash_script, DASHBOARD_LOG
	]

	_dashboard_pid = OS.create_process("/bin/bash", ["-c", dash_cmd])

	if _dashboard_pid <= 0:
		push_warning("[ServerManager] Failed to start dashboard")
		return

	print("[ServerManager] Dashboard started — PID %d (http://localhost:%d)" % [
		_dashboard_pid, DASHBOARD_PORT])

	# Brief delay for Flask to bind the port, then open browser
	await get_tree().create_timer(1.5).timeout
	_open_dashboard_browser()


func _open_dashboard_browser() -> void:
	## Open the dashboard Live Simulation tab in the default browser.
	var url: String = "http://localhost:%d?tab=live" % DASHBOARD_PORT
	OS.shell_open(url)
	print("[ServerManager] Opened dashboard in browser: %s" % url)


func _stop_dashboard() -> void:
	## Kill the dashboard process if running.
	if _dashboard_pid > 0:
		if OS.is_process_running(_dashboard_pid):
			print("[ServerManager] Killing dashboard — PID %d" % _dashboard_pid)
			OS.kill(_dashboard_pid)
		_dashboard_pid = -1


# ═════════════════════════════════════════════════════════════════════════════
# ORPHAN PROCESS CLEANUP
# ═════════════════════════════════════════════════════════════════════════════

func _kill_orphans_on_ports(ports: Array) -> bool:
	## Find and kill any process listening on the given ports.
	## Handles the common case where a previous Godot session left behind a
	## zombie Python server, causing the next launch to fail with EADDRINUSE.
	## Returns true if at least one orphan was killed.
	var killed_any: bool = false
	for p in ports:
		var pids: Array = _find_pids_on_port(int(p))
		for pid in pids:
			# Don't kill processes we already track (server_pid, _dashboard_pid)
			if int(pid) == server_pid or int(pid) == _dashboard_pid:
				continue
			print("[ServerManager] Killing orphan process PID %d on port %d" % [pid, p])
			var output: Array = []
			OS.execute("/bin/kill", ["-9", str(pid)], output, true)
			killed_any = true
	return killed_any


func _find_pids_on_port(port: int) -> Array:
	## Use `lsof -ti :<port>` to list PIDs owning a TCP port.
	## Returns empty array if nothing is listening or lsof is unavailable.
	var output: Array = []
	var exit_code: int = OS.execute("/usr/sbin/lsof", ["-ti", ":%d" % port], output, true)
	if exit_code != 0 or output.is_empty():
		return []
	var raw: String = str(output[0]).strip_edges()
	if raw.is_empty():
		return []
	var pids: Array = []
	for line in raw.split("\n"):
		var s: String = line.strip_edges()
		if s.is_valid_int():
			pids.append(int(s))
	return pids
