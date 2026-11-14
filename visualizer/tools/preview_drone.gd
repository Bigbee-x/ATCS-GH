extends SceneTree
## Offline flight through the real scene. -- single|corridor /absolute/output.png [frames-dir]
func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or DisplayServer.get_name() == "headless":
		quit(1)
		return
	var corridor: bool = args[0] == "corridor"
	var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	root.size = Vector2i(1440, 900)
	root.gui_disable_input = true
	_disable_input(scene)
	scene.set_process(false)
	scene.get_node("TimeOfDayManager").set_time(14.0)
	var drone: CharacterBody3D = scene.get_node("DroneController")
	drone.activate()
	drone.set_process_input(false)
	drone.set_physics_process(false)
	drone.set_speed_mode(0)
	drone.set("_pitch", -0.52)
	drone.call("_snap_camera")
	for i in range(120):
		await physics_frame
	# Focus-safe captures use direct flight intent, not physical keyboard state.
	drone.set_cursor_released(false)
	for i in range(120):
		drone.call("_step_flight", 1.0 / 60.0, Vector3(0, 0, -1))
		await physics_frame
	drone.brake()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(args[1])
	if args.size() > 2:
		root.size = Vector2i(960, 600)
		DirAccess.make_dir_recursive_absolute(args[2])
		for i in range(360):
			if i == 120:
				drone.toggle_view()
			if i == 240:
				drone.adjust_zoom(3)
			var intent := Vector3(0.25, 0, -0.65) if i < 240 else Vector3.ZERO
			drone.call("_step_flight", 1.0 / 60.0, intent)
			await physics_frame
			if i % 4 == 0:
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(args[2].path_join("frame_%03d.png" % (i / 4)))
	print("DRONE CAPTURE ", args[1], " ", drone.telemetry())
	drone.deactivate()
	scene.queue_free()
	await process_frame
	quit()

func _disable_input(node: Node) -> void:
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_unhandled_key_input(false)
	for child in node.get_children():
		_disable_input(child)
