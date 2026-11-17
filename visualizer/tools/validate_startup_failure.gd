extends SceneTree
## A failed backend must leave the launch menu and its error visible.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var manager: Node = root.get_node("ServerManager")
	manager.PYTHON_PATH = "/usr/bin/false"
	var launcher: Control = load("res://scenes/LauncherMenu.tscn").instantiate()
	root.add_child(launcher)
	current_scene = launcher
	# The launcher is corridor-only now; its single entry is _launch_corridor().
	await launcher._launch_corridor()
	var passed: bool = current_scene == launcher and not launcher._launching and not manager.is_running()
	# _error is what the status card shows once launching ends.
	passed = passed and not manager.last_error.is_empty() and not launcher._error.is_empty() and launcher._log_panel.visible
	print("STARTUP FAILURE ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
