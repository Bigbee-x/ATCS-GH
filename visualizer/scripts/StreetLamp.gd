extends Node3D
## Galvanised, serviceable LED lantern. Light is directed onto the carriageway.
const G = preload("res://scripts/PropGeometry.gd")
static var _body_mesh: ArrayMesh
var light: SpotLight3D
var _lens: StandardMaterial3D
var _brightness: float = 0.0
var _night: bool = false
var _tod: Node
var _weather: Node

func _ready() -> void:
	name = "StreetLamp"
	add_to_group("street_lamps")
	if _body_mesh == null:
		_body_mesh = _build_body()
	G.instance(self, _body_mesh, Vector3.ZERO, null, "GalvanisedMastAndLEDHousing")
	_lens = StandardMaterial3D.new()
	_lens.albedo_color = Color("e5e8df")
	_lens.roughness = 0.25
	_lens.emission_enabled = true
	_lens.emission = Color(1.0, 0.89, 0.72)
	_lens.emission_energy_multiplier = 0.0
	for z in [1.35, 1.55, 1.75]:
		G.box(self, Vector3(0, 4.69, z), Vector3(0.23, 0.018, 0.15), _lens, "LEDOptic")
	light = SpotLight3D.new()
	light.name = "RoadLight"
	light.position = Vector3(0, 4.65, 1.55)
	light.rotation.x = -PI * 0.5
	light.light_color = Color(1.0, 0.89, 0.73)
	# A wide, long throw: each lantern reaches across all four lanes and meets
	# the next one's pool, so the carriageway is lit end to end at metre scale.
	light.spot_range = 24.0
	light.spot_angle = 76.0
	light.spot_attenuation = 0.55
	light.spot_angle_attenuation = 0.45
	light.light_energy = 0
	light.distance_fade_enabled = true
	light.distance_fade_begin = 250
	light.distance_fade_length = 90
	# Large numbers of shadow maps are unnecessary for downward road pools.
	light.shadow_enabled = false
	add_child(light)
	call_deferred("_find_environment")

func _find_environment() -> void:
	var scene := get_parent().get_parent()
	_tod = scene.get_node_or_null("TimeOfDayManager")
	_weather = scene.get_node_or_null("WeatherManager")

func set_night(enabled: bool) -> void:
	_night = enabled

static func demand(hour: float, rain: float, cloud: float) -> float:
	var evening: float = smoothstep(17.4, 18.6, hour)
	var morning: float = 1.0 - smoothstep(5.5, 6.7, hour)
	return maxf(maxf(evening, morning), maxf(rain * 0.55, smoothstep(0.75, 1.0, cloud) * 0.18))

func _process(delta: float) -> void:
	var target: float = 1.0 if _night else 0.0
	if is_instance_valid(_tod):
		var rain: float = _weather._current_mods.rain_intensity if is_instance_valid(_weather) else 0.0
		var cloud: float = _weather._current_mods.cloud_cover if is_instance_valid(_weather) else 0.0
		target = demand(_tod.time_of_day, rain, cloud)
	_brightness = lerpf(_brightness, target, 1.0 - exp(-delta * 2.0))
	light.light_energy = _brightness * 9.0
	light.visible = _brightness > 0.005
	_lens.emission_energy_multiplier = _brightness * 9.0

static func _build_body() -> ArrayMesh:
	var parts := Node3D.new()
	var steel := G.solid(Color("89949b"), 0.75, 0.38)
	var dark := G.solid(Color("333e44"), 0.65, 0.4)
	var concrete := G.solid(Color("a39d8c"))
	G.box(parts, Vector3(0, 0.08, 0), Vector3(0.25, 0.16, 0.25), concrete, "Footing")
	G.box(parts, Vector3(0, 0.18, 0), Vector3(0.22, 0.025, 0.22), steel, "BasePlate")
	for x in [-0.075, 0.075]:
		for z in [-0.075, 0.075]:
			G.segment(parts, Vector3(x, 0.19, z), Vector3(x, 0.23, z), 0.015, dark, "AnchorBolt")
	G.segment(parts, Vector3(0, 0.2, 0), Vector3(0, 4.22, 0), 0.075, steel, "TaperedMast", 0.55)
	G.box(parts, Vector3(0, 0.65, -0.07), Vector3(0.07, 0.26, 0.015), dark, "ServiceHatch")
	var previous := Vector3(0, 4.22, 0)
	for i in range(1, 9):
		var t: float = i / 8.0
		var point := Vector3(0, 4.22 + sin(t * PI * 0.5) * 0.56, (1.0 - cos(t * PI * 0.5)) * 0.65)
		G.segment(parts, previous, point, 0.041, steel, "CurvedArm")
		previous = point
	G.segment(parts, previous, Vector3(0, 4.78, 1.4), 0.037, steel, "Outreach")
	var housing := G.rounded_box(parts, Vector3(0, 4.77, 1.55), Vector3(0.34, 0.83, 0.12), 0.11, dark, "LEDHousing")
	housing.rotation.x = PI * 0.5
	for z in [1.24, 1.34, 1.44, 1.54, 1.64, 1.74, 1.84]:
		G.box(parts, Vector3(0, 4.845, z), Vector3(0.24, 0.035, 0.025), steel, "CoolingFin")
	G.ellipsoid(parts, Vector3(0, 4.88, 1.27), Vector3(0.09, 0.075, 0.09), steel, "Photocell")
	var groups: Dictionary = {}
	for node: MeshInstance3D in parts.get_children():
		var mat: Material = node.material_override
		if not groups.has(mat):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[mat] = st
		# Index custom rounded housing before combining with indexed primitives.
		var indexed := SurfaceTool.new()
		indexed.create_from(node.mesh, 0)
		indexed.index()
		groups[mat].append_from(indexed.commit(), 0, node.transform)
	var result := ArrayMesh.new()
	for mat in groups:
		groups[mat].set_material(mat)
		groups[mat].commit(result)
	parts.free()
	return result
