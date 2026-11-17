extends SceneTree
## Replay a recorded packet for visual inspection. No traffic server is started.
## -- /absolute/output_directory /absolute/packet.json
func _initialize() -> void: call_deferred("capture")
func capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or DisplayServer.get_name() == "headless":
		quit(1)
		return
	var packet: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	var scene: Node3D = load("res://scenes/CorridorMain.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	scene.set_process(false)
	scene.set_process_unhandled_input(false)
	root.size = Vector2i(1440,900)
	await process_frame
	scene._on_state_updated(packet)
	var hud: Control = scene.get_node("UI/UIRoot")
	hud.set_process(false)
	hud._lbl_connection.text = "Recorded snapshot"
	var camera: Camera3D = scene.get_node("IsometricCamera")
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.position = Vector3(-100,100,135)
	camera.look_at(Vector3(0,0,310))
	scene.get_node("TimeOfDayManager").set_time(21.5)
	for page in ["","Traffic"]:
		if not page.is_empty(): hud.toggle_page(page)
		for frame in range(30): await process_frame
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image().save_png(args[0].path_join("preview-%s.png" % ("overview" if page.is_empty() else "traffic")))
		if result != OK:
			quit(1)
			return
	print("HUD recorded-snapshot previews saved")
	quit()
