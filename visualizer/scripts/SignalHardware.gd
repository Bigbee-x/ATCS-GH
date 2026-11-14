extends RefCounted
## Shared physical signal assemblies. Phase decisions remain in the scene builders.
const G = preload("res://scripts/PropGeometry.gd")
const LENS = preload("res://shaders/signal_lens.gdshader")
const COLORS = {"red": Color("ff371b"), "yellow": Color("ffb51a"), "green": Color("24ef98"), "arrow": Color("24ef98")}
const PED_LENS = preload("res://shaders/ped_lens.gdshader")
const PED_COLORS = {"hand": Color("ff8a1f"), "person": Color("eef3f6")}   # Portland orange, lunar white
const HEIGHT := 5.5

static func structure(root: Node3D, arm_sign: float, arm_length: float) -> void:
	root.set_meta("arm_sign", arm_sign)
	root.set_meta("arm_length", arm_length)
	root.add_to_group("pedestrian_obstacle")
	var steel := G.solid(Color("67706c"), 0.75, 0.38)
	var dark := G.solid(Color("343b38"), 0.55, 0.5)
	G.box(root, Vector3(0, 0.045, 0), Vector3(0.44, 0.13, 0.44), G.solid(Color("949085")), "ConcreteFooting")
	G.rounded_box(root, Vector3(0, 0.12, 0), Vector3(0.30, 0.045, 0.30), 0.018, steel, "BaseFlange")
	G.segment(root, Vector3(0, 0.14, 0), Vector3(0, HEIGHT - 0.23, 0), 0.095, steel, "Pole", 0.65)
	G.ellipsoid(root, Vector3(0, HEIGHT - 0.22, 0), Vector3(0.14, 0.14, 0.14), steel, "MastElbow")
	var previous := Vector3(0, HEIGHT - 0.23, 0)
	for i in range(1, 7):
		var t: float = i / 6.0 * PI * 0.5
		var point := Vector3(arm_sign * 0.24 * (1.0 - cos(t)), HEIGHT - 0.23 + 0.24 * sin(t), 0)
		G.segment(root, previous, point, 0.064, steel)
		previous = point
	var arm := G.segment(root, previous, Vector3(arm_sign * arm_length, HEIGHT, 0), 0.062, steel, "MastArm", 0.72)
	arm.set_meta("arm_sign", arm_sign)
	G.segment(root, Vector3(0, HEIGHT - 1.1, 0), Vector3(arm_sign * arm_length * 0.52, HEIGHT, 0), 0.029, steel, "Brace")
	for x in [-0.105, 0.105]:
		for z in [-0.105, 0.105]:
			G.segment(root, Vector3(x, 0.14, z), Vector3(x, 0.18, z), 0.021, dark, "AnchorBolt")
	G.rounded_box(root, Vector3(0, 0.58, 0.089), Vector3(0.075, 0.27, 0.018), 0.015, dark, "InspectionDoor")
	for y in [0.49, 0.67]:
		G.ellipsoid(root, Vector3(0, y, 0.102), Vector3.ONE * 0.014, steel, "DoorScrew")

