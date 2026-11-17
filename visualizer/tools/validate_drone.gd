extends SceneTree
## Headless integration checks for drone flight, collision and camera handover.
## godot --headless --path visualizer --script res://tools/validate_drone.gd

const Drone = preload("res://scripts/DroneController.gd")
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	await _check_flight()
	for corridor in [false, true]:
		await _check_scene(corridor)
	print("Drone validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)

func _check_flight() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var drone: Node3D = Drone.new()
	world.add_child(drone)
	_check_airframe_clearance(drone)
	drone.activate()
	drone.set_process(false)
	drone.set_physics_process(false)
	drone.set_cursor_released(false)
	drone.set("_focus_lost", false)
	drone.set("_yaw", 0.0)
	var caps: Array[float] = [4.0,30.0,65.0]
	for preset in range(3):
		drone.set_speed_mode(preset)
		drone.set("_velocity", Vector3.ZERO)
		for i in range(600):
			drone.call("_integrate_velocity", 1.0 / 60.0, Vector3.FORWARD, false, false)
		var forward: Vector3 = drone.get("_velocity")
		_check(forward.z < -caps[preset] * 0.95 and absf(forward.x) < 0.01,
			"Drone forward input does not follow its heading or selected speed")
		_check(forward.length() <= caps[preset] + 0.05, "Flight preset exceeds its speed cap")
		drone.set("_velocity", Vector3.ZERO)
		for i in range(600):
			drone.call("_integrate_velocity", 1.0 / 60.0, Vector3(1, 0, -1), false, false)
		var diagonal: Vector3 = drone.get("_velocity")
		_check(diagonal.length() <= caps[preset] + 0.05, "Diagonal movement increases flight speed")
		_check(diagonal.x > 0.0 and diagonal.z < 0.0, "Diagonal input loses an axis")
	drone.set("_velocity", Vector3.ZERO)
	for i in range(600):
		drone.call("_integrate_velocity", 1.0 / 60.0, Vector3.FORWARD, true, false)
	_check(Vector3(drone.get("_velocity")).length() > caps[2] * 1.2, "Shift boost does not increase speed")
	drone.set("_yaw", PI * 0.5)
	drone.set("_velocity", Vector3.ZERO)
	for i in range(120):
		drone.call("_integrate_velocity", 1.0 / 60.0, Vector3.FORWARD, false, false)
	var turned: Vector3 = drone.get("_velocity")
	_check(turned.x < -1.0 and absf(turned.z) < 0.01, "Forward flight ignores yaw")
	# Compare the same deceleration interval at two update rates.
	var stopped: Array[Vector3] = []
	for fps in [30, 120]:
		drone.set("_velocity", Vector3(14, 4, -8))
		for i in range(fps * 3):
			drone.call("_integrate_velocity", 1.0 / fps, Vector3.ZERO, false, false)
		stopped.append(drone.get("_velocity"))
	_check(stopped[0].distance_to(stopped[1]) < 0.05, "Hover braking depends on update rate")
	_check(stopped[0].length() < 0.1, "Released movement input leaves the drone drifting")
	drone.set("_velocity", Vector3(20, 3, -8))
	drone.brake()
	_check(Vector3(drone.get("_velocity")).length() < 0.01, "Emergency brake leaves flight velocity")
	var before_zoom: float = drone.get("_zoom_target")
	drone.adjust_zoom(1.0)
	_check(float(drone.get("_zoom_target")) < before_zoom, "Positive zoom input does not zoom in")
	drone.adjust_zoom(1000.0)
	_check(float(drone.get("_zoom_target")) >= 15.0, "Zoom can collapse to an unusable field of view")
	drone.adjust_zoom(-2000.0)
	_check(float(drone.get("_zoom_target")) <= 110.0, "Zoom can exceed a usable field of view")
	var old_view: String = drone.telemetry().view
	drone.toggle_view()
	_check(drone.telemetry().view != old_view, "Camera view toggle has no effect")
	drone.toggle_view()
	_check(drone.telemetry().view == old_view, "Camera view does not toggle back")
	_check(drone.get("_camera_rig").top_level, "Camera rig inherits drone translation and defeats smoothing")
	_check(drone.get("_spring_arm") is SpringArm3D, "Chase camera lacks obstruction handling")

	# An actual thin wall and ceiling exercise swept body motion at boost speed.
	var wall := _solid_box(world, Vector3(0, 5, -5), Vector3(20, 10, 0.2))
	var ceiling := _solid_box(world, Vector3(0, 8, 0), Vector3(20, 0.2, 20))
	drone.global_position = Vector3(0, 5, 0)
	drone.set("_yaw", 0.0)
	drone.brake()
	await physics_frame
	for i in range(90):
		await physics_frame
		drone.call("_step_flight", 1.0 / 60.0, Vector3.FORWARD, true, false)
	_check(drone.global_position.z > -4.8, "Boosted flight tunnels through a thin wall")
	_check(drone.global_position.z < -3.0, "Collision check never approached the wall")
	drone.global_position = Vector3(0, 5, 0)
	drone.brake()
	for i in range(90):
		await physics_frame
		drone.call("_step_flight", 1.0 / 60.0, Vector3.UP, true, false)
	_check(drone.global_position.y < 7.8, "Drone ascends through a ceiling")
	_check(drone.global_position.y > 6.0, "Ceiling check never reached the roof")
	# The chase camera must retract before a wall and recover its full distance
	# when the obstruction disappears, independently of body flight processing.
	var camera_wall := _solid_box(world, Vector3(0, 5, 2), Vector3(20, 10, 0.2))
	drone.global_position = Vector3(0, 5, 0)
	drone.set("_pitch", 0.0)
	drone.call("_snap_camera")
	for i in range(8):
		await physics_frame
	var near_camera: Vector3 = drone.flight_camera().global_position
	_check(near_camera.z < 1.9 and near_camera.z > 0.1, "Chase camera clips through a wall behind the drone")
	camera_wall.queue_free()
	await process_frame
	for i in range(8):
		await physics_frame
	_check(drone.flight_camera().global_position.z > 3.5, "Chase camera does not extend again after clearing an obstacle")
	var paused_at: Vector3 = drone.global_position
	drone.set_cursor_released(true)
	for i in range(10):
		drone.call("_step_flight", 1.0 / 60.0, Vector3.RIGHT, true, false)
	_check(drone.global_position.is_equal_approx(paused_at), "Drone moves while the cursor is released")
	_check(drone.telemetry().paused, "Cursor release is not represented in flight status")
	drone.set_cursor_released(false)
	drone.set("_focus_lost", true)
	drone.call("_step_flight", 1.0 / 60.0, Vector3.RIGHT, true, false)
	_check(drone.global_position.is_equal_approx(paused_at), "Drone moves after window focus loss")
	drone.set("_focus_lost", false)
	wall.queue_free()
	ceiling.queue_free()
	await physics_frame
	var resumed_at := Vector3(2, 16, 12)
	drone.global_position = resumed_at
	drone.deactivate()
	drone.activate()
	drone.set_process(false)
	drone.set_physics_process(false)
	_check(drone.global_position.distance_to(resumed_at) < 0.01, "Re-entering drone mode resets its position")
	drone.return_home()
	_check(drone.global_position.distance_to(drone.telemetry().home) < 0.01, "Return home misses its safe start position")
	_check(Vector3(drone.get("_velocity")).length() < 0.01, "Return home retains momentum")
	drone.deactivate()
	world.queue_free()
	await process_frame
	print("DRONE FLIGHT PASS")

func _solid_box(parent: Node3D, at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	body.position = at
	return body

func _check_airframe_clearance(drone: Node3D) -> void:
	# The new visible airframe must fit the flight collision envelope in motion.
	var model: Node3D = drone.get("_airframe")
	var tilt: Node3D = drone.get("_tilt_pivot")
	for spin in [0.0, 0.7, 1.4, 2.1]:
		tilt.rotation = Vector3(0.2, 0, 0.28)
		tilt.position.y = 0.025
		model.animate_flight(spin, -0.5, 0.2, 0.28, 0.0, 0.0)
		_check_mesh_clearance(model, drone)
	tilt.rotation = Vector3.ZERO
	tilt.position = Vector3.ZERO
	model.animate_flight(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

func _check_mesh_clearance(node: Node, drone: Node3D) -> void:
	# Blur uses a transparent quad with invisible corners; the blades define its radius.
	if node is MeshInstance3D and node.name != "RotorBlur":
		var transform: Transform3D = drone.global_transform.affine_inverse() * node.global_transform
		for surface in range(node.mesh.get_surface_count()):
			var vertices: PackedVector3Array = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				_check((transform * vertex).length() <= Drone.BODY_RADIUS,
					"Visible drone geometry exceeds its collision envelope: " + str(node.name))
	for child in node.get_children():
		_check_mesh_clearance(child, drone)

func _check_scene(corridor: bool) -> void:
	var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	scene.set_process(false)
	await process_frame
	var overview: Camera3D = scene.get_node("IsometricCamera")
	var original: Transform3D = overview.global_transform
	var drone: Node3D = scene.get_node("DroneController")
	var dashboard: CanvasLayer = scene.get_node("UI")
	var dashboard_visible: bool = dashboard.visible
	_check(drone is CharacterBody3D, "Scene drone is not a collision-aware character body")
	scene.call("_unhandled_input", _key(KEY_H))
	drone.set_process(false)
	drone.set_physics_process(false)
	_check(bool(scene.get("_drone_mode_active")), "Scene does not enter drone mode")
	_check(root.get_camera_3d() == drone.flight_camera(), "Flight camera does not own the viewport")
	_check(bool(drone.telemetry().corridor) == corridor, "Drone navigation map uses the wrong scene layout")
	_check(not dashboard.visible, "Captured flight leaves the simulation dashboard over the drone controls")
	await _check_scene_input(scene, drone, dashboard, dashboard_visible)
	# Weather follows the actual active flight camera, including higher altitudes.
	var weather: Node = scene.get_node("WeatherManager")
	weather.set_process(false)
	weather.get("_current_mods").rain_intensity = 1.0
	weather.call("_update_rain", 0.0)
	var rain: Node3D = weather.get("_rain_particles")
	var camera_at: Vector3 = drone.flight_camera().global_position
	_check(Vector2(rain.global_position.x, rain.global_position.z).distance_to(Vector2(camera_at.x, camera_at.z)) < 0.01,
		"Rain emitter stays at the overview camera during flight")
	_check(rain.global_position.y > camera_at.y, "Rain emitter sits below the flying camera")
	scene.call("_unhandled_input", _key(KEY_H))
	_check(not bool(scene.get("_drone_mode_active")), "Scene does not exit drone mode")
	_check(root.get_camera_3d() == overview, "Exiting flight does not restore the overview camera")
	_check(overview.global_transform.is_equal_approx(original), "Flight changes the saved overview framing")
	_check(not drone.active, "Drone remains active after the scene exits flight mode")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Exiting flight leaves the mouse captured")
	_check(dashboard.visible == dashboard_visible, "Exiting flight does not restore the dashboard's visibility")
	print("DRONE SCENE PASS: ", "corridor" if corridor else "single")
	scene.queue_free()
	await process_frame

func _key(code: Key, pressed: bool = true) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	return event

func _check_scene_input(scene: Node3D, drone: Node3D, dashboard: CanvasLayer, dashboard_visible: bool) -> void:
	var modes: Array[String] = ["INSPECT", "CRUISE", "FAST"]
	var keys: Array[Key] = [KEY_1, KEY_2, KEY_3]
	for i in range(3):
		drone.call("_input", _key(keys[i]))
		_check(drone.telemetry().mode == modes[i], "Number-key speed selection does not match its HUD mode")
	var initial_view: String = drone.telemetry().view
	drone.call("_input", _key(KEY_F))
	_check(drone.telemetry().view != initial_view, "F does not change the drone camera view")
	var changed_view: String = drone.telemetry().view
	drone.call("_input", _key(KEY_F, false))
	_check(drone.telemetry().view == changed_view, "Releasing F toggles the camera a second time")
	_check(root.get_camera_3d() == drone.flight_camera(), "F gives camera ownership back to the overview")
	drone.call("_input", _key(KEY_F))
	var zoom_before: float = drone.get("_zoom_target")
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	drone.call("_input", wheel)
	_check(float(drone.get("_zoom_target")) < zoom_before, "Mouse wheel up does not zoom the drone camera")
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	drone.call("_input", wheel)
	_check(is_equal_approx(float(drone.get("_zoom_target")), zoom_before), "Mouse wheel down does not reverse zoom")
	var yaw_before: float = drone.get("_yaw")
	var pitch_before: float = drone.get("_pitch")
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(40, -20)
	drone.call("_input", motion)
	_check(not is_equal_approx(float(drone.get("_yaw")), yaw_before) and float(drone.get("_pitch")) > pitch_before,
		"Captured mouse movement does not steer yaw and camera pitch")
	drone.call("_input", _key(KEY_TAB))
	_check(drone.telemetry().paused and drone.active, "Tab does not suspend flight while keeping drone mode active")
	_check(dashboard.visible == dashboard_visible, "Tab does not restore the simulation dashboard")
	yaw_before = drone.get("_yaw")
	drone.call("_input", motion)
	_check(is_equal_approx(float(drone.get("_yaw")), yaw_before), "Released cursor still steers the drone")
	# Focus a real simulation control before recapturing. Flight must release
	# that focus so Space cannot also click a previously selected HUD button.
	var button: Button
	for candidate in scene.find_children("*", "Button", true, false):
		if candidate.is_visible_in_tree() and not candidate.disabled and candidate.focus_mode != Control.FOCUS_NONE:
			button = candidate
			break
	_check(button != null, "Could not find a visible simulation button for flight focus regression")
	var clicks: Dictionary = {"count": 0}
	if button:
		button.grab_focus()
		button.pressed.connect(func(): clicks.count += 1)
		_check(root.gui_get_focus_owner() == button, "Simulation control could not receive focus")
	drone.call("_input", _key(KEY_TAB))
	_check(not drone.telemetry().paused and not dashboard.visible, "Tab does not recapture flight and hide the dashboard")
	_check(root.gui_get_focus_owner() == null, "Recapturing flight leaves a simulation button focused")
	Input.parse_input_event(_key(KEY_SPACE))
	Input.parse_input_event(_key(KEY_SPACE, false))
	await process_frame
	_check(int(clicks.count) == 0, "A flight Space key press/release activates a simulation button")
	drone.set("_velocity", Vector3(12, 0, 0))
	drone.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(drone.telemetry().paused and Vector3(drone.get("_velocity")).is_zero_approx(),
		"Application focus loss does not suspend and brake the drone")
	drone.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(drone.telemetry().paused, "Returning application focus silently resumes flight")
	drone.call("_input", _key(KEY_TAB))
	_check(not drone.telemetry().paused, "Tab cannot resume after application focus returns")
	drone.global_position += Vector3(5, 2, -4)
	drone.call("_input", _key(KEY_R))
	_check(drone.global_position.distance_to(drone.telemetry().home) < 0.01, "R does not return the drone home")
	_check(root.get_camera_3d() == drone.flight_camera(), "Drone shortcuts relinquish the active flight camera")
