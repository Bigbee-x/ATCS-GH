extends Node3D
## Continuous cloud layers in the sky, driven by the same wind as rain/foliage.
var tod: Node
var weather_manager: Node
var _material: ShaderMaterial
var _offset := Vector2(0.12, 0.37)

func _ready() -> void:
	process_priority = 20

func initialize() -> void:
	if tod == null or tod.world_env == null:
		return
	var noise := FastNoiseLite.new()
	noise.seed = 5721
	noise.frequency = 0.014
	noise.fractal_octaves = 5
	var texture := NoiseTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.noise = noise
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/accra_sky.gdshader")
	_material.set_shader_parameter("cloud_noise", texture)
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	sky.sky_material = _material
	tod.world_env.environment.sky = sky
	# Both managers cache the sky; keep them on the same material after replacement.
	tod.set("_sky_material", _material)
	if weather_manager:
		weather_manager.set("_sky_material", _material)
	tod.force_reapply()
	_process(0.0)

func _process(delta: float) -> void:
	if _material == null:
		return
	if weather_manager:
		var mods = weather_manager.get("_current_mods")
		var wind: Vector3 = weather_manager.get_wind()
		_offset += Vector2(wind.x, wind.z) * delta * 0.0008
		_material.set_shader_parameter("cloud_offset", _offset)
		_material.set_shader_parameter("cloud_cover", mods.cloud_cover)
		_material.set_shader_parameter("storm", mods.rain_intensity)
		_material.set_shader_parameter("dust", mods.dust)
	if tod and tod.sun:
		_material.set_shader_parameter("sun_direction", tod.sun.global_basis.z)
		_material.set_shader_parameter("sun_color", tod.sun.light_color)
		# Daylight remains tied to the clock, including a gentle twilight shoulder.
		var hour: float = tod.time_of_day
		var daylight: float = smoothstep(5.3, 7.5, hour) * (1.0 - smoothstep(17.5, 19.5, hour))
		_material.set_shader_parameter("daylight", daylight)