static func overhead(root: Node3D, cx: float, arm_y: float) -> Dictionary:
	var y: float = arm_y - 0.48
	var dark := G.solid(Color("202723"), 0.2, 0.56)
	var edge := G.solid(Color("b4ae89"), 0.25, 0.66)
	for x in [cx - 0.42, cx + 0.42]:
		G.segment(root, Vector3(x, arm_y, 0), Vector3(x, y + 0.12, -0.02), 0.022, dark, "SuspensionClamp")
	G.rounded_box(root, Vector3(cx, y, -0.045), Vector3(1.51, 0.66, 0.035), 0.08, edge, "ReflectiveBorder")
	G.rounded_box(root, Vector3(cx, y, -0.068), Vector3(1.49, 0.64, 0.015), 0.075, dark, "RearBackplate")
	G.rounded_box(root, Vector3(cx, y, -0.015), Vector3(1.45, 0.60, 0.045), 0.07, dark, "Backplate")
	G.rounded_box(root, Vector3(cx, y, 0.06), Vector3(1.25, 0.40, 0.24), 0.07, dark)
	var head: Dictionary = {}
	var colors: Array[String] = ["red", "yellow", "green"]
	for i in range(3):
		head[colors[i]] = _aspect(root, Vector3(cx + (i - 1) * 0.39, y, 0.19), 0.132, colors[i], "Over")
	var arrow_y: float = y - 0.47
	G.rounded_box(root, Vector3(cx, arrow_y, 0.035), Vector3(0.41, 0.41, 0.23), 0.065, dark, "ArrowHousing")
	G.segment(root, Vector3(cx, y - 0.13, -0.035), Vector3(cx, arrow_y + 0.1, -0.035), 0.022, dark)
	head["arrow"] = _aspect(root, Vector3(cx, arrow_y, 0.16), 0.145, "arrow", "Over")
	return head

static func repeater(root: Node3D, top_y: float) -> Dictionary:
	var dark := G.solid(Color("202723"), 0.2, 0.56)
	for y in [top_y - 0.12, top_y - 0.88]:
		G.segment(root, Vector3(0, y, 0), Vector3(0, y, 0.2), 0.027, dark, "HeadClamp")
	G.rounded_box(root, Vector3(0, top_y - 0.5, 0.18), Vector3(0.37, 1.02, 0.23), 0.065, dark, "RepeaterHousing")
	var head: Dictionary = {}
	var colors: Array[String] = ["red", "yellow", "green"]
	for i in range(3):
		head[colors[i]] = _aspect(root, Vector3(0, top_y - 0.19 - i * 0.31, 0.305), 0.108, colors[i], "Pole")
	return head

## Far-side through head plus its left-arrow head, clamped behind the pole and
## facing back across the junction (pole-local -Z). It serves the approach whose
## far-left corner this pole stands on; the arrow sits on that driver's left.
static func far_side(root: Node3D, top_y: float) -> Dictionary:
	var mount := Node3D.new()
	mount.name = "FarSideHead"
	mount.rotation.y = PI
	root.add_child(mount)
	var dark := G.solid(Color("202723"), 0.2, 0.56)
	for y in [top_y - 0.12, top_y - 0.88]:
		G.segment(mount, Vector3(0, y, 0), Vector3(0, y, 0.19), 0.027, dark, "HeadClamp")
	G.rounded_box(mount, Vector3(0, top_y - 0.5, 0.30), Vector3(0.37, 1.02, 0.23), 0.065, dark, "FarSideHousing")
	var head: Dictionary = {}
	var colors: Array[String] = ["red", "yellow", "green"]
	for i in range(3):
		head[colors[i]] = _aspect(mount, Vector3(0, top_y - 0.19 - i * 0.31, 0.425), 0.108, colors[i], "Far")
	var arrow_y: float = top_y - 0.81
	G.segment(mount, Vector3(-0.17, arrow_y, 0.30), Vector3(-0.25, arrow_y, 0.30), 0.03, dark, "ArrowBracket")
	G.rounded_box(mount, Vector3(-0.42, arrow_y, 0.30), Vector3(0.37, 0.37, 0.23), 0.065, dark, "FarArrowHousing")
	head["arrow"] = _aspect(mount, Vector3(-0.42, arrow_y, 0.425), 0.12, "arrow", "Far")
	return head

