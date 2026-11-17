extends SceneTree
## Contract checks: corridor-only dispatch, readiness, duplicate launch, failure/retry,
## resume and stop. A local fake replaces process ownership; no SUMO is started.
class FakeServer extends Node:
	signal server_started(server_type_name: String)
	signal server_stopped()
	signal server_log_updated(new_text: String)
	signal server_error(message: String)
	var running := false
	var type := 0
	var starts: Array = []
	var dashboard_requests := 0
	var succeed := true
	func is_running() -> bool: return running
	func get_server_type() -> int: return type
	func get_log_contents() -> String: return "validation log"
	func open_dashboard() -> void: dashboard_requests += 1
	func stop_server() -> void:
		running = false
		type = 0
		server_stopped.emit()
	func start_server(requested: int, options: Dictionary) -> bool:
		starts.append({"type":requested,"options":options})
		await get_tree().process_frame
		if not succeed:
			server_error.emit("Test startup failure")
			return false
		running = true
		type = requested
		server_started.emit("N6 Corridor")
		return true

class TestLauncher extends "res://scripts/LauncherMenu.gd":
	var entered := false
	func _enter_corridor() -> void: entered = true

var failures := 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var original := root.get_node("ServerManager")
	root.remove_child(original)
	original.free()
	var server := FakeServer.new()
	server.name = "ServerManager"
	root.add_child(server)
	var menu := TestLauncher.new()
	root.add_child(menu)
	await process_frame
	await process_frame
	check(menu.SCENE_CORRIDOR == "res://scenes/CorridorMain.tscn", "Launcher must target corridor")
	check(not menu._launch_btn.disabled, "Idle launcher disabled")
	check(not menu._stop_btn.visible, "Idle session offers stop")
	menu._dashboard.button_pressed = false
	menu._launch_btn.pressed.emit()
	menu._launch_btn.pressed.emit()
	check(menu._launch_btn.disabled and menu._dashboard.disabled, "Startup controls not locked")
	check(not menu.entered, "Scene opened before traffic readiness")
	await process_frame
	await process_frame
	check(menu.entered, "Ready server did not open scene")
	check(server.starts.size() == 1 and server.starts[0].type == 2, "Launch must dispatch exactly once to corridor server")
	check(server.starts[0].options.dashboard == false, "Dashboard opt-out ignored")
	menu.entered = false
	menu._dashboard.button_pressed = true
	menu._launch_btn.pressed.emit()
	check(menu.entered and server.starts.size() == 1, "Resume restarted running traffic")
	check(server.dashboard_requests == 1, "Resume did not honour dashboard option")
	menu._on_stop_pressed()
	check(not server.running and not menu._stop_btn.visible, "Stop failed to return to idle")
	server.succeed = false
	menu.entered = false
	menu._launch_btn.pressed.emit()
	await process_frame
	await process_frame
	check(not menu.entered and not menu._launch_btn.disabled, "Failure entered scene or blocked retry")
	check(menu._log_panel.visible and menu._status_label.text == "Unable to launch", "Failure/log not visible")
	server.server_stopped.emit()
	check(menu._status_label.text == "Unable to launch", "Stop event erased startup failure")
	server.succeed = true
	menu._launch_btn.pressed.emit()
	await process_frame
	await process_frame
	check(menu.entered and menu._error.is_empty(), "Retry failed to recover")
	menu._on_stop_pressed()
	menu._log_panel.hide()
	root.content_scale_size = Vector2i.ZERO
	for dimensions in [Vector2i(1280,720),Vector2i(960,720),Vector2i(720,900)]:
		root.size = dimensions
		await process_frame
		await process_frame
		check(menu._columns.columns == (1 if dimensions.x < 920 else 2), "Responsive column count wrong")
		check(menu._launch_btn.get_global_rect().end.x <= dimensions.x, "Launch action overflows viewport")
		var diagram: Control = menu.find_child("RouteDiagram",true,false)
		check(diagram.get_global_rect().end.x <= dimensions.x, "Route schematic overflows viewport")
		check(menu.get_node("PageScroll").get_h_scroll_bar().max_value <= dimensions.x+1, "Horizontal overflow")
	print("Corridor launcher validation: ", failures, " failures")
	menu.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
