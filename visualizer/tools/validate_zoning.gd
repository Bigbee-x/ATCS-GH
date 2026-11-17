extends SceneTree
## Integration checks for land use and clearance in both assembled environments.
## Godot --headless --path visualizer --script res://tools/validate_zoning.gd
const Signs = preload("res://scripts/StreetSignLayout.gd")
const Transit = preload("res://scripts/TransitLayout.gd")

var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	for corridor in [false, true]:
		var mode: String = "corridor" if corridor else "single"
		var path: String = "res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn"
		var scene: Node3D = load(path).instantiate()
		scene.get_node("WebSocketClient").auto_connect = false
		root.add_child(scene)
		current_scene = scene
		scene.get_node("WebSocketClient").set_process(false)
		await process_frame
		var environment: Node3D = scene.get_node("EnvironmentBuilder")
		var kit: Node3D = environment.get_node("DetailedStreetscape")
		var uses: Array = kit.get("land_uses")
		var frontage: Array = environment.get("frontage_uses")
		var roads: Array[Rect2] = _arterial_roads(corridor)
		var streets: Array[Rect2] = []
		if corridor:
			var town = preload("res://scripts/CityDistrictBuilder.gd")
			for street in town.streets(): streets.append(town.street_plot(street))
		for child in environment.get_children():
			if child is CSGBox3D and (String(child.name).begins_with("ResidentialStreet") or String(child.name).begins_with("CommercialAccess") or String(child.name).begins_with("AirportAccess")):
				streets.append(_box_footprint(child.global_transform, child.size))
		var counts: Dictionary = {}
		var tall_apartments: int = 0
		var tall_offices: int = 0
		for use: Dictionary in uses:
			var kind: String = use.kind
			counts[kind] = int(counts.get(kind, 0)) + 1
			if int(use.floors) >= 8:
				tall_apartments += 1 if kind == "apartment" else 0
				tall_offices += 1 if kind == "office" else 0
			var footprint: Rect2 = _use_footprint(use)
			for road in roads:
				_check(not footprint.intersects(road), "%s: %s obstructs an arterial %s" % [mode, _describe(use), road])
				if kind == "house":
					var clearance: float = _rect_distance(footprint, road)
					_check(clearance >= 12.0 - 0.01, "%s: %s is only %.2f from an arterial" % [mode, _describe(use), clearance])
			for street in streets:
				_check(not footprint.intersects(street), "%s: %s obstructs a neighbourhood street %s" % [mode, _describe(use), street])
		for kind in ["supermarket", "mall", "mechanic", "police", "kiosk", "shop", "house"]:
			_check(int(counts.get(kind, 0)) > 0, "%s: missing land use %s" % [mode, kind])
		_check(tall_apartments >= 2, "%s: expected at least two apartments with eight or more floors" % mode)
		_check(tall_offices >= 3, "%s: expected at least three offices with eight or more floors" % mode)
		_check(frontage.size() > 12, "%s: commercial frontage missing" % mode)
		# Distinct land-use records represent separate buildings or whole compounds.
		# A compound's house is recorded once with its enclosing plot dimensions.
		for i in range(uses.size()):
			for j in range(i + 1, uses.size()):
				_check(not _use_footprint(uses[i]).intersects(_use_footprint(uses[j])),
					"%s: overlapping buildings: %s and %s" % [mode, _describe(uses[i]), _describe(uses[j])])
		var reserved: Array[Rect2] = []
		for spec in Signs.billboards(corridor):
			reserved.append(Signs.plot(spec))
		for spec in Transit.stations(corridor):
			reserved.append(Transit.plot(spec))
		for i in range(frontage.size()):
			var item: Dictionary = frontage[i]
			var plot: Rect2 = item.plot
			_check(item.kind not in ["house", "apartment"], "%s: residential frontage at %s" % [mode, item.center])
			var matching_buildings: int = 0
			for use: Dictionary in uses:
				if use.kind == item.kind and use.center.is_equal_approx(item.center):
					matching_buildings += 1
					continue
				_check(not plot.intersects(_use_footprint(use)),
					"%s: frontage %s at %s overlaps %s" % [mode, item.kind, item.center, _describe(use)])
			_check(matching_buildings == 1, "%s: frontage %s at %s lacks its unique building" % [mode, item.kind, item.center])
			for j in range(i + 1, frontage.size()):
				_check(not plot.intersects(frontage[j].plot),
					"%s: overlapping frontage plots at %s and %s" % [mode, item.center, frontage[j].center])
			for exclusion in reserved:
				_check(not plot.intersects(exclusion), "%s: frontage at %s occupies a station/billboard plot %s" % [mode, item.center, exclusion])
			for street in streets:
				_check(not plot.intersects(street), "%s: frontage at %s blocks neighbourhood access %s" % [mode, item.center, street])
			for road in roads:
				_check(not plot.intersects(road), "%s: frontage apron at %s occupies an arterial" % [mode, item.center])
		print("ZONING ", mode, ": ", counts, "; commercial frontages=", frontage.size(),
			"; tall apartments=", tall_apartments, "; tall offices=", tall_offices)
		scene.queue_free()
		await process_frame
	print("Zoning validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)

func _describe(use: Dictionary) -> String:
	return "%s at %s (%s×%s)" % [use.kind, use.center, use.width, use.depth]

func _use_footprint(use: Dictionary) -> Rect2:
	var facing: Vector3 = use.facing
	var transform := Transform3D(Basis(Vector3.UP, atan2(facing.x, facing.z)), use.center)
	return _box_footprint(transform, Vector3(use.width, 1.0, use.depth))

func _box_footprint(transform: Transform3D, size: Vector3) -> Rect2:
	var half: Vector3 = (transform.basis.x.abs() * size.x + transform.basis.y.abs() * size.y + transform.basis.z.abs() * size.z) * 0.5
	return Rect2(transform.origin.x - half.x, transform.origin.z - half.z, half.x * 2.0, half.z * 2.0)

func _rect_distance(a: Rect2, b: Rect2) -> float:
	return Vector2(maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x)),
		maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))).length()

func _arterial_roads(corridor: bool) -> Array[Rect2]:
	var roads: Array[Rect2] = []
	if not corridor:
		roads.append(Rect2(-6.4,-1500.0,12.8,3000.0))
		roads.append(Rect2(-1500.0,-6.4,3000.0,12.8))
		return roads
	roads.append(Rect2(-6.4, -1500.0, 12.8, 3600.0))
	for i in range(3):
		var widths := preload("res://scripts/CorridorGeometry.gd").widths(i)
		roads.append(Rect2(-1500.0, i * 300.0 - widths.y * 0.5, 1500.0, widths.y))
		roads.append(Rect2(0.0, i * 300.0 - widths.z * 0.5, 1500.0, widths.z))
	return roads