## The junction's one signal cabinet: NEMA TS2 Type 1 (1118 x 1397 x 660 mm) with a
## side-mounted battery backup (432 x 1270 x 432 mm) and a low-profile 5G antenna,
## on a concrete foundation. Local +Z is the main door, +X the battery side.
static func junction_cabinet(root: Node3D, junction: String) -> void:
	root.add_to_group("pedestrian_obstacle")
	var alu := G.solid(Color("c9cccd"), 0.55, 0.42)
	var door_alu := G.solid(Color("bec2c3"), 0.5, 0.45)
	var dark := G.solid(Color("2b2e33"), 0.3, 0.55)
	G.box(root, Vector3(0.175, 0.055, 0.06), Vector3(1.75, 0.15, 0.92), G.solid(Color("9a988f"), 0.0, 0.9), "CabinetFoundation")
	G.rounded_box(root, Vector3(0, 0.8285, 0), Vector3(1.118, 1.397, 0.66), 0.012, alu, "CabinetBody")
	G.rounded_box(root, Vector3(0, 1.545, -0.01), Vector3(1.16, 0.036, 0.70), 0.01, door_alu, "CabinetRoof")
	G.box(root, Vector3(0, 0.835, 0.331), Vector3(1.076, 1.316, 0.006), dark, "DoorGasket")
	G.rounded_box(root, Vector3(0, 0.835, 0.337), Vector3(1.06, 1.30, 0.012), 0.008, door_alu, "MainDoor")
	# Police door: officers reach the flash and signals-off switches without the main key.
	G.rounded_box(root, Vector3(0.28, 1.13, 0.345), Vector3(0.30, 0.34, 0.006), 0.006, alu, "PoliceDoor")
	G.segment(root, Vector3(0.38, 1.13, 0.346), Vector3(0.38, 1.13, 0.353), 0.012, dark, "PoliceLock")
	for y in [0.40, 0.85, 1.30]:
		G.segment(root, Vector3(-0.535, y - 0.05, 0.345), Vector3(-0.535, y + 0.05, 0.345), 0.012, dark, "DoorHinge")
	G.segment(root, Vector3(0.45, 0.68, 0.365), Vector3(0.45, 0.92, 0.365), 0.011, dark, "DoorHandle")
	for y in [0.68, 0.92]:
		G.segment(root, Vector3(0.45, y, 0.343), Vector3(0.45, y, 0.365), 0.008, dark, "HandleStandoff")
	for i in range(6):
		G.box(root, Vector3(0, 0.28 + i * 0.036, 0.345), Vector3(0.72, 0.012, 0.010), dark, "DoorLouvre")
	G.box(root, Vector3(-0.24, 1.32, 0.344), Vector3(0.30, 0.075, 0.004), dark, "AssetPlate")
	G.label(root, "ATCS-GH " + junction, Vector3(-0.24, 1.32, 0.347), 0.27, 0.05, Color("d9ddcd")).visibility_range_end = 14.0
	var badge := G.rounded_box(root, Vector3(-0.30, 1.13, 0.345), Vector3(0.09, 0.09, 0.006), 0.007, G.solid(Color("cfb952")), "ElectricalWarning")
	G.label(badge, "!", Vector3(0, 0, 0.006), 0.04, 0.065, Color("242924")).visibility_range_end = 12.0
	# Battery backup bolted to the battery side, its door flush with the main door.
	G.rounded_box(root, Vector3(0.775, 0.765, 0.122), Vector3(0.432, 1.27, 0.432), 0.01, alu, "BatteryBackup")
	G.rounded_box(root, Vector3(0.775, 0.77, 0.343), Vector3(0.40, 1.20, 0.012), 0.008, door_alu, "BatteryBackupDoor")
	for i in range(4):
		G.box(root, Vector3(0.775, 1.12 + i * 0.036, 0.351), Vector3(0.30, 0.012, 0.010), dark, "BatteryLouvre")
	G.segment(root, Vector3(0.93, 0.70, 0.362), Vector3(0.93, 0.86, 0.362), 0.010, dark, "BatteryHandle")
	G.label(root, "BATTERY BACKUP", Vector3(0.775, 0.98, 0.351), 0.30, 0.03, Color("2b2e33")).visibility_range_end = 10.0
	# Low-profile 5G antenna, for remote access only: it is never in the control loop.
	G.segment(root, Vector3(0.22, 1.563, -0.14), Vector3(0.22, 1.60, -0.14), 0.075, dark, "RoofAntenna")

