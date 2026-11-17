extends SceneTree
## Run with Godot --headless --path visualizer --script res://tools/validate_streetscape.gd
## Integration checks against the assembled scenes, not just the mesh helpers.

var failures: int = 0

func _initialize() -> void:
	call_deferred("_validate")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _validate() -> void:
	_check_beam_endpoints()
	for corridor in [false, true]:
		var scene_path: String = "res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn"
		var packed: PackedScene = load(scene_path)
		if packed == null:
			_check(false, "Scene failed to load: " + scene_path)
			continue
		var scene: Node3D = packed.instantiate()
		scene.get_node("WebSocketClient").auto_connect = false
		root.add_child(scene)
		current_scene = scene
		scene.get_node("WebSocketClient").set_process(false)
		await process_frame
		var environment: Node3D = scene.get_node("EnvironmentBuilder")
		var kit: Node3D = environment.get_node("DetailedStreetscape")
		_check(kit.get("_building_count") > 40, "Architecture missing in " + scene_path)
		_check(kit.get("_tree_count") > 25, "Vegetation missing in " + scene_path)
		if not corridor:
			_check(kit.get("_background_count") > 250,"Surrounding neighbourhoods missing in " + scene_path)
		_check(kit.get("_batches").is_empty(), "Unflushed geometry in " + scene_path)
		_check_roads(kit, corridor)
		var clock: Node = scene.get_node("TimeOfDayManager")
		clock.set_time(20.0)
		_check(environment.get("_mat_window_warm_early").emission_energy_multiplier > 0.0, "Windows do not light at night")
		clock.set_time(12.0)
		_check(is_zero_approx(environment.get("_mat_window_warm_early").emission_energy_multiplier), "Windows remain emissive by day")
		var camera: Camera3D = scene.get_node("IsometricCamera")
		_check(camera.projection == Camera3D.PROJECTION_PERSPECTIVE, "Perspective overview missing")
		var pivot: Vector3 = scene.get("_camera_pivot")
		var original_distance: float = camera.position.distance_to(pivot)
		scene.set("_zoom_level", 0.7)
		scene.call("_apply_camera")
		_check(camera.position.distance_to(pivot) < original_distance * 0.8, "Perspective zoom does not move camera")
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		scene.call("_apply_camera")
		_check(is_equal_approx(camera.size, float(scene.get("_camera_default_size")) * 0.7), "Plan-view zoom changed")
		print("VALIDATED ", scene_path)
		scene.queue_free()
		await process_frame
	print("Streetscape validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)

func _check_beam_endpoints() -> void:
	# Diagonal braces and roof ridges must reach their requested endpoints even
	# under a rotated building frame; world-axis scaling previously broke this.
	var kit = preload("res://scripts/AccraStreetscape.gd").new()
	var material := StandardMaterial3D.new()
	kit.configure(material, material)
	var frame := Transform3D(Basis(Vector3.UP, 0.7), Vector3(4, 0, 6))
	var a := Vector3(-1, 0.3, 0.2)
	for b: Vector3 in [Vector3(3, 0.3, 0.2), Vector3(1, 3, 2), Vector3(-1, 2.4, 0.2)]:
		kit.call("_beam", frame, a, b, 0.12, material)
		var batches: Dictionary = kit.get("_batches")
		for batch: Dictionary in batches.values():
			var transform: Transform3D = batch["transforms"][0]
			_check((transform * Vector3(0, -0.5, 0)).is_equal_approx(frame * a), "Beam start misses its anchor")
			_check((transform * Vector3(0, 0.5, 0)).is_equal_approx(frame * b), "Beam end misses its anchor")
		batches.clear()
	kit.free()

func _check_roads(kit: Node3D, corridor: bool) -> void:
	var roads: Array[Rect2] = []
	var net = preload("res://scripts/CorridorGeometry.gd")
	roads.append(Rect2(-6.4,-1500,12.8,3600 if corridor else 3000))
	for j in range(3 if corridor else 1):
		var w: Vector3 = net.widths(j,corridor)
		var z: float = net.center(j,corridor).z
		roads.append(Rect2(-1500,z-w.y*0.5,1500,w.y))
		roads.append(Rect2(0,z-w.z*0.5,1500,w.z))
	for child in kit.get_children():
		if not child is StaticBody3D:
			continue
		var collider: CollisionShape3D = child.get_child(0)
		var shape: BoxShape3D = collider.shape
		var transform: Transform3D = collider.global_transform
		var half: Vector3 = (transform.basis.x.abs() * shape.size.x + transform.basis.y.abs() * shape.size.y + transform.basis.z.abs() * shape.size.z) * 0.5
		var footprint := Rect2(transform.origin.x - half.x, transform.origin.z - half.z, half.x * 2.0, half.z * 2.0)
		for road in roads:
			_check(not footprint.intersects(road), "Building or wall obstructs a simulated road: " + str(footprint))
