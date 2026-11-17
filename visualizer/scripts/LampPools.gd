extends MultiMeshInstance3D
## One additive quad under every street lamp: a far-distance stand-in for the
## lamp's spot light, which fades out a few hundred metres from the camera.
## Follows the same dusk, rain and cloud demand as the lamps themselves.
const StreetLamp = preload("res://scripts/StreetLamp.gd")
const RADIUS := 19.0
var _tod: Node
var _weather: Node
var _level: float = 0.0
var _material: ShaderMaterial

func setup(lamps: Array, scene: Node) -> void:
	name = "LampPools"
	_tod = scene.get_node_or_null("TimeOfDayManager")
	_weather = scene.get_node_or_null("WeatherManager")
	var quad := PlaneMesh.new()
	quad.size = Vector2(2, 2)
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = quad
	multimesh.instance_count = lamps.size()
	for i in range(lamps.size()):
		var lamp: Node3D = lamps[i]
		# The lantern hangs 1.55 m out over the road from the column.
		var under: Vector3 = lamp.position + lamp.basis.z * 1.55
		multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(RADIUS, 1, RADIUS)), Vector3(under.x, 0.17, under.z)))
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/lamp_pool.gdshader")
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false

func _process(delta: float) -> void:
	if not is_instance_valid(_tod):
		return
	var rain: float = _weather._current_mods.rain_intensity if is_instance_valid(_weather) else 0.0
	var cloud: float = _weather._current_mods.cloud_cover if is_instance_valid(_weather) else 0.0
	_level = lerpf(_level, StreetLamp.demand(_tod.time_of_day, rain, cloud), 1.0 - exp(-delta * 2.0))
	visible = _level > 0.01
	_material.set_shader_parameter("level", _level)
