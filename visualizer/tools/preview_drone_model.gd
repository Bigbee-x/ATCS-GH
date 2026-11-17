extends SceneTree
## Render the actual flight-controller airframe at close range. -- /absolute/output.png [rear]
func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or DisplayServer.get_name() == "headless":
		quit(1)
		return
	root.size = Vector2i(1440, 960)
	root.gui_disable_input = true
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("18242c")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("b0c5cf")
	settings.ambient_light_energy = 0.4
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	settings.ssao_enabled = true
	settings.ssao_radius = 0.12
	settings.ssao_intensity = 1.7
	settings.ssao_detail = 1.0
	environment.environment = settings
	world.add_child(environment)
	var key := DirectionalLight3D.new()
	world.add_child(key)
	key.rotation_degrees = Vector3(-48, -32, 0)
	key.light_color = Color("fff0d9")
	key.light_energy = 1.0
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 10
	key.light_angular_distance = 5.0
	var fill := OmniLight3D.new()
	world.add_child(fill)
	fill.position = Vector3(1, 1.3, -1.5)
	fill.light_color = Color("b8d7ed")
	fill.light_energy = 0.45
	fill.omni_range = 5.0
	var rim := OmniLight3D.new()
	world.add_child(rim)
	rim.position = Vector3(-1.0, 0.7, 0.8)
	rim.light_color = Color("accad8")
	rim.light_energy = 0.6
	rim.omni_range = 3.0
	var floor_node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_node.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("18242c")
	floor_material.roughness = 0.8
	floor_node.material_override = floor_material
	world.add_child(floor_node)
	var drone = preload("res://scripts/DroneController.gd").new()
	world.add_child(drone)
	drone.visible = true
	drone.global_position = Vector3(0, 0.205, 0)
	drone.set_process(false)
	drone.set_physics_process(false)
	drone.set_process_input(false)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.fov = 31
	camera.near = 0.01
	camera.far = 20.0
	camera.position = Vector3(1.18, 0.98, -1.5)
	if args.size() > 1 and args[1] == "rear":
		camera.position = Vector3(-1.15, 1.12, 1.45)
	camera.look_at(Vector3(0, 0.21, 0))
	camera.current = true
	for i in range(100):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(args[0])
	print("AIRFRAME CAPTURE ", args[0])
	world.queue_free()
	await process_frame
	quit()
