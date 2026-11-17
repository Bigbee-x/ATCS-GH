extends SceneTree
## Actual SUMO replay, with the application interpolation and lighting enabled.
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var corridor: bool = args[0] == "corridor"
	var packets: Array = JSON.parse_string(FileAccess.get_file_as_string("/private/tmp/crossing-replay-%s.json" % args[0]))
	var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	_disable_input(scene)
	scene.set_process(false)
	root.gui_disable_input = true
	root.size = Vector2i(1440, 1000)
	scene.get_node("UI").hide()
	var hour: float = float(args[3]) if args.size() > 3 else 14.5
	scene.get_node("TimeOfDayManager").set_time(hour)
	var camera: Camera3D = scene.get_node("IsometricCamera")
	camera.position = Vector3(9, 18, 19)
	camera.look_at(Vector3(0, 0, 1))
	camera.fov = 46
	if args.size() > 4 and args[4] == "lamp":
		var lamp: Node3D = scene.intersection._street_lights[0]
		camera.global_position = lamp.to_global(Vector3(4, 5.5, 6.5))
		camera.look_at(lamp.to_global(Vector3(0, 3, 0.8)))
		camera.fov = 48
	var vm: Node = scene.get_node("VehicleManager")
	var pm: Node = scene.get_node("PedestrianManager")
	vm.set_process(false)
	pm.set_process(false)
	var target: int = int(args[2])
	for i in range(maxi(0, target-6), target+2):
		var packet: Dictionary = packets[i]
		vm.update_vehicles(packet)
		pm.update_crossing_pedestrians(packet.pedestrians, packet.sim_time)
		scene.signal_playback.feed(packet)
	vm._clock.render_t = target + 0.4
	pm._snap_clock.render_t = target + 0.4
	vm._process(0)
	pm._process(0)
	scene.signal_playback._process(0)
	# Allow lighting and shaders to settle, with traffic frozen at replay time.
	for i in range(100):
		vm._clock.render_t = target + 0.4
		pm._snap_clock.render_t = target + 0.4
		vm._process(0.04)
		pm._process(0.04)
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(args[1])
	print("CROSSING CAPTURE ",args[1]," vehicles=",vm._active.size()," peds=",pm._crossing_peds.size())
	scene.queue_free()
	await process_frame
	quit()
func _disable_input(node: Node) -> void:
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	for child in node.get_children(): _disable_input(child)