static func _aspect(root: Node3D, at: Vector3, radius: float, color_name: String, suffix: String) -> Dictionary:
	var dark := G.solid(Color("151c18"), 0.15, 0.58)
	G.segment(root, at - Vector3(0, 0, 0.025), at, radius + 0.018, dark, "LensSeal")
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * radius * 2.0
	var material := ShaderMaterial.new()
	material.shader = LENS
	material.set_shader_parameter("signal_color", COLORS[color_name])
	material.set_shader_parameter("arrow", color_name == "arrow")
	var lens := G.instance(root, quad, at + Vector3(0, 0, 0.003), material, "Bulb_%s_%s" % [color_name, suffix])
	lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Individual open-bottom cylindrical hoods shield each lens from sunlight.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(16):
		var a: float = -0.12 + i * (PI + 0.24) / 16.0
		var b: float = -0.12 + (i + 1) * (PI + 0.24) / 16.0
		var p := Vector3(cos(a), sin(a), 0) * (radius + 0.017)
		var q := Vector3(cos(b), sin(b), 0) * (radius + 0.017)
		var depth := Vector3(0, 0, radius * 1.25)
		G.triangle(st, p, p + depth, q)
		G.triangle(st, q, p + depth, q + depth)
	var hood_mat := dark.duplicate() as StandardMaterial3D
	hood_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	G.instance(root, st.commit(), at, hood_mat, "SunHood")
	var glow := OmniLight3D.new()
	glow.position = at + Vector3(0, 0, 0.09)
	glow.light_color = COLORS[color_name]
	glow.light_energy = 0.0
	glow.omni_range = 1.2
	glow.omni_attenuation = 2.0
	glow.shadow_enabled = false
	root.add_child(glow)
	return {"mesh": lens, "glow": glow, "material": material, "on": false}

## ITE two-section pedestrian head (hand over walking person) on a short bracket
## from the pole. `at` is its lens plane in root space, `yaw` turns it to face
## the far end of its crossing, `clamp_from` is where the bracket leaves the pole.
static func pedestrian_head(root: Node3D, at: Vector3, yaw: float, clamp_from: Vector3) -> Dictionary:
	var dark := G.solid(Color("202723"), 0.2, 0.56)
	var mount := Node3D.new()
	mount.name = "PedestrianHead"
	mount.position = at
	mount.rotation.y = yaw
	root.add_child(mount)
	G.rounded_box(mount, Vector3(0, 0, -0.10), Vector3(0.30, 0.50, 0.20), 0.04, dark, "PedHousing")
	for y in [0.235, -0.005]:
		G.box(mount, Vector3(0, y, 0.055), Vector3(0.29, 0.012, 0.11), dark, "PedVisor")
	for y in [-0.12, 0.12]:
		G.segment(root, Vector3(clamp_from.x, at.y + y, clamp_from.z), mount.transform * Vector3(0, y, -0.20), 0.018, dark, "PedBracket")
	return {"hand": _ped_aspect(mount, Vector3(0, 0.12, 0.004), "hand"), "person": _ped_aspect(mount, Vector3(0, -0.12, 0.004), "person")}

static func _ped_aspect(mount: Node3D, at: Vector3, symbol: String) -> Dictionary:
	# Emissive only: no glow light, so sixteen heads per junction stay cheap.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.21, 0.21)
	var material := ShaderMaterial.new()
	material.shader = PED_LENS
	material.set_shader_parameter("signal_color", PED_COLORS[symbol])
	material.set_shader_parameter("person", symbol == "person")
	var lens := G.instance(mount, quad, at, material, "PedLens_" + symbol)
	lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return {"mesh": lens, "glow": null, "material": material, "on": false}

static func set_aspect(aspect: Dictionary, enabled: bool) -> void:
	aspect["on"] = enabled
	aspect["material"].set_shader_parameter("active", 1.0 if enabled else 0.0)
	if aspect["glow"] != null:
		aspect["glow"].light_energy = 0.08 if enabled else 0.0
