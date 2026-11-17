extends SceneTree
## Render launcher at two sizes without starting traffic or opening a browser.
func _initialize() -> void: call_deferred("capture")
func capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or DisplayServer.get_name() == "headless":
		push_error("Use a display and pass an existing absolute output directory")
		quit(1)
		return
	root.content_scale_size = Vector2i.ZERO
	var scene: Control = load("res://scenes/LauncherMenu.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for spec in [[1280,720,"launcher"],[720,1000,"launcher-compact"]]:
		root.size = Vector2i(spec[0],spec[1])
		for frame in range(8): await process_frame
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image().save_png(args[0].path_join(spec[2]+".png"))
		if result != OK:
			quit(1)
			return
	root.size = Vector2i(1280,850)
	scene._on_server_error("Preview: traffic did not start. Check the session log, then retry.")
	scene._log_text.text = "Preview only — no traffic server was started.\nA failed launch keeps the lobby open so you can inspect the log and retry."
	for frame in range(8): await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(args[0].path_join("launcher-error.png"))
	print("Launcher preview saved to ",args[0])
	quit(0 if result == OK else 1)
